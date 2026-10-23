/* request bodies and stream parsers for anthropic messages and openai chat completions */

#import "ProviderFormats.h"
#import "Agent.h"

static NSString *JSONString(id object) {
    if (!object || ![NSJSONSerialization isValidJSONObject:object]) return @"{}";
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    NSString *s = data ? [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] : nil;
    return s ?: @"{}";
}

static NSDictionary *ParseJSONObject(NSString *s) {
    if ([s length] == 0) return @{};
    id obj = [NSJSONSerialization JSONObjectWithData:[s dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

static NSDictionary *ToolSchema(OCToolDefinition *tool) {
    NSDictionary *schema = tool.inputSchema;
    return [schema isKindOfClass:[NSDictionary class]] ? schema : @{@"type": @"object", @"properties": @{}};
}

NSString *OCProviderErrorMessage(NSData *body) {
    if ([body length] == 0) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    if ([json isKindOfClass:[NSArray class]] && [json count]) json = [json objectAtIndex:0];
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    id err = [json objectForKey:@"error"];
    if ([err isKindOfClass:[NSDictionary class]]) {
        id msg = [err objectForKey:@"message"];
        if ([msg isKindOfClass:[NSString class]]) return msg;
    }
    if ([err isKindOfClass:[NSString class]]) return err;
    id msg = [json objectForKey:@"message"];
    return [msg isKindOfClass:[NSString class]] ? msg : nil;
}

#pragma mark - Anthropic request

static void AppendTurn(NSMutableArray *turns, NSString *role, NSArray *blocks) {
    if ([blocks count] == 0) return;
    NSMutableDictionary *last = [turns lastObject];
    /* the api wants user and assistant turns to alternate, so neighbours with one role merge */
    if (last && [[last objectForKey:@"role"] isEqualToString:role]) {
        [[last objectForKey:@"content"] addObjectsFromArray:blocks];
        return;
    }
    [turns addObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:
                      role, @"role", [NSMutableArray arrayWithArray:blocks], @"content", nil]];
}

/* the generation five models think by default and accept an effort level */
static BOOL AlwaysThinks(NSString *model) {
    for (NSString *family in @[@"claude-opus-5", @"claude-sonnet-5", @"claude-haiku-5", @"claude-fable-5", @"claude-mythos-5"])
        if ([model hasPrefix:family]) return YES;
    return NO;
}

NSDictionary *OCAnthropicRequestBody(NSString *model, NSString *system, NSArray *messages,
                                     NSArray *tools, NSUInteger maxTokens) {
    NSMutableArray *turns = [NSMutableArray arrayWithCapacity:[messages count]];
    for (id<OCProviderMessage> m in messages) {
        NSMutableArray *blocks = [NSMutableArray array];
        switch (m.role) {
            case OCAgentRoleUser:
                if ([m.content length]) [blocks addObject:@{@"type": @"text", @"text": m.content}];
                AppendTurn(turns, @"user", blocks);
                break;
            case OCAgentRoleAssistant:
                if ([m.rawContent count]) {
                    [blocks addObjectsFromArray:m.rawContent];
                } else {
                    if ([m.content length]) [blocks addObject:@{@"type": @"text", @"text": m.content}];
                    for (OCProviderToolCall *call in m.toolCalls) {
                        [blocks addObject:@{@"type": @"tool_use", @"id": call.callId ?: @"",
                                            @"name": call.name ?: @"", @"input": call.input ?: @{}}];
                    }
                }
                AppendTurn(turns, @"assistant", blocks);
                break;
            case OCAgentRoleTool: {
                NSMutableDictionary *r = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                    @"tool_result", @"type", m.toolCallId ?: @"", @"tool_use_id", m.content ?: @"", @"content", nil];
                if (m.isError) [r setObject:@YES forKey:@"is_error"];
                [blocks addObject:r];
                AppendTurn(turns, @"user", blocks);
                break;
            }
            default:
                break;
        }
    }

    NSMutableDictionary *body = [NSMutableDictionary dictionaryWithCapacity:8];
    [body setObject:model forKey:@"model"];
    if (AlwaysThinks(model)) {
        /* thinking on these models cannot be switched off and is paid from max_tokens, so a small budget leaves no reply */
        maxTokens = MAX(maxTokens, (NSUInteger)4096);
        [body setObject:@{@"effort": [tools count] ? @"medium" : @"low"} forKey:@"output_config"];
    }
    [body setObject:@(maxTokens) forKey:@"max_tokens"];
    [body setObject:@YES forKey:@"stream"];
    [body setObject:turns forKey:@"messages"];
    if ([system length]) [body setObject:system forKey:@"system"];
    if ([tools count]) {
        NSMutableArray *defs = [NSMutableArray arrayWithCapacity:[tools count]];
        for (OCToolDefinition *t in tools) {
            [defs addObject:@{@"name": t.name, @"description": t.toolDescription ?: @"",
                              @"input_schema": ToolSchema(t)}];
        }
        [body setObject:defs forKey:@"tools"];
    }
    return body;
}

#pragma mark - OpenAI request

NSDictionary *OCOpenAIRequestBody(OCProviderInfo *info, NSString *model, NSString *system,
                                  NSArray *messages, NSArray *tools, NSUInteger maxTokens) {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:[messages count] + 1];
    if ([system length]) [out addObject:@{@"role": @"system", @"content": system}];
    for (id<OCProviderMessage> m in messages) {
        switch (m.role) {
            case OCAgentRoleUser:
                if ([m.content length]) [out addObject:@{@"role": @"user", @"content": m.content}];
                break;
            case OCAgentRoleAssistant: {
                if ([m.content length] == 0 && [m.toolCalls count] == 0) break;
                NSMutableDictionary *a = [NSMutableDictionary dictionaryWithObject:@"assistant" forKey:@"role"];
                [a setObject:[m.content length] ? m.content : (id)[NSNull null] forKey:@"content"];
                if ([m.toolCalls count]) {
                    NSMutableArray *calls = [NSMutableArray array];
                    for (OCProviderToolCall *c in m.toolCalls) {
                        [calls addObject:@{@"id": c.callId ?: @"", @"type": @"function",
                                           @"function": @{@"name": c.name ?: @"", @"arguments": JSONString(c.input ?: @{})}}];
                    }
                    [a setObject:calls forKey:@"tool_calls"];
                }
                [out addObject:a];
                break;
            }
            case OCAgentRoleTool:
                [out addObject:@{@"role": @"tool", @"tool_call_id": m.toolCallId ?: @"", @"content": m.content ?: @""}];
                break;
            default:
                break;
        }
    }

    NSMutableDictionary *body = [NSMutableDictionary dictionaryWithCapacity:8];
    [body setObject:model forKey:@"model"];
    [body setObject:out forKey:@"messages"];
    [body setObject:@YES forKey:@"stream"];
    /* openai reasoning models refuse max_tokens; the compatible services still expect it */
    [body setObject:@(maxTokens) forKey:[info.providerId isEqualToString:@"openai"] ? @"max_completion_tokens" : @"max_tokens"];
    if ([tools count]) {
        NSMutableArray *defs = [NSMutableArray arrayWithCapacity:[tools count]];
        for (OCToolDefinition *t in tools) {
            [defs addObject:@{@"type": @"function", @"function": @{
                @"name": t.name, @"description": t.toolDescription ?: @"", @"parameters": ToolSchema(t)}}];
        }
        [body setObject:defs forKey:@"tools"];
    }
    return body;
}

