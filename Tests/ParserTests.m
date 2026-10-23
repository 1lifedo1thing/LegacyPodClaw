/*
 * ParserTests.m
 * LegacyPodClaw - CPHTTPResponseParser framing tests
 */

#import "TestHarness.h"
#import "HTTPResponseParser.h"

static CPHTTPResponseParser *Parse(NSArray *pieces, BOOL eof) {
    CPHTTPResponseParser *p = [[[CPHTTPResponseParser alloc] initWithChunkHandler:nil] autorelease];
    for (NSString *piece in pieces) {
        NSData *d = [piece dataUsingEncoding:NSISOLatin1StringEncoding];
        [p feed:[d bytes] length:[d length]];
    }
    if (eof) [p finishAtEOF];
    return p;
}

static NSString *Body(CPHTTPResponseParser *p) {
    return [[[NSString alloc] initWithData:[p body] encoding:NSISOLatin1StringEncoding] autorelease];
}

static NSArray *Bytewise(NSString *s) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSUInteger i = 0; i < [s length]; i++) [out addObject:[s substringWithRange:NSMakeRange(i, 1)]];
    return out;
}

void RunParserTests(void) {
    CPHTTPResponseParser *p;

    p = Parse(@[@"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel", @"lo"], NO);
    CHECK(p->complete && !p->error && p->statusCode == 200, @"content-length split body");
    CHECK([Body(p) isEqualToString:@"hello"], @"body is %@", Body(p));

    p = Parse(@[@"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nabEXTRA"], NO);
    CHECK([Body(p) isEqualToString:@"ab"], @"bytes past content-length dropped, got %@", Body(p));

    NSString *chunked = @"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4;ext=1\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n";
    p = Parse(@[chunked], NO);
    CHECK(p->complete && !p->error && [Body(p) isEqualToString:@"Wikipedia"], @"chunked with extension: %@", Body(p));
    p = Parse(Bytewise(chunked), NO);
    CHECK(p->complete && !p->error && [Body(p) isEqualToString:@"Wikipedia"], @"chunked fed byte by byte: %@", Body(p));

    p = Parse(@[@"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n00000000000000000000a\r\n"], NO);
    CHECK(p->error != nil, @"over-long chunk size rejected");
    p = Parse(@[@"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n"], NO);
    CHECK(p->error != nil, @"non-hex chunk size rejected");
    p = Parse(@[@"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabcXY0\r\n\r\n"], NO);
    CHECK(p->error != nil, @"missing crlf after chunk rejected");

    p = Parse(@[@"HTTP/1.1 200 OK\r\nContent-Length: 12abc\r\n\r\n"], NO);
    CHECK(p->error != nil, @"malformed content-length rejected");

    p = Parse(@[@"HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 201 Created\r\nContent-Length: 2\r\n\r\nok"], NO);
    CHECK(p->complete && !p->error && p->statusCode == 201 && [Body(p) isEqualToString:@"ok"],
          @"interim 100 skipped, status %ld", (long)p->statusCode);

    p = Parse(@[@"HTTP/1.1 204 No Content\r\n\r\n"], NO);
    CHECK(p->complete && !p->error && [[p body] length] == 0, @"204 completes with no body");

    p = Parse(@[@"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc"], YES);
    CHECK(p->error != nil, @"eof before content-length is an error");
    p = Parse(@[@"HTTP/1.1 200 OK\r\n\r\nuntil close"], YES);
    CHECK(!p->error && [Body(p) isEqualToString:@"until close"], @"body delimited by eof");
    p = Parse(@[@"HTTP/1.1 200 OK\r\nContent-"], YES);
    CHECK(p->error != nil, @"eof inside headers is an error");

    p = Parse(@[@"garbage\r\n\r\n"], NO);
    CHECK(p->error != nil, @"bad status line rejected");

    NSMutableString *huge = [NSMutableString stringWithString:@"HTTP/1.1 200 OK\r\nX: "];
    while ([huge length] < 70 * 1024) [huge appendString:@"aaaaaaaaaaaaaaaa"];
    p = Parse(@[huge], NO);
    CHECK(p->error != nil, @"oversized headers rejected");
}
