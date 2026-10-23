/*
 * ToolInputCheck.m
 * LegacyPodClaw - pure checks OCToolDispatcher runs before a tool call
 */

#import "ToolInputCheck.h"

static BOOL ValueMatchesType(id value, NSString *type) {
    if (!type) return YES;
    if ([type isEqualToString:@"string"]) return [value isKindOfClass:[NSString class]];
    if ([type isEqualToString:@"object"]) return [value isKindOfClass:[NSDictionary class]];
    if ([type isEqualToString:@"array"]) return [value isKindOfClass:[NSArray class]];
    if ([type isEqualToString:@"number"] || [type isEqualToString:@"integer"] || [type isEqualToString:@"boolean"])
        return [value isKindOfClass:[NSNumber class]];
    return YES;
}

NSString *OCToolSchemaProblem(NSDictionary *schema, NSDictionary *input) {
    if (![schema isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *props = [schema objectForKey:@"properties"];
    for (NSString *key in [schema objectForKey:@"required"]) {
        id value = [input objectForKey:key];
        if (!value || value == [NSNull null]) return [NSString stringWithFormat:@"missing required parameter '%@'", key];
    }
    for (NSString *key in input) {
        NSString *type = [[props objectForKey:key] objectForKey:@"type"];
        if (![type isKindOfClass:[NSString class]]) continue;
        if (!ValueMatchesType([input objectForKey:key], type))
            return [NSString stringWithFormat:@"parameter '%@' must be of type %@", key, type];
    }
    return nil;
}

/* fields that decide what a call does; the user must see them whole */
NSArray *OCToolApprovalFields(void) {
    return @[@"command", @"path", @"url", @"to", @"recipient", @"bundle_id", @"query"];
}

/* make spaces, tabs and line breaks visible, so padding cannot hide the rest of a command */
NSString *OCToolVisibleText(NSString *value) {
    NSMutableString *out = [NSMutableString stringWithCapacity:[value length]];
    NSUInteger spaces = 0;
    for (NSUInteger i = 0; i < [value length]; i++) {
        unichar c = [value characterAtIndex:i];
        if (c == ' ') { spaces++; continue; }
        if (spaces > 1) [out appendFormat:@"[%lu spaces]", (unsigned long)spaces];
        else if (spaces == 1) [out appendString:@" "];
        spaces = 0;
        if (c == '\n') [out appendString:@"⏎\n"];
        else if (c == '\t') [out appendString:@"[tab]"];
        else if (c < 0x20 || c == 0x7f) [out appendFormat:@"[0x%02x]", c];
        else [out appendFormat:@"%C", c];
    }
    if (spaces > 1) [out appendFormat:@"[%lu spaces]", (unsigned long)spaces];
    else if (spaces == 1) [out appendString:@"[space]"];
    return out;
}

NSString *OCToolApprovalText(NSDictionary *input, BOOL *tooLong) {
    NSMutableString *text = [NSMutableString string];
    for (NSString *key in OCToolApprovalFields()) {
        id value = [input objectForKey:key];
        if (!value) continue;
        NSString *str = [value isKindOfClass:[NSString class]] ? value : [value description];
        if ([str length] > OC_TOOL_KEY_FIELD_MAX) { *tooLong = YES; return nil; }
        [text appendFormat:@"%@: %@\n", key, OCToolVisibleText(str)];
    }
    return text;
}

/* cut at a character boundary, so a split multi-byte sequence does not garble the whole output */
NSUInteger OCUtf8SafeLength(const uint8_t *bytes, NSUInteger length) {
    NSUInteger i = length;
    NSUInteger back = 0;
    while (i > 0 && back < 4 && (bytes[i - 1] & 0xC0) == 0x80) { i--; back++; }
    if (i == 0) return length;
    uint8_t lead = bytes[i - 1];
    NSUInteger need = (lead & 0x80) == 0 ? 1 : (lead & 0xE0) == 0xC0 ? 2 : (lead & 0xF0) == 0xE0 ? 3 : (lead & 0xF8) == 0xF0 ? 4 : 1;
    return (back + 1 >= need) ? length : i - 1;
}
