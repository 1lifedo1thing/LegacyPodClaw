/*
 * ToolDispatcher.m
 * LegacyPodClaw - the one path every tool call takes
 */

#import "ToolDispatcher.h"
#import "Guardrails.h"
#import <UIKit/UIKit.h>

#define TOOL_DEFAULT_TIMEOUT 30.0
#define CONFIRM_TIMEOUT 60.0
#define RESULT_MAX_CHARS 16384
#define SUMMARY_MAX_CHARS 400

static NSString *const OCToolErrorDomain = @"OCToolDispatcher";

static NSError *ToolError(NSString *message) {
    return [NSError errorWithDomain:OCToolErrorDomain code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

#pragma mark - Confirmation

@interface _OCToolConfirmation : NSObject <UIAlertViewDelegate> {
    UIAlertView *_alert;
    void (^_decision)(BOOL allowed);
}
- (instancetype)initWithTitle:(NSString *)title message:(NSString *)message decision:(void(^)(BOOL))decision;
- (void)show;
@end

@implementation _OCToolConfirmation

- (instancetype)initWithTitle:(NSString *)title message:(NSString *)message decision:(void(^)(BOOL))decision {
    if ((self = [super init])) {
        _decision = [decision copy];
        _alert = [[UIAlertView alloc] initWithTitle:title message:message delegate:self
                                  cancelButtonTitle:@"Deny" otherButtonTitles:@"Allow", nil];
    }
    return self;
}

- (void)show {
    /* the alert does not retain its delegate, so keep self alive until a decision */
    [self retain];
    [_alert show];
    [self performSelector:@selector(_expire) withObject:nil afterDelay:CONFIRM_TIMEOUT];
}

- (void)_finish:(BOOL)allowed {
    if (!_decision) return;
    void (^decision)(BOOL) = [_decision autorelease];
    _decision = nil;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_expire) object:nil];
    _alert.delegate = nil;
    decision(allowed);
    [self autorelease];
}

- (void)_expire {
    [_alert dismissWithClickedButtonIndex:_alert.cancelButtonIndex animated:YES];
    [self _finish:NO];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    [self _finish:buttonIndex != alertView.cancelButtonIndex];
}

- (void)dealloc {
    [_alert release];
    [_decision release];
    [super dealloc];
}

@end

#pragma mark - Dispatcher

@implementation OCToolDispatcher

+ (instancetype)shared {
    static OCToolDispatcher *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

+ (OCToolDefinition *)toolNamed:(NSString *)name inTools:(NSArray *)tools {
    if (![name isKindOfClass:[NSString class]]) return nil;
    for (OCToolDefinition *t in tools)
        if ([t.name isEqualToString:name]) return t;
    return nil;
}

static BOOL ValueMatchesType(id value, NSString *type) {
    if (!type) return YES;
    if ([type isEqualToString:@"string"]) return [value isKindOfClass:[NSString class]];
    if ([type isEqualToString:@"object"]) return [value isKindOfClass:[NSDictionary class]];
    if ([type isEqualToString:@"array"]) return [value isKindOfClass:[NSArray class]];
    if ([type isEqualToString:@"number"] || [type isEqualToString:@"integer"] || [type isEqualToString:@"boolean"])
        return [value isKindOfClass:[NSNumber class]];
    return YES;
}

static NSString *SchemaProblem(NSDictionary *schema, NSDictionary *input) {
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

/* file tools whose path argument the guardrails must see first */
static BOOL PathCheckForTool(NSString *name, OCFileOp *op) {
    static NSDictionary *ops;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ops = [@{@"write_file": @(OCFileOpWrite), @"edit_file": @(OCFileOpEdit),
                 @"delete_file": @(OCFileOpDelete), @"list_files": @(OCFileOpRead),
                 @"read_file": @(OCFileOpRead)} retain];
    });
    NSNumber *n = [ops objectForKey:name];
    if (!n) return NO;
    *op = (OCFileOp)[n unsignedIntegerValue];
    return YES;
}

