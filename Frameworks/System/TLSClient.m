/*
 * TLSClient.m
 * LegacyPodClaw - HTTPS client on wolfSSL (TLS 1.2/1.3)
 */

#import "TLSClient.h"
#import "HTTPResponseParser.h"
#import <sys/socket.h>
#import <netdb.h>
#import <fcntl.h>
#import <poll.h>
#import <errno.h>
#import <ctype.h>
#import <unistd.h>

#include <wolfssl/wolfcrypt/settings.h>
#include <wolfssl/ssl.h>
#include <wolfssl/error-ssl.h>
#include <wolfssl/wolfcrypt/asn_public.h>
#include <wolfssl/wolfcrypt/hash.h>
#include <wolfssl/wolfcrypt/coding.h>

/* the tweak runs inside springboard, so the bundle path cannot come from mainBundle */
static NSString *const kCABundlePath = @"/Applications/LegacyPodClaw.app/cacert.pem";

static const int kConnectTimeoutMs = 15000;
static const int kIOTimeoutSec = 120;          /* streamed replies can idle while the model thinks */
static const NSTimeInterval kConnectBudgetSec = 30;   /* all addresses together, not 15 s each */
static const NSTimeInterval kRequestBudgetSec = 600;  /* a trickling server must not hold the thread forever */

static WOLFSSL_CTX *gContext = NULL;
static NSString *gContextError = nil;
static NSMutableDictionary *gPins = nil;


static NSError *TLSError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:CPTLSErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static WOLFSSL_CTX *SharedContext(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        wolfSSL_Init();
        WOLFSSL_CTX *ctx = wolfSSL_CTX_new(wolfSSLv23_client_method());
        if (!ctx) { gContextError = @"wolfSSL context allocation failed"; return; }
        wolfSSL_CTX_SetMinVersion(ctx, WOLFSSL_TLSV1_2);

        NSData *pem = [NSData dataWithContentsOfFile:kCABundlePath];
        if (!pem || wolfSSL_CTX_load_verify_buffer(ctx, [pem bytes], (long)[pem length],
                                                   WOLFSSL_FILETYPE_PEM) != WOLFSSL_SUCCESS) {
            wolfSSL_CTX_free(ctx);
            gContextError = [[NSString alloc] initWithFormat:@"CA bundle missing or unreadable at %@", kCABundlePath];
            return;
        }
        wolfSSL_CTX_set_verify(ctx, WOLFSSL_VERIFY_PEER, NULL);
        gContext = ctx;
    });
    return gContext;
}

static int ConnectSocket(NSString *host, int port, NSError **error) {
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    char portStr[8];
    snprintf(portStr, sizeof(portStr), "%d", port);

    int gai = getaddrinfo([host UTF8String], portStr, &hints, &res);
    if (gai != 0) {
        *error = TLSError(CPTLSErrorDNS, [NSString stringWithFormat:@"DNS lookup for %@ failed: %s", host, gai_strerror(gai)]);
        return -1;
    }

    int sock = -1;
    NSDate *connectDeadline = [NSDate dateWithTimeIntervalSinceNow:kConnectBudgetSec];
    for (struct addrinfo *ai = res; ai && sock < 0; ai = ai->ai_next) {
        int budgetMs = (int)([connectDeadline timeIntervalSinceNow] * 1000);
        if (budgetMs <= 0) break;
        int s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (s < 0) continue;

        int on = 1;
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
        int flags = fcntl(s, F_GETFL, 0);
        fcntl(s, F_SETFL, flags | O_NONBLOCK);

        int rc = connect(s, ai->ai_addr, ai->ai_addrlen);
        if (rc != 0 && errno == EINPROGRESS) {
            struct pollfd pfd = { .fd = s, .events = POLLOUT };
            int soErr = 0;
            socklen_t len = sizeof(soErr);
            if (poll(&pfd, 1, MIN(kConnectTimeoutMs, budgetMs)) == 1 &&
                getsockopt(s, SOL_SOCKET, SO_ERROR, &soErr, &len) == 0 && soErr == 0) {
                rc = 0;
            }
        }
        if (rc != 0) { close(s); continue; }

        fcntl(s, F_SETFL, flags);
        struct timeval tv = { .tv_sec = kIOTimeoutSec, .tv_usec = 0 };
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        sock = s;
    }
    freeaddrinfo(res);

    if (sock < 0) {
        *error = TLSError(CPTLSErrorConnect, [NSString stringWithFormat:@"Could not connect to %@:%d", host, port]);
    }
    return sock;
}