#pragma mark - Parsers

@interface OCStreamParser ()
- (void)_emit:(NSString *)text;
- (void)_setError:(NSString *)message;
@end

@implementation OCStreamParser
@synthesize onText = _onText, streamError = _streamError;
- (void)dealloc { [_onText release]; [_streamError release]; [super dealloc]; }
- (void)handleEvent:(NSDictionary *)event {}
- (OCProviderResult *)result { return [[[OCProviderResult alloc] init] autorelease]; }
- (void)_emit:(NSString *)text { if ([text length] && _onText) _onText(text); }
- (void)_setError:(NSString *)message {
    if (_streamError) return;
    _streamError = [(message ?: @"The provider reported an error") copy];
}
@end

@interface OCAnthropicStreamParser () {
    NSMutableArray *_blocks;
    NSMutableDictionary *_partialJSON;
    NSString *_stopReason;
    NSUInteger _inTokens, _outTokens;
}
@end

@implementation OCAnthropicStreamParser

- (id)init {
    if ((self = [super init])) {
        _blocks = [[NSMutableArray alloc] init];
        _partialJSON = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)dealloc { [_blocks release]; [_partialJSON release]; [_stopReason release]; [super dealloc]; }

- (NSMutableDictionary *)_blockAt:(id)index {
    NSUInteger i = [index respondsToSelector:@selector(unsignedIntegerValue)] ? [index unsignedIntegerValue] : NSNotFound;
    return i < [_blocks count] ? [_blocks objectAtIndex:i] : nil;
}

- (void)handleEvent:(NSDictionary *)event {
    NSString *type = [event objectForKey:@"type"];
    if ([type isEqualToString:@"content_block_start"]) {
        NSDictionary *block = [event objectForKey:@"content_block"];
        if (![block isKindOfClass:[NSDictionary class]]) return;
        NSUInteger index = [[event objectForKey:@"index"] unsignedIntegerValue];
        while ([_blocks count] < index) [_blocks addObject:[NSMutableDictionary dictionary]];
        if ([_blocks count] == index) [_blocks addObject:[[block mutableCopy] autorelease]];
    } else if ([type isEqualToString:@"content_block_delta"]) {
        NSMutableDictionary *block = [self _blockAt:[event objectForKey:@"index"]];
        NSDictionary *delta = [event objectForKey:@"delta"];
        NSString *dt = [delta objectForKey:@"type"];
        if (!block) return;
        if ([dt isEqualToString:@"text_delta"]) {
            NSString *t = [delta objectForKey:@"text"];
            if (![t isKindOfClass:[NSString class]]) return;
            [block setObject:[([block objectForKey:@"text"] ?: @"") stringByAppendingString:t] forKey:@"text"];
            [self _emit:t];
        } else if ([dt isEqualToString:@"thinking_delta"]) {
            NSString *t = [delta objectForKey:@"thinking"] ?: @"";
            [block setObject:[([block objectForKey:@"thinking"] ?: @"") stringByAppendingString:t] forKey:@"thinking"];
        } else if ([dt isEqualToString:@"signature_delta"]) {
            NSString *sig = [delta objectForKey:@"signature"] ?: @"";
            [block setObject:[([block objectForKey:@"signature"] ?: @"") stringByAppendingString:sig] forKey:@"signature"];
        } else if ([dt isEqualToString:@"input_json_delta"]) {
            NSString *key = [[event objectForKey:@"index"] description];
            NSMutableString *buf = [_partialJSON objectForKey:key];
            if (!buf) { buf = [NSMutableString string]; [_partialJSON setObject:buf forKey:key]; }
            [buf appendString:[delta objectForKey:@"partial_json"] ?: @""];
        }
    } else if ([type isEqualToString:@"message_start"]) {
        _inTokens = [[[[event objectForKey:@"message"] objectForKey:@"usage"] objectForKey:@"input_tokens"] unsignedIntegerValue];
    } else if ([type isEqualToString:@"message_delta"]) {
        NSString *stop = [[event objectForKey:@"delta"] objectForKey:@"stop_reason"];
        if ([stop isKindOfClass:[NSString class]]) { [_stopReason release]; _stopReason = [stop copy]; }
        NSUInteger out = [[[event objectForKey:@"usage"] objectForKey:@"output_tokens"] unsignedIntegerValue];
        if (out) _outTokens = out;
    } else if ([type isEqualToString:@"error"]) {
        [self _setError:[[event objectForKey:@"error"] objectForKey:@"message"]];
    }
}

- (OCProviderResult *)result {
    OCProviderResult *r = [[[OCProviderResult alloc] init] autorelease];
    NSMutableString *text = [NSMutableString string];
    NSMutableArray *calls = [NSMutableArray array];
    NSMutableArray *raw = [NSMutableArray arrayWithCapacity:[_blocks count]];
    for (NSUInteger i = 0; i < [_blocks count]; i++) {
        NSMutableDictionary *block = [_blocks objectAtIndex:i];
        NSString *type = [block objectForKey:@"type"];
        if (!type) continue;
        if ([type isEqualToString:@"text"]) {
            NSString *t = [block objectForKey:@"text"] ?: @"";
            [text appendString:t];
            /* an empty text block is rejected when it is sent back */
            if ([t length] == 0) continue;
        } else if ([type isEqualToString:@"tool_use"]) {
            NSString *json = [_partialJSON objectForKey:[@(i) description]];
            NSDictionary *input = json ? ParseJSONObject(json) : ([block objectForKey:@"input"] ?: @{});
            [block setObject:input ?: @{} forKey:@"input"];
            OCProviderToolCall *call = [[[OCProviderToolCall alloc] init] autorelease];
            call.callId = [block objectForKey:@"id"];
            call.name = [block objectForKey:@"name"];
            call.input = input;
            [calls addObject:call];
        }
        [raw addObject:block];
    }
    r.text = text;
    r.toolCalls = calls;
    r.rawContent = raw;
    r.stopReason = _stopReason;
    r.inputTokens = _inTokens;
    r.outputTokens = _outTokens;
    return r;
}

@end

@interface OCOpenAIStreamParser () {
    NSMutableString *_text;
    NSMutableArray *_calls; /* of mutable dictionaries: id, name, arguments */
    NSString *_finish;
    NSUInteger _inTokens, _outTokens;
}
@end

@implementation OCOpenAIStreamParser

- (id)init {
    if ((self = [super init])) {
        _text = [[NSMutableString alloc] init];
        _calls = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc { [_text release]; [_calls release]; [_finish release]; [super dealloc]; }

- (void)handleEvent:(NSDictionary *)event {
    id err = [event objectForKey:@"error"];
    if (err) {
        [self _setError:[err isKindOfClass:[NSDictionary class]] ? [err objectForKey:@"message"] : [err description]];
        return;
    }
    NSDictionary *usage = [event objectForKey:@"usage"];
    if ([usage isKindOfClass:[NSDictionary class]]) {
        _inTokens = [[usage objectForKey:@"prompt_tokens"] unsignedIntegerValue];
        _outTokens = [[usage objectForKey:@"completion_tokens"] unsignedIntegerValue];
    }
    NSArray *choices = [event objectForKey:@"choices"];
    if (![choices isKindOfClass:[NSArray class]] || [choices count] == 0) return;
    NSDictionary *choice = [choices objectAtIndex:0];
    NSDictionary *delta = [choice objectForKey:@"delta"];
    NSString *content = [delta objectForKey:@"content"];
    if ([content isKindOfClass:[NSString class]]) { [_text appendString:content]; [self _emit:content]; }

    NSArray *toolDeltas = [delta objectForKey:@"tool_calls"];
    if ([toolDeltas isKindOfClass:[NSArray class]]) {
        for (NSDictionary *td in toolDeltas) {
            if (![td isKindOfClass:[NSDictionary class]]) continue;
            id idx = [td objectForKey:@"index"];
            NSString *callId = [td objectForKey:@"id"];
            NSMutableDictionary *entry = nil;
            if ([idx respondsToSelector:@selector(unsignedIntegerValue)]) {
                NSUInteger i = [idx unsignedIntegerValue];
                while ([_calls count] <= i && i < 64) [_calls addObject:[NSMutableDictionary dictionary]];
                if (i < [_calls count]) entry = [_calls objectAtIndex:i];
            } else if ([callId length] || [_calls count] == 0) {
                /* some services leave out the index and send each call whole */
                entry = [NSMutableDictionary dictionary];
                [_calls addObject:entry];
            } else {
                entry = [_calls lastObject];
            }
            if (!entry) continue;
            if ([callId isKindOfClass:[NSString class]] && [callId length]) [entry setObject:callId forKey:@"id"];
            NSDictionary *fn = [td objectForKey:@"function"];
            NSString *name = [fn objectForKey:@"name"];
            if ([name isKindOfClass:[NSString class]] && [name length]) [entry setObject:name forKey:@"name"];
            id args = [fn objectForKey:@"arguments"];
            if ([args isKindOfClass:[NSDictionary class]]) args = JSONString(args);
            if ([args isKindOfClass:[NSString class]]) {
                [entry setObject:[([entry objectForKey:@"arguments"] ?: @"") stringByAppendingString:args] forKey:@"arguments"];
            }
        }
    }
    NSString *finish = [choice objectForKey:@"finish_reason"];
    if ([finish isKindOfClass:[NSString class]]) { [_finish release]; _finish = [finish copy]; }
}

- (OCProviderResult *)result {
    OCProviderResult *r = [[[OCProviderResult alloc] init] autorelease];
    NSMutableArray *calls = [NSMutableArray array];
    NSUInteger n = 0;
    for (NSDictionary *entry in _calls) {
        NSString *name = [entry objectForKey:@"name"];
        if ([name length] == 0) continue;
        OCProviderToolCall *call = [[[OCProviderToolCall alloc] init] autorelease];
        call.callId = [entry objectForKey:@"id"] ?: [NSString stringWithFormat:@"call_%lu", (unsigned long)n];
        call.name = name;
        call.input = ParseJSONObject([entry objectForKey:@"arguments"]);
        [calls addObject:call];
        n++;
    }
    r.text = _text;
    r.toolCalls = calls;
    r.stopReason = [calls count] && ![_finish isEqualToString:@"length"] ? @"tool_calls" : _finish;
    r.inputTokens = _inTokens;
    r.outputTokens = _outTokens;
    return r;
}

@end
