/*
 * HTTPResponseParser.m
 * LegacyPodClaw - incremental HTTP/1.1 response parser used by CPTLSClient
 */

#import "HTTPResponseParser.h"
#import <ctype.h>

NSString *const CPTLSErrorDomain = @"CPTLSClient";

static const NSUInteger kMaxHeaderBytes = 64 * 1024;
static const NSUInteger kMaxBodyBytes = 24 * 1024 * 1024;

@implementation CPHTTPResponseParser

- (id)initWithChunkHandler:(CPHTTPSStreamChunk)onChunk {
    if ((self = [super init])) {
        _pending = [[NSMutableData alloc] init];
        _body = [[NSMutableData alloc] init];
        _contentLength = -1;
        _needChunkSize = YES;
        _onChunk = [onChunk copy];
    }
    return self;
}

- (void)dealloc {
    [_pending release]; [_body release]; [_onChunk release]; [error release];
    [super dealloc];
}

- (NSData *)body { return _body; }

- (void)fail:(NSInteger)code message:(NSString *)message {
    if (!error) error = [[NSError alloc] initWithDomain:CPTLSErrorDomain code:code
                                               userInfo:@{NSLocalizedDescriptionKey: message}];
    complete = YES;
}

- (void)emit:(const uint8_t *)bytes length:(NSUInteger)length {
    /* bytes past the declared length are not part of this response */
    if (!_chunked && _contentLength >= 0) {
        long long room = _contentLength - (long long)_received;
        if (room < (long long)length) length = room > 0 ? (NSUInteger)room : 0;
    }
    if (length == 0) return;
    if (_received + length > kMaxBodyBytes) {
        [self fail:CPTLSErrorTooLarge message:@"Response exceeds size limit"];
        return;
    }
    _received += length;
    /* a streamed success goes to the chunk handler only; keeping a copy would double the memory */
    BOOL streaming = _onChunk && statusCode >= 200 && statusCode < 300;
    if (!streaming) [_body appendBytes:bytes length:length];
    if (_onChunk) {
        NSData *chunk = [NSData dataWithBytes:bytes length:length];
        CPHTTPSStreamChunk handler = _onChunk;
        dispatch_async(dispatch_get_main_queue(), ^{ handler(chunk); });
    }
    if (!_chunked && _contentLength >= 0 && (long long)_received >= _contentLength) {
        complete = YES;
    }
}