static NSString *SPKIHash(WOLFSSL *ssl) {
    WOLFSSL_X509 *cert = wolfSSL_get_peer_certificate(ssl);
    if (!cert) return nil;

    NSString *result = nil;
    int derLen = 0;
    const unsigned char *der = wolfSSL_X509_get_der(cert, &derLen);
    byte spki[2048];
    word32 spkiLen = sizeof(spki);
    if (der && derLen > 0 &&
        wc_GetSubjectPubKeyInfoDerFromCert(der, (word32)derLen, spki, &spkiLen) == 0) {
        byte digest[WC_SHA256_DIGEST_SIZE];
        byte b64[64];
        word32 b64Len = sizeof(b64);
        if (wc_Sha256Hash(spki, spkiLen, digest) == 0 &&
            Base64_Encode_NoNl(digest, sizeof(digest), b64, &b64Len) == 0) {
            result = [[[NSString alloc] initWithBytes:b64 length:b64Len encoding:NSASCIIStringEncoding] autorelease];
        }
    }
    wolfSSL_X509_free(cert);
    return result;
}

static BOOL WriteAll(WOLFSSL *ssl, const void *bytes, NSUInteger length) {
    const char *p = bytes;
    while (length > 0) {
        int chunk = (int)MIN(length, (NSUInteger)16384);
        int n = wolfSSL_write(ssl, p, chunk);
        if (n <= 0) return NO;
        p += n;
        length -= (NSUInteger)n;
    }
    return YES;
}

static BOOL HasLineBreak(NSString *s) {
    return [s rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]].location != NSNotFound;
}


@implementation CPTLSClient

+ (void)request:(NSString *)urlString method:(NSString *)method
        headers:(NSDictionary *)headers body:(NSData *)body
     completion:(CPHTTPSCompletion)completion {
    [self streamRequest:urlString method:method headers:headers body:body
                onChunk:nil completion:completion];
}

+ (void)setPinnedSPKIHashes:(NSArray *)hashes forHost:(NSString *)host {
    @synchronized (self) {
        if (!gPins) gPins = [[NSMutableDictionary alloc] init];
        if ([hashes count]) [gPins setObject:[[hashes copy] autorelease] forKey:[host lowercaseString]];
        else [gPins removeObjectForKey:[host lowercaseString]];
    }
}

+ (NSArray *)pinsForHost:(NSString *)host {
    @synchronized (self) {
        return [[[gPins objectForKey:[host lowercaseString]] retain] autorelease];
    }
}

+ (void)streamRequest:(NSString *)urlString method:(NSString *)method
              headers:(NSDictionary *)headers body:(NSData *)body
              onChunk:(CPHTTPSStreamChunk)onChunk
           completion:(CPHTTPSCompletion)completion {

    CPHTTPSCompletion done = [[completion copy] autorelease];
    CPHTTPSStreamChunk chunkHandler = [[onChunk copy] autorelease];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            NSData *responseBody = nil;
            NSInteger status = 0;
            NSError *error = nil;
            [self performRequest:urlString method:method headers:headers body:body
                         onChunk:chunkHandler body:&responseBody status:&status error:&error];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (done) done(responseBody, status, error);
            });
        }
    });
}

