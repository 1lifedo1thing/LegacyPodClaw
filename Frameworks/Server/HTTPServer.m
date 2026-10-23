/*
 * OCHTTPServer.m
 * LegacyPodClaw - HTTP Server Implementation
 *
 * Uses CFSocket for non-blocking accept, NSStream for I/O.
 * Parses HTTP/1.1 requests, routes to handlers, supports WS upgrade.
 */

#import "HTTPServer.h"
#import <sys/socket.h>
#import <sys/stat.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>

static const NSUInteger kDefaultMaxConnections = 32;
static const NSUInteger kDefaultMaxBodySize = 64 * 1024;
static const NSUInteger kDefaultMaxHeaderSize = 8 * 1024;
static const NSTimeInterval kDefaultRequestTimeout = 15.0;
enum { kReadBufferSize = 4096 };
static const NSUInteger kMaxHeaderCount = 64;
static const unsigned long long kMaxStaticFileSize = 1024 * 1024;

#pragma mark - OCHTTPRequest

@implementation OCHTTPRequest

- (void)dealloc {
    [_method release]; [_path release]; [_query release];
    [_headers release]; [_body release]; [_remoteAddress release];
    [super dealloc];
}

- (NSString *)headerValue:(NSString *)name {
    /* Case-insensitive header lookup */
    for (NSString *key in _headers) {
        if ([key caseInsensitiveCompare:name] == NSOrderedSame) {
            return [_headers objectForKey:key];
        }
    }
    return nil;
}