static NSString *InputSummary(NSDictionary *input) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:input options:0 error:nil];
    NSString *s = json ? [[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] autorelease] : @"{}";
    if ([s length] > SUMMARY_MAX_CHARS) s = [[s substringToIndex:SUMMARY_MAX_CHARS] stringByAppendingString:@"…"];
    return s;
}

static NSString *ResultString(id result) {
    NSString *s;
    if (!result || result == [NSNull null]) s = @"";
    else if ([result isKindOfClass:[NSString class]]) s = result;
    else if ([NSJSONSerialization isValidJSONObject:result]) {
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        s = [[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] autorelease] ?: @"";
    } else s = [result description];
    if ([s length] > RESULT_MAX_CHARS)
        s = [[s substringToIndex:RESULT_MAX_CHARS] stringByAppendingString:@"\n[result truncated]"];
    return s;
}

static NSString *CallerText(OCToolCaller caller) {
    switch (caller) {
        case OCToolCallerRemote: return @"A remote gateway client";
        case OCToolCallerChannel: return @"A chat channel message";
        case OCToolCallerAgent: return @"The background agent";
        default: return @"The assistant";
    }
}

- (void)runTool:(OCToolDefinition *)tool
          input:(id)input
         caller:(OCToolCaller)caller
     completion:(void(^)(NSString *result, NSError *error))completion {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self runTool:tool input:input caller:caller completion:completion];
        });
        return;
    }
    if (!tool || !tool.handler) { completion(nil, ToolError(@"tool not found")); return; }
    if (!input || input == [NSNull null]) input = @{};
    if (![input isKindOfClass:[NSDictionary class]]) {
        completion(nil, ToolError(@"tool input must be a JSON object"));
        return;
    }

    NSString *problem = SchemaProblem(tool.inputSchema, input);
    if (problem) { completion(nil, ToolError(problem)); return; }

    BOOL confirm = tool.requiresConfirmation || caller == OCToolCallerChannel;
    NSString *reason = nil;
    OCFileOp op;
    if (PathCheckForTool(tool.name, &op)) {
        id path = [input objectForKey:@"path"];
        OCGuardrailVerdict *v = [[OCGuardrails shared] checkPath:[path isKindOfClass:[NSString class]] ? path : nil
                                                    forOperation:op];
        if (v.action == OCGuardrailBlock) { completion(nil, ToolError(v.reason)); return; }
        if (v.action == OCGuardrailConfirm) { confirm = YES; reason = v.reason; }
    }

    void (^run)(void) = ^{ [self _invoke:tool input:input completion:completion]; };
    if (!confirm) { run(); return; }

    NSMutableString *message = [NSMutableString stringWithFormat:@"%@ wants to run \"%@\".\n\n%@",
                                CallerText(caller), tool.name, InputSummary(input)];
    if (reason) [message appendFormat:@"\n\n%@", reason];
    _OCToolConfirmation *c = [[_OCToolConfirmation alloc] initWithTitle:@"Allow Tool?" message:message
        decision:^(BOOL allowed) {
            if (allowed) run();
            else completion(nil, ToolError(@"the user denied this tool call"));
        }];
    [c show];
    [c release];
}

- (void)_invoke:(OCToolDefinition *)tool input:(NSDictionary *)input
     completion:(void(^)(NSString *result, NSError *error))completion {
    /* the flag lives on the heap so the handler and the timer share it */
    __block BOOL done = NO;
    void (^finish)(NSString *, NSError *) = [[^(NSString *result, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (done) return;
            done = YES;
            completion(result, error);
        });
    } copy] autorelease];

    NSTimeInterval timeout = tool.timeout > 0 ? tool.timeout : TOOL_DEFAULT_TIMEOUT;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        finish(nil, ToolError([NSString stringWithFormat:@"tool timed out after %.0f s", timeout]));
    });

    @try {
        tool.handler(input, ^(id result, NSError *error) {
            if (error) finish(nil, error);
            else finish(ResultString(result), nil);
        });
    } @catch (NSException *e) {
        finish(nil, ToolError([NSString stringWithFormat:@"tool raised %@: %@", [e name], [e reason]]));
    }
}

@end
