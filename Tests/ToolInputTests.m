/*
 * ToolInputTests.m
 * LegacyPodClaw - schema checks, approval text and utf-8 truncation
 */

#import "TestHarness.h"
#import "ToolInputCheck.h"

void RunToolInputTests(void) {
    NSDictionary *schema = @{@"type": @"object",
        @"properties": @{@"command": @{@"type": @"string"}, @"count": @{@"type": @"integer"}},
        @"required": @[@"command"]};
    CHECK(OCToolSchemaProblem(schema, @{@"command": @"ls"}) == nil, @"valid input passes");
    CHECK(OCToolSchemaProblem(schema, @{}) != nil, @"missing required key fails");
    CHECK(OCToolSchemaProblem(schema, @{@"command": [NSNull null]}) != nil, @"null required key fails");
    CHECK(OCToolSchemaProblem(schema, @{@"command": @5}) != nil, @"wrong type fails");
    CHECK(OCToolSchemaProblem(schema, @{@"command": @"ls", @"count": @"3"}) != nil, @"string for integer fails");
    CHECK(OCToolSchemaProblem(nil, @{@"x": @1}) == nil, @"no schema accepts input");

    NSString *padded = [NSString stringWithFormat:@"ls%@; rm -rf /x", [@"" stringByPaddingToLength:400 withString:@" " startingAtIndex:0]];
    BOOL tooLong = NO;
    NSString *text = OCToolApprovalText(@{@"command": padded}, &tooLong);
    CHECK(!tooLong && [text rangeOfString:@"[400 spaces]"].location != NSNotFound, @"padding made visible: %@", text);
    CHECK([text rangeOfString:@"rm -rf /x"].location != NSNotFound, @"text after padding shown");

    text = OCToolApprovalText(@{@"command": @"a\tb\nc\x01"}, &tooLong);
    CHECK([text rangeOfString:@"[tab]"].location != NSNotFound && [text rangeOfString:@"[0x01]"].location != NSNotFound,
          @"tab and control chars visible: %@", text);
    text = OCToolApprovalText(@{@"command": @"ls "}, &tooLong);
    CHECK([text rangeOfString:@"[space]"].location != NSNotFound, @"trailing space visible");

    tooLong = NO;
    text = OCToolApprovalText(@{@"path": [@"" stringByPaddingToLength:OC_TOOL_KEY_FIELD_MAX + 1 withString:@"a" startingAtIndex:0]}, &tooLong);
    CHECK(tooLong && text == nil, @"over-long key field refused");

    const uint8_t euro[] = {'a', 0xE2, 0x82, 0xAC};
    CHECK(OCUtf8SafeLength(euro, 4) == 4, @"complete sequence kept");
    CHECK(OCUtf8SafeLength(euro, 3) == 1, @"cut before split 3-byte sequence");
    CHECK(OCUtf8SafeLength(euro, 2) == 1, @"cut before lone lead byte");
    const uint8_t ascii[] = {'a', 'b'};
    CHECK(OCUtf8SafeLength(ascii, 2) == 2, @"ascii untouched");
}