+ (void)performRequest:(NSString *)urlString method:(NSString *)method
               headers:(NSDictionary *)headers body:(NSData *)body
               onChunk:(CPHTTPSStreamChunk)onChunk
                  body:(NSData **)outBody status:(NSInteger *)outStatus error:(NSError **)outError {

    NSURL *url = [NSURL URLWithString:urlString];
    NSString *host = [url host];
    if (![[[url scheme] lowercaseString] isEqualToString:@"https"] || [host length] == 0) {
        *outError = TLSError(CPTLSErrorBadRequest, [NSString stringWithFormat:@"Not an https URL: %@", urlString]);
        return;
    }
    for (NSString *key in headers) {
        if (HasLineBreak(key) || HasLineBreak([[headers objectForKey:key] description])) {
            *outError = TLSError(CPTLSErrorBadRequest, @"Header contains a line break");
            return;
        }
    }

    WOLFSSL_CTX *ctx = SharedContext();
    if (!ctx) { *outError = TLSError(CPTLSErrorSetup, gContextError ?: @"TLS setup failed"); return; }

    int port = [url port] ? [[url port] intValue] : 443;
    int sock = ConnectSocket(host, port, outError);
    if (sock < 0) return;

    WOLFSSL *ssl = wolfSSL_new(ctx);
    if (!ssl) { close(sock); *outError = TLSError(CPTLSErrorSetup, @"wolfSSL session allocation failed"); return; }
    wolfSSL_set_fd(ssl, sock);

    const char *hostC = [host UTF8String];
    if (wolfSSL_UseSNI(ssl, WOLFSSL_SNI_HOST_NAME, hostC, (unsigned short)strlen(hostC)) != WOLFSSL_SUCCESS ||
        wolfSSL_check_domain_name(ssl, hostC) != WOLFSSL_SUCCESS) {
        /* without the name check the handshake would accept any valid certificate */
        *outError = TLSError(CPTLSErrorSetup, @"Could not set the TLS host name");
        goto cleanup;
    }

    int connected = wolfSSL_connect(ssl);
    if (connected != WOLFSSL_SUCCESS) {
        char reason[WOLFSSL_MAX_ERROR_SZ];
        wolfSSL_ERR_error_string_n(wolfSSL_get_error(ssl, connected), reason, sizeof(reason));
        *outError = TLSError(CPTLSErrorHandshake, [NSString stringWithFormat:@"TLS handshake with %@ failed: %s", host, reason]);
        goto cleanup;
    }

    NSArray *pins = [self pinsForHost:host];
    if ([pins count]) {
        NSString *spki = SPKIHash(ssl);
        if (!spki || ![pins containsObject:spki]) {
            *outError = TLSError(CPTLSErrorPinning, [NSString stringWithFormat:@"Certificate for %@ does not match its pinned key", host]);
            goto cleanup;
        }
    }

    {
        /* the raw path keeps percent escapes and trailing slashes that -[NSURL path] removes */
        NSString *path = [(NSString *)CFURLCopyPath((CFURLRef)url) autorelease];
        if ([path length] == 0) path = @"/";
        NSString *query = [(NSString *)CFURLCopyQueryString((CFURLRef)url, NULL) autorelease];
        NSString *target = query ? [NSString stringWithFormat:@"%@?%@", path, query] : path;
        NSCharacterSet *badTarget = [NSCharacterSet characterSetWithCharactersInString:@" \t\r\n"];
        NSCharacterSet *notToken = [[NSCharacterSet uppercaseLetterCharacterSet] invertedSet];
        NSString *verb = method ?: @"GET";
        if ([target rangeOfCharacterFromSet:badTarget].location != NSNotFound ||
            [verb length] == 0 || [verb rangeOfCharacterFromSet:notToken].location != NSNotFound) {
            *outError = TLSError(CPTLSErrorProtocol, @"Invalid request method or path");
            goto cleanup;
        }
        NSString *hostHeader = [url port] ? [NSString stringWithFormat:@"%@:%d", host, port] : host;

        NSMutableString *head = [NSMutableString stringWithFormat:@"%@ %@ HTTP/1.1\r\nHost: %@\r\nConnection: close\r\n",
                                 verb, target, hostHeader];
        if (body) [head appendFormat:@"Content-Length: %lu\r\n", (unsigned long)[body length]];
        for (NSString *key in headers) {
            [head appendFormat:@"%@: %@\r\n", key, [headers objectForKey:key]];
        }
        [head appendString:@"\r\n"];

        NSData *headData = [head dataUsingEncoding:NSUTF8StringEncoding];
        if (!WriteAll(ssl, [headData bytes], [headData length]) ||
            (body && !WriteAll(ssl, [body bytes], [body length]))) {
            *outError = TLSError(CPTLSErrorIO, [NSString stringWithFormat:@"Sending request to %@ failed", host]);
            goto cleanup;
        }

        CPHTTPResponseParser *parser = [[[CPHTTPResponseParser alloc] initWithChunkHandler:onChunk] autorelease];
        char buf[8192];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kRequestBudgetSec];
        while (!parser->complete) {
            if ([deadline timeIntervalSinceNow] <= 0) {
                *outError = TLSError(CPTLSErrorIO, [NSString stringWithFormat:@"%@ took longer than %.0f s", host, kRequestBudgetSec]);
                break;
            }
            int n = wolfSSL_read(ssl, buf, sizeof(buf));
            if (n > 0) {
                [parser feed:buf length:(NSUInteger)n];
                continue;
            }
            int err = wolfSSL_get_error(ssl, n);
            if (err == WOLFSSL_ERROR_ZERO_RETURN || err == SOCKET_PEER_CLOSED_E || n == 0) {
                [parser finishAtEOF];
            } else {
                *outError = TLSError(CPTLSErrorIO, err == WOLFSSL_ERROR_WANT_READ
                    ? [NSString stringWithFormat:@"%@ timed out", host]
                    : [NSString stringWithFormat:@"Reading from %@ failed (%d)", host, err]);
            }
            break;
        }
        if (!*outError && parser->error) *outError = [[parser->error retain] autorelease];
        *outStatus = parser->statusCode;
        *outBody = [[[parser body] copy] autorelease];
    }