- (NSDictionary *)queryParams {
    if (!_query || [_query length] == 0) return @{};
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    for (NSString *pair in [_query componentsSeparatedByString:@"&"]) {
        NSRange eq = [pair rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *key = [[pair substringToIndex:eq.location]
            stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        NSString *val = [[pair substringFromIndex:eq.location + 1]
            stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        if (key && val) [params setObject:val forKey:key];
    }
    return params;
}

- (NSDictionary *)jsonBody {
    if (!_body || [_body length] == 0) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:_body options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

- (NSString *)bearerToken {
    NSString *auth = [self headerValue:@"Authorization"];
    if ([auth length] > 7 && [[auth substringToIndex:7] caseInsensitiveCompare:@"Bearer "] == NSOrderedSame) {
        return [[auth substringFromIndex:7]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
    return nil;
}

- (BOOL)isWebSocketUpgrade {
    NSString *upgrade = [self headerValue:@"Upgrade"];
    NSString *connection = [self headerValue:@"Connection"];
    return (upgrade && [upgrade caseInsensitiveCompare:@"websocket"] == NSOrderedSame &&
            connection && [connection rangeOfString:@"Upgrade" options:NSCaseInsensitiveSearch].location != NSNotFound);
}

@end

#pragma mark - OCHTTPResponse

@implementation OCHTTPResponse

- (instancetype)init {
    if ((self = [super init])) {
        _statusCode = 200;
        _headers = [[NSMutableDictionary alloc] initWithCapacity:4];
        [_headers setObject:@"LegacyPodClaw" forKey:@"Server"];
        [_headers setObject:@"close" forKey:@"Connection"];
        [_headers setObject:@"no-store" forKey:@"Cache-Control"];
        [_headers setObject:@"nosniff" forKey:@"X-Content-Type-Options"];
    }
    return self;
}

- (void)dealloc {
    [_headers release]; [_body release];
    [super dealloc];
}

+ (OCHTTPResponse *)responseWithStatus:(NSInteger)status {
    OCHTTPResponse *r = [[[OCHTTPResponse alloc] init] autorelease];
    r.statusCode = status;
    return r;
}

+ (OCHTTPResponse *)jsonResponse:(id)object {
    return [self jsonResponse:object status:200];
}

+ (OCHTTPResponse *)jsonResponse:(id)object status:(NSInteger)status {
    OCHTTPResponse *r = [[[OCHTTPResponse alloc] init] autorelease];
    r.statusCode = status;
    [r.headers setObject:@"application/json" forKey:@"Content-Type"];
    NSData *body = nil;
    if (object && [NSJSONSerialization isValidJSONObject:object]) {
        body = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    }
    r.body = body ?: [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
    return r;
}

+ (OCHTTPResponse *)textResponse:(NSString *)text {
    OCHTTPResponse *r = [[[OCHTTPResponse alloc] init] autorelease];
    [r.headers setObject:@"text/plain; charset=utf-8" forKey:@"Content-Type"];
    r.body = [text dataUsingEncoding:NSUTF8StringEncoding];
    return r;
}

+ (OCHTTPResponse *)errorResponse:(NSInteger)status message:(NSString *)message {
    return [self jsonResponse:@{@"ok": @NO, @"error": message ?: @""} status:status];
}

- (NSData *)serializedHTTPResponse {
    NSString *statusText = [self _statusText:_statusCode];
    NSMutableString *header = [NSMutableString stringWithCapacity:256];
    [header appendFormat:@"HTTP/1.1 %ld %@\r\n", (long)_statusCode, statusText];

    [_headers setObject:[NSString stringWithFormat:@"%lu", (unsigned long)[_body length]]
                 forKey:@"Content-Length"];

    for (NSString *key in _headers) {
        [header appendFormat:@"%@: %@\r\n", key, [_headers objectForKey:key]];
    }
    [header appendString:@"\r\n"];

    NSMutableData *data = [NSMutableData dataWithData:[header dataUsingEncoding:NSUTF8StringEncoding]];
    if (_body) [data appendData:_body];
    return data;
}

- (NSString *)_statusText:(NSInteger)code {
    switch (code) {
        case 200: return @"OK";
        case 201: return @"Created";
        case 204: return @"No Content";
        case 400: return @"Bad Request";
        case 401: return @"Unauthorized";
        case 403: return @"Forbidden";
        case 404: return @"Not Found";
        case 405: return @"Method Not Allowed";
        case 408: return @"Request Timeout";
        case 413: return @"Payload Too Large";
        case 426: return @"Upgrade Required";
        case 431: return @"Request Header Fields Too Large";
        case 500: return @"Internal Server Error";
        case 501: return @"Not Implemented";
        case 503: return @"Service Unavailable";
        default:  return @"Unknown";
    }
}

@end

#pragma mark - Route Entry

@interface _OCRouteEntry : NSObject {
    @public
    NSString *method;
    NSString *path;
    OCHTTPHandler handler;
    BOOL isPrefix; /* path ends with * */
    BOOL isPublic;
}
@end

@implementation _OCRouteEntry
- (void)dealloc {
    [method release]; [path release]; [handler release];
    [super dealloc];
}
@end

#pragma mark - Client Connection

@interface _OCHTTPConnection : NSObject <NSStreamDelegate> {
    @public
    NSInputStream *inputStream;
    NSOutputStream *outputStream;
    NSString *remoteAddress;
    uint16_t remotePort;

    NSMutableData *readBuffer;
    BOOL headersParsed;
    BOOL dispatched;
    BOOL responded;
    BOOL closed;
    NSUInteger contentLength;
    OCHTTPRequest *request;

    NSMutableData *writeBuffer;
    NSUInteger writeOffset;

    OCHTTPServer *server; /* weak - not retained */
    NSTimer *timeoutTimer;
}
@end

@interface OCHTTPServer ()
- (void)_readDataFromConnection:(_OCHTTPConnection *)conn;
- (void)_flushConnection:(_OCHTTPConnection *)conn;
- (void)_closeConnection:(_OCHTTPConnection *)conn;
@end

@implementation _OCHTTPConnection

- (void)dealloc {
    [inputStream setDelegate:nil]; [outputStream setDelegate:nil];
    [inputStream close]; [outputStream close];
    [inputStream release]; [outputStream release];
    [remoteAddress release]; [readBuffer release]; [request release];
    [writeBuffer release];
    [timeoutTimer invalidate];
    [super dealloc];
}

- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode {
    if (aStream == inputStream && eventCode == NSStreamEventHasBytesAvailable) {
        [server _readDataFromConnection:self];
    } else if (aStream == outputStream && eventCode == NSStreamEventHasSpaceAvailable) {
        [server _flushConnection:self];
    } else if (eventCode == NSStreamEventErrorOccurred || eventCode == NSStreamEventEndEncountered) {
        [server _closeConnection:self];
    }
}

@end

#pragma mark - OCHTTPServer

@interface OCHTTPServer () {
    CFSocketRef _listenSocket;
    NSMutableArray *_routes;
    NSMutableSet *_connections;
    OCWSUpgradeHandler _wsUpgradeHandler;
    NSString *_staticDir;
    NSString *_staticURLPath;
}
@end

/* Accept callback */
static void OCHTTPServerAcceptCallback(CFSocketRef s, CFSocketCallBackType type,
                                        CFDataRef address, const void *data, void *info);

static void OCSetNoSigPipe(int fd) {
    int on = 1;
    // a peer that resets mid-write would otherwise kill the whole app with sigpipe
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
}

static BOOL OCIsTokenChar(unichar c) {
    if (c >= 'A' && c <= 'Z') return YES;
    if (c >= 'a' && c <= 'z') return YES;
    if (c >= '0' && c <= '9') return YES;
    return [@"!#$%&'*+-.^_`|~" rangeOfString:[NSString stringWithCharacters:&c length:1]].location != NSNotFound;
}

static BOOL OCIsToken(NSString *s) {
    NSUInteger len = [s length];
    if (len == 0) return NO;
    for (NSUInteger i = 0; i < len; i++) {
        if (!OCIsTokenChar([s characterAtIndex:i])) return NO;
    }
    return YES;
}

@implementation OCHTTPServer

- (instancetype)init {
    if ((self = [super init])) {
        _port = 18789;
        _bindAddress = [@"0.0.0.0" retain];
        _maxConnections = kDefaultMaxConnections;
        _maxBodySize = kDefaultMaxBodySize;
        _maxHeaderSize = kDefaultMaxHeaderSize;
        _requestTimeout = kDefaultRequestTimeout;
        _handlerTimeout = kDefaultRequestTimeout;
        _routes = [[NSMutableArray alloc] initWithCapacity:16];
        _connections = [[NSMutableSet alloc] initWithCapacity:16];
    }
    return self;
}

- (void)dealloc {
    [self stop];
    [_bindAddress release]; [_routes release]; [_connections release];
    [_wsUpgradeHandler release]; [_staticDir release]; [_staticURLPath release];
    [_authorizer release];
    [super dealloc];
}

#pragma mark - Start/Stop

- (BOOL)start:(NSError **)error {
    if (_isRunning) return YES;

    /* Create socket */
    CFSocketContext ctx = {0, (__bridge void *)self, NULL, NULL, NULL};
    _listenSocket = CFSocketCreate(kCFAllocatorDefault, PF_INET, SOCK_STREAM, IPPROTO_TCP,
                                    kCFSocketAcceptCallBack, OCHTTPServerAcceptCallback, &ctx);

    if (!_listenSocket) {
        if (error) *error = [NSError errorWithDomain:@"OCHTTPServer" code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: @"Failed to create socket"}];
        return NO;
    }

    /* Allow address reuse */
    int yes = 1;
    setsockopt(CFSocketGetNative(_listenSocket), SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    OCSetNoSigPipe(CFSocketGetNative(_listenSocket));

    /* Bind */
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons(_port);
    if (inet_pton(AF_INET, [_bindAddress UTF8String], &addr.sin_addr) != 1) {
        CFSocketInvalidate(_listenSocket);
        CFRelease(_listenSocket); _listenSocket = NULL;
        if (error) *error = [NSError errorWithDomain:@"OCHTTPServer" code:-3
                                            userInfo:@{NSLocalizedDescriptionKey: @"Invalid bind address"}];
        return NO;
    }

    NSData *addrData = [NSData dataWithBytes:&addr length:sizeof(addr)];
    CFSocketError sockErr = CFSocketSetAddress(_listenSocket, (__bridge CFDataRef)addrData);

    if (sockErr != kCFSocketSuccess) {
        CFSocketInvalidate(_listenSocket);
        CFRelease(_listenSocket); _listenSocket = NULL;
        if (error) *error = [NSError errorWithDomain:@"OCHTTPServer" code:-2
                                            userInfo:@{NSLocalizedDescriptionKey:
            [NSString stringWithFormat:@"Failed to bind to %@:%d", _bindAddress, _port]}];
        return NO;
    }

    /* Schedule on run loop */
    CFRunLoopSourceRef source = CFSocketCreateRunLoopSource(kCFAllocatorDefault, _listenSocket, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    CFRelease(source);

    _isRunning = YES;

    dispatch_async(dispatch_get_main_queue(), ^{
        if ([_delegate respondsToSelector:@selector(httpServerDidStart:port:)]) {
            [_delegate httpServerDidStart:self port:_port];
        }
    });

    return YES;
}

- (void)stop {
    if (!_isRunning) return;

    if (_listenSocket) {
        CFSocketInvalidate(_listenSocket);
        CFRelease(_listenSocket);
        _listenSocket = NULL;
    }

    /* Close all connections */
    for (_OCHTTPConnection *conn in [_connections allObjects]) {
        [self _closeConnection:conn];
    }

    _isRunning = NO;

    dispatch_async(dispatch_get_main_queue(), ^{
        if ([_delegate respondsToSelector:@selector(httpServerDidStop:)]) {
            [_delegate httpServerDidStop:self];
        }
    });
}

#pragma mark - Routing

- (void)get:(NSString *)path handler:(OCHTTPHandler)handler {
    [self route:@"GET" path:path handler:handler];
}

- (void)post:(NSString *)path handler:(OCHTTPHandler)handler {
    [self route:@"POST" path:path handler:handler];
}

- (void)route:(NSString *)method path:(NSString *)path handler:(OCHTTPHandler)handler {
    [self _addRoute:method path:path handler:handler isPublic:NO];
}

- (void)publicGet:(NSString *)path handler:(OCHTTPHandler)handler {
    // prefix matches would let a public route shadow private ones
    NSString *exact = [path hasSuffix:@"*"] ? [path substringToIndex:[path length] - 1] : path;
    [self _addRoute:@"GET" path:exact handler:handler isPublic:YES];
}

- (void)_addRoute:(NSString *)method path:(NSString *)path handler:(OCHTTPHandler)handler isPublic:(BOOL)isPublic {
    _OCRouteEntry *entry = [[_OCRouteEntry alloc] init];
    entry->method = [method retain];
    entry->isPrefix = !isPublic && [path hasSuffix:@"*"];
    entry->path = [(entry->isPrefix ? [path substringToIndex:[path length] - 1] : path) retain];
    entry->handler = [handler copy];
    entry->isPublic = isPublic;
    [_routes addObject:entry];
    [entry release];
}

- (void)onWebSocketUpgrade:(OCWSUpgradeHandler)handler {
    [_wsUpgradeHandler release];
    _wsUpgradeHandler = [handler copy];
}

- (void)serveStaticFiles:(NSString *)directory atPath:(NSString *)urlPath {
    [_staticDir release];
    _staticDir = [[[directory stringByStandardizingPath] stringByResolvingSymlinksInPath] copy];
    [_staticURLPath release]; _staticURLPath = [urlPath copy];
}

- (_OCRouteEntry *)_routeForRequest:(OCHTTPRequest *)req {
    for (_OCRouteEntry *route in _routes) {
        if (![route->method isEqualToString:req.method]) continue;
        BOOL match = route->isPrefix ? [req.path hasPrefix:route->path]
                                     : [req.path isEqualToString:route->path];
        if (match) return route;
    }
    return nil;
}

#pragma mark - Accept

- (void)_acceptConnection:(CFSocketNativeHandle)nativeSocket {
    if (!_isRunning || [_connections count] >= _maxConnections) {
        close(nativeSocket);
        return;
    }

    OCSetNoSigPipe(nativeSocket);

    /* Get remote address */
    struct sockaddr_in peerAddr;
    socklen_t peerLen = sizeof(peerAddr);
    memset(&peerAddr, 0, sizeof(peerAddr));
    char addrBuf[INET_ADDRSTRLEN] = "unknown";
    if (getpeername(nativeSocket, (struct sockaddr *)&peerAddr, &peerLen) == 0) {
        inet_ntop(AF_INET, &peerAddr.sin_addr, addrBuf, sizeof(addrBuf));
    }

    /* Create streams */
    CFReadStreamRef readStream = NULL;
    CFWriteStreamRef writeStream = NULL;
    CFStreamCreatePairWithSocket(kCFAllocatorDefault, nativeSocket, &readStream, &writeStream);

    if (!readStream || !writeStream) {
        if (readStream) CFRelease(readStream);
        if (writeStream) CFRelease(writeStream);
        close(nativeSocket);
        return;
    }

    // the streams own the descriptor from here, so closing them releases it
    CFReadStreamSetProperty(readStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
    CFWriteStreamSetProperty(writeStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);

    _OCHTTPConnection *conn = [[_OCHTTPConnection alloc] init];
    conn->inputStream = (NSInputStream *)readStream;
    conn->outputStream = (NSOutputStream *)writeStream;
    conn->remoteAddress = [[NSString stringWithUTF8String:addrBuf] retain];
    conn->remotePort = ntohs(peerAddr.sin_port);
    conn->readBuffer = [[NSMutableData alloc] initWithCapacity:kReadBufferSize];
    conn->writeBuffer = [[NSMutableData alloc] init];
    conn->server = self;

    [conn->inputStream setDelegate:conn];
    [conn->outputStream setDelegate:conn];
    [conn->inputStream scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [conn->outputStream scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [conn->inputStream open];
    [conn->outputStream open];

    conn->timeoutTimer = [NSTimer scheduledTimerWithTimeInterval:_requestTimeout
                                                          target:self
                                                        selector:@selector(_connectionTimeout:)
                                                        userInfo:conn
                                                         repeats:NO];

    [_connections addObject:conn];
    [conn release];
}

#pragma mark - Read/Parse

- (void)_readDataFromConnection:(_OCHTTPConnection *)conn {
    // closing or upgrading drops the set's reference while this loop still uses conn
    [[conn retain] autorelease];
    uint8_t buf[kReadBufferSize];
    while (!conn->closed && [conn->inputStream hasBytesAvailable]) {
        NSInteger bytesRead = [conn->inputStream read:buf maxLength:sizeof(buf)];
        if (bytesRead < 0) { [self _closeConnection:conn]; return; }
        if (bytesRead == 0) break;
        // once a request is dispatched the rest of the input is ignored, not buffered
        if (conn->dispatched || conn->responded) continue;
        [conn->readBuffer appendBytes:buf length:(NSUInteger)bytesRead];

        if (!conn->headersParsed) {
            [self _tryParseHeaders:conn];
        } else {
            [self _tryReadBody:conn];
        }
    }
}

- (void)_reject:(_OCHTTPConnection *)conn status:(NSInteger)status message:(NSString *)message {
    OCHTTPResponse *resp = [OCHTTPResponse errorResponse:status message:message];
    if (status == 401) [resp.headers setObject:@"Bearer" forKey:@"WWW-Authenticate"];
    [self _sendResponse:resp toConnection:conn];
}

- (void)_tryParseHeaders:(_OCHTTPConnection *)conn {
    const uint8_t *bytes = [conn->readBuffer bytes];
    NSUInteger length = [conn->readBuffer length];

    NSUInteger headerEnd = 0;
    NSUInteger scanLimit = MIN(length, _maxHeaderSize);
    for (NSUInteger i = 0; i + 3 < scanLimit; i++) {
        if (bytes[i] == '\r' && bytes[i+1] == '\n' && bytes[i+2] == '\r' && bytes[i+3] == '\n') {
            headerEnd = i + 4;
            break;
        }
    }
    if (headerEnd == 0) {
        if (length >= _maxHeaderSize) [self _reject:conn status:431 message:@"Headers too large"];
        return;
    }

    // latin-1 maps every byte, so odd header bytes cannot make the decode fail
    NSString *headerStr = [[[NSString alloc] initWithBytes:bytes length:headerEnd - 4
                                                  encoding:NSISOLatin1StringEncoding] autorelease];
    NSArray *lines = [headerStr componentsSeparatedByString:@"\r\n"];
    if ([lines count] < 1 || [lines count] > kMaxHeaderCount + 1) {
        [self _reject:conn status:400 message:@"Bad request"];
        return;
    }

    NSArray *parts = [[lines objectAtIndex:0] componentsSeparatedByString:@" "];
    if ([parts count] != 3) { [self _reject:conn status:400 message:@"Bad request line"]; return; }
    NSString *method = [parts objectAtIndex:0];
    NSString *uri = [parts objectAtIndex:1];
    NSString *version = [parts objectAtIndex:2];
    if (!OCIsToken(method) || ![uri hasPrefix:@"/"] ||
        !([version isEqualToString:@"HTTP/1.1"] || [version isEqualToString:@"HTTP/1.0"])) {
        [self _reject:conn status:400 message:@"Bad request line"];
        return;
    }

    OCHTTPRequest *req = [[OCHTTPRequest alloc] init];
    conn->request = req;
    conn->headersParsed = YES;
    req.method = method;
    req.remoteAddress = conn->remoteAddress;
    req.remotePort = conn->remotePort;

    NSRange qRange = [uri rangeOfString:@"?"];
    if (qRange.location != NSNotFound) {
        req.path = [uri substringToIndex:qRange.location];
        req.query = [uri substringFromIndex:qRange.location + 1];
    } else {
        req.path = uri;
    }

    NSMutableDictionary *hdrs = [NSMutableDictionary dictionaryWithCapacity:8];
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
    for (NSUInteger i = 1; i < [lines count]; i++) {
        NSString *line = [lines objectAtIndex:i];
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) { [self _reject:conn status:400 message:@"Bad header"]; return; }
        NSString *key = [line substringToIndex:colon.location];
        if (!OCIsToken(key)) { [self _reject:conn status:400 message:@"Bad header"]; return; }
        NSString *val = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:ws];
        // duplicates of these are how smuggling and auth confusion start
        if ([req headerValue:key] && ([key caseInsensitiveCompare:@"Content-Length"] == NSOrderedSame ||
                                      [key caseInsensitiveCompare:@"Authorization"] == NSOrderedSame ||
                                      [key caseInsensitiveCompare:@"Host"] == NSOrderedSame)) {
            [self _reject:conn status:400 message:@"Duplicate header"];
            return;
        }
        [hdrs setObject:val forKey:key];
        req.headers = hdrs;
    }
    req.headers = hdrs;

    if ([req headerValue:@"Transfer-Encoding"]) {
        [self _reject:conn status:501 message:@"Transfer-Encoding not supported"];
        return;
    }

    NSString *clStr = [req headerValue:@"Content-Length"];
    unsigned long long cl = 0;
    if (clStr) {
        NSScanner *sc = [NSScanner scannerWithString:clStr];
        if ([clStr length] == 0 || [clStr length] > 12 ||
            [clStr rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location != NSNotFound ||
            ![sc scanUnsignedLongLong:&cl]) {
            [self _reject:conn status:400 message:@"Bad Content-Length"];
            return;
        }
    }

    // auth runs before the body is read, so an unauthenticated client cannot make us buffer anything
    BOOL isUpgrade = [req isWebSocketUpgrade];
    _OCRouteEntry *route = isUpgrade ? nil : [self _routeForRequest:req];
    BOOL isPublic = route && route->isPublic;
    BOOL hasAuthHeader = [req headerValue:@"Authorization"] != nil;
    req.authorized = (_authorizer && hasAuthHeader) ? _authorizer(req) : NO;

    if (isUpgrade) {
        // browsers cannot set headers on a websocket, so a missing header defers auth to the connect frame
        if (hasAuthHeader && !req.authorized) { [self _reject:conn status:401 message:@"Unauthorized"]; return; }
        if (![req.method isEqualToString:@"GET"] || cl > 0) {
            [self _reject:conn status:400 message:@"Bad upgrade"];
            return;
        }
    } else if (!isPublic && !req.authorized) {
        [self _reject:conn status:401 message:@"Unauthorized"];
        return;
    } else if (!req.authorized && cl > 0) {
        [self _reject:conn status:400 message:@"Unexpected body"];
        return;
    }

    if (cl > _maxBodySize) {
        [self _reject:conn status:413 message:@"Payload too large"];
        return;
    }
    conn->contentLength = (NSUInteger)cl;

    NSData *remaining = nil;
    if (headerEnd < length) {
        remaining = [NSData dataWithBytes:bytes + headerEnd length:length - headerEnd];
    }
    [conn->readBuffer setLength:0];
    if (remaining) [conn->readBuffer appendData:remaining];

    if (isUpgrade) {
        [self _dispatchUpgrade:conn];
        return;
    }
    [self _tryReadBody:conn];
}

- (void)_tryReadBody:(_OCHTTPConnection *)conn {
    if (conn->dispatched || conn->responded) return;
    if ([conn->readBuffer length] < conn->contentLength) return;
    conn->request.body = conn->contentLength > 0
        ? [conn->readBuffer subdataWithRange:NSMakeRange(0, conn->contentLength)]
        : nil;
    [conn->readBuffer setLength:0];
    [self _dispatchRequest:conn];
}

#pragma mark - Dispatch

- (void)_dispatchUpgrade:(_OCHTTPConnection *)conn {
    conn->dispatched = YES;
    if (!_wsUpgradeHandler) {
        [self _reject:conn status:404 message:@"Not found"];
        return;
    }

    [conn->timeoutTimer invalidate];
    conn->timeoutTimer = nil;
    [conn->inputStream removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [conn->outputStream removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [conn->inputStream setDelegate:nil];
    [conn->outputStream setDelegate:nil];

    // ownership of the streams moves to the websocket layer
    NSInputStream *input = [conn->inputStream autorelease];
    NSOutputStream *output = [conn->outputStream autorelease];
    conn->inputStream = nil;
    conn->outputStream = nil;
    NSData *pending = [[conn->readBuffer copy] autorelease];
    OCHTTPRequest *req = [[conn->request retain] autorelease];
    conn->closed = YES;
    [_connections removeObject:conn];

    _wsUpgradeHandler(req, input, output, pending);
}

- (void)_dispatchRequest:(_OCHTTPConnection *)conn {
    conn->dispatched = YES;
    OCHTTPRequest *req = conn->request;

    _OCRouteEntry *route = [self _routeForRequest:req];
    if (route) {
        [conn->timeoutTimer invalidate];
        conn->timeoutTimer = [NSTimer scheduledTimerWithTimeInterval:_handlerTimeout
                                                              target:self
                                                            selector:@selector(_connectionTimeout:)
                                                            userInfo:conn
                                                             repeats:NO];
        route->handler(req, ^(OCHTTPResponse *response) {
            [self _sendResponse:response toConnection:conn];
        });
        return;
    }

    if (_staticDir && _staticURLPath && [req.method isEqualToString:@"GET"] &&
        [req.path hasPrefix:_staticURLPath]) {
        [self _serveStaticFile:req connection:conn];
        return;
    }

    [self _sendResponse:[OCHTTPResponse errorResponse:404 message:@"Not found"] toConnection:conn];
}

- (void)_serveStaticFile:(OCHTTPRequest *)req connection:(_OCHTTPConnection *)conn {
    NSString *relativePath = [req.path substringFromIndex:[_staticURLPath length]];
    if ([relativePath length] == 0 || [relativePath isEqualToString:@"/"]) {
        relativePath = @"/index.html";
    }
    if ([relativePath rangeOfString:@".."].location != NSNotFound ||
        [relativePath rangeOfString:@"\\"].location != NSNotFound ||
        [relativePath rangeOfString:@"%"].location != NSNotFound) {
        [self _sendResponse:[OCHTTPResponse errorResponse:403 message:@"Forbidden"] toConnection:conn];
        return;
    }

    // resolve symlinks and compare against the directory plus a slash, so a sibling like static-old cannot match
    NSString *resolved = [[[_staticDir stringByAppendingPathComponent:relativePath]
        stringByStandardizingPath] stringByResolvingSymlinksInPath];
    NSString *base = [_staticDir hasSuffix:@"/"] ? _staticDir : [_staticDir stringByAppendingString:@"/"];
    if (![resolved hasPrefix:base]) {
        [self _sendResponse:[OCHTTPResponse errorResponse:403 message:@"Forbidden"] toConnection:conn];
        return;
    }

    struct stat st;
    if (stat([resolved fileSystemRepresentation], &st) != 0 || !S_ISREG(st.st_mode)) {
        [self _sendResponse:[OCHTTPResponse errorResponse:404 message:@"Not found"] toConnection:conn];
        return;
    }
    if ((unsigned long long)st.st_size > kMaxStaticFileSize) {
        [self _sendResponse:[OCHTTPResponse errorResponse:413 message:@"File too large"] toConnection:conn];
        return;
    }

    NSData *fileData = [NSData dataWithContentsOfFile:resolved];
    if (!fileData) {
        [self _sendResponse:[OCHTTPResponse errorResponse:404 message:@"Not found"] toConnection:conn];
        return;
    }

    OCHTTPResponse *resp = [OCHTTPResponse responseWithStatus:200];
    resp.body = fileData;

    NSString *ext = [[resolved pathExtension] lowercaseString];
    NSString *ct = @"application/octet-stream";
    if ([ext isEqualToString:@"html"]) ct = @"text/html; charset=utf-8";
    else if ([ext isEqualToString:@"js"]) ct = @"application/javascript";
    else if ([ext isEqualToString:@"css"]) ct = @"text/css";
    else if ([ext isEqualToString:@"json"]) ct = @"application/json";
    else if ([ext isEqualToString:@"png"]) ct = @"image/png";
    else if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) ct = @"image/jpeg";
    [resp.headers setObject:ct forKey:@"Content-Type"];

    [self _sendResponse:resp toConnection:conn];
}

#pragma mark - Response

- (void)_sendResponse:(OCHTTPResponse *)response toConnection:(_OCHTTPConnection *)conn {
    // handlers may answer late or twice; only the first answer on a live connection counts
    if (conn->responded || conn->closed || !response) return;
    conn->responded = YES;
    [conn->writeBuffer appendData:[response serializedHTTPResponse]];
    [self _flushConnection:conn];
}

- (void)_flushConnection:(_OCHTTPConnection *)conn {
    if (conn->closed || !conn->responded) return;
    [[conn retain] autorelease];
    while (conn->writeOffset < [conn->writeBuffer length] && [conn->outputStream hasSpaceAvailable]) {
        const uint8_t *p = (const uint8_t *)[conn->writeBuffer bytes] + conn->writeOffset;
        NSInteger n = [conn->outputStream write:p maxLength:[conn->writeBuffer length] - conn->writeOffset];
        if (n < 0) { [self _closeConnection:conn]; return; }
        if (n == 0) break;
        conn->writeOffset += (NSUInteger)n;
    }
    if (conn->writeOffset >= [conn->writeBuffer length]) {
        [self _closeConnection:conn];
    }
}

#pragma mark - Connection Management

- (void)_closeConnection:(_OCHTTPConnection *)conn {
    if (conn->closed) return;
    conn->closed = YES;
    [[conn retain] autorelease];
    [conn->timeoutTimer invalidate];
    conn->timeoutTimer = nil;
    [conn->inputStream setDelegate:nil];
    [conn->outputStream setDelegate:nil];
    [conn->inputStream removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [conn->outputStream removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [conn->inputStream close];
    [conn->outputStream close];
    [_connections removeObject:conn];
}

- (void)_connectionTimeout:(NSTimer *)timer {
    _OCHTTPConnection *conn = [[[timer userInfo] retain] autorelease];
    conn->timeoutTimer = nil;
    if (conn->closed) return;
    if (conn->responded) {
        [self _closeConnection:conn];
        return;
    }
    [self _sendResponse:[OCHTTPResponse errorResponse:408 message:@"Request timeout"] toConnection:conn];
    // a peer that never reads must not keep the slot after the timeout either
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self _closeConnection:conn];
    });
}

- (NSUInteger)activeConnections {
    return [_connections count];
}

@end

#pragma mark - Accept Callback

static void OCHTTPServerAcceptCallback(CFSocketRef s, CFSocketCallBackType type,
                                        CFDataRef address, const void *data, void *info) {
    OCHTTPServer *server = (__bridge OCHTTPServer *)info;
    if (type == kCFSocketAcceptCallBack && data) {
        CFSocketNativeHandle nativeSocket = *(CFSocketNativeHandle *)data;
        [server _acceptConnection:nativeSocket];
    }
}
