/*
 * HTTPResponseParser.h
 * LegacyPodClaw - incremental HTTP/1.1 response parser used by CPTLSClient
 *
 * Kept apart from TLSClient.m so the host test target can build it without wolfSSL.
 */

#import "TLSClient.h"

@interface CPHTTPResponseParser : NSObject {
@public
    NSInteger statusCode;
    BOOL headersDone;
    BOOL complete;
    NSError *error;
@private
    NSMutableData *_pending;
    NSMutableData *_body;
    BOOL _chunked;
    long long _contentLength;
    unsigned long long _chunkRemain;
    unsigned long long _received;
    BOOL _needChunkSize;
    CPHTTPSStreamChunk _onChunk;
}
- (id)initWithChunkHandler:(CPHTTPSStreamChunk)onChunk;
- (void)feed:(const char *)bytes length:(NSUInteger)length;
- (void)finishAtEOF;
- (NSData *)body;
@end