cleanup:
    wolfSSL_shutdown(ssl);
    wolfSSL_free(ssl);
    close(sock);
}

+ (void)postJSON:(NSString *)urlString headers:(NSDictionary *)headers
            body:(NSDictionary *)jsonBody
      completion:(void(^)(NSDictionary *, NSError *))completion {

    /* dataWithJSONObject: throws on invalid input instead of returning nil */
    NSData *bodyData = [NSJSONSerialization isValidJSONObject:jsonBody]
        ? [NSJSONSerialization dataWithJSONObject:jsonBody options:0 error:NULL] : nil;
    if (!bodyData) {
        NSError *encodeError = TLSError(CPTLSErrorProtocol, @"Request body is not valid JSON");
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, encodeError); });
        return;
    }

    NSMutableDictionary *hdrs = [NSMutableDictionary dictionaryWithDictionary:headers ?: @{}];
    [hdrs setObject:@"application/json" forKey:@"Content-Type"];

    [self request:urlString method:@"POST" headers:hdrs body:bodyData
       completion:^(NSData *data, NSInteger statusCode, NSError *error) {
        if (error) { completion(nil, error); return; }
        NSError *parseError = nil;
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError] : nil;
        if (![json isKindOfClass:[NSDictionary class]]) {
            completion(nil, parseError ?: TLSError(CPTLSErrorProtocol,
                [NSString stringWithFormat:@"Expected a JSON object (HTTP %ld)", (long)statusCode]));
            return;
        }
        completion(json, nil);
    }];
}

@end