- (void)parseHeaders:(NSString *)head {
    NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
    NSString *status = [lines count] ? [lines objectAtIndex:0] : @"";
    NSRange sp = [status rangeOfString:@" "];
    if (![status hasPrefix:@"HTTP/"] || sp.location == NSNotFound) {
        [self fail:CPTLSErrorProtocol message:@"Malformed HTTP status line"];
        return;
    }
    statusCode = [[status substringFromIndex:sp.location + 1] integerValue];

    for (NSUInteger i = 1; i < [lines count]; i++) {
        NSString *line = [lines objectAtIndex:i];
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *name = [[line substringToIndex:colon.location] lowercaseString];
        NSString *value = [[line substringFromIndex:colon.location + 1]
                           stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([name isEqualToString:@"transfer-encoding"]) {
            _chunked = [[value lowercaseString] rangeOfString:@"chunked"].location != NSNotFound;
        } else if ([name isEqualToString:@"content-length"]) {
            NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
            if ([value length] == 0 || [value length] > 18 || [value rangeOfCharacterFromSet:nonDigits].location != NSNotFound) {
                [self fail:CPTLSErrorProtocol message:@"Malformed Content-Length"];
                return;
            }
            _contentLength = [value longLongValue];
        }
    }
    if (_chunked) _contentLength = -1;
    if (_contentLength == 0 || statusCode == 204 || statusCode == 304) complete = YES;
}

- (void)drainChunked {
    while (!complete && [_pending length] > 0) {
        const uint8_t *p = [_pending bytes];
        NSUInteger len = [_pending length];

        if (_needChunkSize) {
            NSUInteger eol = NSNotFound;
            for (NSUInteger j = 0; j + 1 < len; j++) {
                if (p[j] == '\r' && p[j + 1] == '\n') { eol = j; break; }
            }
            if (eol == NSNotFound) {
                if (len > 1024) [self fail:CPTLSErrorProtocol message:@"Malformed chunk header"];
                return;
            }
            /* hex digits, then an optional ;extension; anything else is a framing error */
            unsigned long long size = 0;
            NSUInteger digits = 0;
            while (digits < eol && isxdigit(p[digits])) {
                int c = p[digits];
                size = size * 16 + (unsigned long long)(isdigit(c) ? c - '0' : (tolower(c) - 'a' + 10));
                if (++digits > 15) break;
            }
            BOOL validTail = digits == eol || (digits < eol && (p[digits] == ';' || p[digits] == ' ' || p[digits] == '\t'));
            if (digits == 0 || digits > 15 || !validTail) {
                [self fail:CPTLSErrorProtocol message:@"Malformed chunk size"];
                return;
            }
            _chunkRemain = size;
            [_pending replaceBytesInRange:NSMakeRange(0, eol + 2) withBytes:NULL length:0];
            if (_chunkRemain == 0) { complete = YES; return; }
            _needChunkSize = NO;
        } else if (_chunkRemain > 0) {
            NSUInteger take = (NSUInteger)MIN((unsigned long long)len, _chunkRemain);
            [self emit:p length:take];
            [_pending replaceBytesInRange:NSMakeRange(0, take) withBytes:NULL length:0];
            _chunkRemain -= take;
        } else {
            if (len < 2) return;
            if (p[0] != '\r' || p[1] != '\n') { [self fail:CPTLSErrorProtocol message:@"Missing CRLF after chunk"]; return; }
            [_pending replaceBytesInRange:NSMakeRange(0, 2) withBytes:NULL length:0];
            _needChunkSize = YES;
        }
    }
}

- (void)feed:(const char *)bytes length:(NSUInteger)length {
    if (complete) return;
    if (headersDone && !_chunked) {
        [self emit:(const uint8_t *)bytes length:length];
        return;
    }
    [_pending appendBytes:bytes length:length];

    if (!headersDone) {
        const uint8_t *p = [_pending bytes];
        NSUInteger len = [_pending length];
        NSUInteger end = NSNotFound;
        for (NSUInteger i = 0; i + 3 < len; i++) {
            if (p[i] == '\r' && p[i + 1] == '\n' && p[i + 2] == '\r' && p[i + 3] == '\n') { end = i; break; }
        }
        if (end == NSNotFound) {
            if (len > kMaxHeaderBytes) [self fail:CPTLSErrorProtocol message:@"Response headers too large"];
            return;
        }
        NSString *head = [[NSString alloc] initWithBytes:p length:end encoding:NSISOLatin1StringEncoding];
        [self parseHeaders:head];
        [head release];
        [_pending replaceBytesInRange:NSMakeRange(0, end + 4) withBytes:NULL length:0];
        if (complete && error) return;
        if (statusCode >= 100 && statusCode < 200) {
            /* an interim 1xx response; the real one follows on the same connection */
            statusCode = 0; _chunked = NO; _contentLength = -1; complete = NO;
            [self feed:"" length:0];
            return;
        }
        headersDone = YES;
        if (complete) return;

        if (!_chunked) {
            NSData *rest = [[_pending copy] autorelease];
            [_pending setLength:0];
            [self emit:[rest bytes] length:[rest length]];
            return;
        }
    }
    [self drainChunked];
}

- (void)finishAtEOF {
    if (complete) return;
    if (!headersDone) {
        [self fail:CPTLSErrorProtocol message:@"Connection closed before response headers"];
    } else if (_chunked || (_contentLength >= 0 && (long long)_received < _contentLength)) {
        [self fail:CPTLSErrorIO message:@"Connection closed before response completed"];
    }
    complete = YES;
}

@end
