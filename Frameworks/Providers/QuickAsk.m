/* text-only asks for springboard through the provider client the app uses */

#import "QuickAsk.h"
#import "Agent.h"
#import "SecretStore.h"

static NSString *PrefString(NSDictionary *prefs, NSString *key) {
    id v = key ? [prefs objectForKey:key] : nil;
    return ([v isKindOfClass:[NSString class]] && [v length]) ? v : nil;
}

/* one turn in the shape the request builders read; springboard does not link OCAgentMessage */
@interface _OCQuickMessage : NSObject <OCProviderMessage> {
    OCAgentMessageRole _role;
    NSString *_content;
}
- (id)initWithRole:(OCAgentMessageRole)role content:(NSString *)content;
@end

@implementation _OCQuickMessage
- (id)initWithRole:(OCAgentMessageRole)role content:(NSString *)content {
    if ((self = [super init])) { _role = role; _content = [content copy]; }
    return self;
}
- (void)dealloc { [_content release]; [super dealloc]; }
- (OCAgentMessageRole)role { return _role; }
- (NSString *)content { return _content; }
- (NSString *)toolCallId { return nil; }
- (BOOL)isError { return NO; }
- (NSArray *)toolCalls { return nil; }
- (NSArray *)rawContent { return nil; }
@end

@interface OCQuickAsk () {
    OCProviderClient *_client;
}
@end

@implementation OCQuickAsk

+ (OCProviderInfo *)providerForPrefs:(NSDictionary *)prefs {
    return [OCProviderInfo providerWithId:PrefString(prefs, @"modelProvider")]
        ?: [OCProviderInfo providerWithId:[OCProviderInfo defaultProviderId]];
}

+ (NSString *)modelForPrefs:(NSDictionary *)prefs {
    return PrefString(prefs, @"modelId") ?: [self providerForPrefs:prefs].defaultModel;
}

+ (BOOL)isConfigured:(NSDictionary *)prefs {
    OCProviderInfo *info = [self providerForPrefs:prefs];
    NSString *base = PrefString(prefs, info.baseURLPrefKey) ?: info.defaultBaseURL;
    if ([base length] == 0) return NO;
    return !info.requiresKey || [[CPSecretStore secretForKey:info.secretKey] length] > 0;
}

- (id)initWithPrefs:(NSDictionary *)prefs {
    if ((self = [super init])) {
        _provider = [[[self class] providerForPrefs:prefs] retain];
        _model = [[[self class] modelForPrefs:prefs] copy];
        NSString *key = _provider.secretKey ? [CPSecretStore secretForKey:_provider.secretKey] : nil;
        _client = [[OCProviderClient alloc] initWithInfo:_provider apiKey:key
                                                 baseURL:PrefString(prefs, _provider.baseURLPrefKey)];
    }
    return self;
}

- (void)dealloc {
    [_client cancel];
    [_client release]; [_provider release]; [_model release];
    [super dealloc];
}

- (void)cancel { [_client cancel]; }

- (void)askWithSystem:(NSString *)system history:(NSArray *)history maxTokens:(NSUInteger)maxTokens
               onText:(void(^)(NSString *))onText completion:(OCQuickAskDone)completion {
    NSMutableArray *messages = [NSMutableArray arrayWithCapacity:[history count]];
    for (NSDictionary *turn in history) {
        NSString *content = [turn objectForKey:@"content"];
        if (![content isKindOfClass:[NSString class]] || [content length] == 0) continue;
        OCAgentMessageRole role = [[turn objectForKey:@"role"] isEqual:@"assistant"] ? OCAgentRoleAssistant : OCAgentRoleUser;
        [messages addObject:[[[_OCQuickMessage alloc] initWithRole:role content:content] autorelease]];
    }
    OCQuickAskDone done = [[completion copy] autorelease];
    [_client streamWithModel:_model system:system messages:messages tools:nil maxTokens:maxTokens
                      onText:onText
                  completion:^(OCProviderResult *result, NSError *error) {
        if (done) done(error ? nil : (result.text ?: @""), error);
    }];
}

@end
