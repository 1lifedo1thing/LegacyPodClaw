/* model providers: anthropic messages plus one openai-compatible chat adapter */

#import <Foundation/Foundation.h>

extern NSString *const OCProviderErrorDomain;
extern NSString *const OCDefaultModelId;

typedef NS_ENUM(NSUInteger, OCProviderFormat) {
    OCProviderFormatAnthropic = 0,
    OCProviderFormatOpenAI,
};

@interface OCProviderInfo : NSObject
@property (nonatomic, readonly, copy) NSString *providerId;
@property (nonatomic, readonly, copy) NSString *displayName;
@property (nonatomic, readonly) OCProviderFormat format;
@property (nonatomic, readonly, copy) NSString *defaultBaseURL;
/* key name in the secret store, nil when the provider takes no key */
@property (nonatomic, readonly, copy) NSString *secretKey;
@property (nonatomic, readonly) BOOL requiresKey;
@property (nonatomic, readonly, copy) NSString *defaultModel;
@property (nonatomic, readonly, copy) NSString *modelHint;
@property (nonatomic, readonly, retain) NSArray *suggestedModels;
/* preferences plist key that overrides the base url */
@property (nonatomic, readonly, copy) NSString *baseURLPrefKey;

+ (NSArray *)allProviders;
+ (OCProviderInfo *)providerWithId:(NSString *)providerId;
+ (NSString *)defaultProviderId;
+ (NSArray *)allSecretKeys;
@end

@interface OCProviderToolCall : NSObject
@property (nonatomic, copy) NSString *callId;
@property (nonatomic, copy) NSString *name;
/* nil when the model sent arguments that are not a json object */
@property (nonatomic, copy) NSDictionary *input;
@end

@interface OCProviderResult : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic, retain) NSArray *toolCalls;
/* end_turn, tool_use, max_tokens, refusal, stop, length, tool_calls */
@property (nonatomic, copy) NSString *stopReason;
/* anthropic content blocks, sent back unchanged so thinking blocks stay valid */
@property (nonatomic, retain) NSArray *rawContent;
@property (nonatomic, assign) NSUInteger inputTokens;
@property (nonatomic, assign) NSUInteger outputTokens;
@end

typedef void(^OCProviderTextBlock)(NSString *delta);
typedef void(^OCProviderDoneBlock)(OCProviderResult *result, NSError *error);

/* one client per conversation; callbacks arrive on the main queue */
@interface OCProviderClient : NSObject

@property (nonatomic, readonly, retain) OCProviderInfo *info;

- (id)initWithInfo:(OCProviderInfo *)info apiKey:(NSString *)apiKey baseURL:(NSString *)baseURL;

/* messages hold agent messages, tools hold tool definitions */
- (void)streamWithModel:(NSString *)model
                 system:(NSString *)system
               messages:(NSArray *)messages
                  tools:(NSArray *)tools
              maxTokens:(NSUInteger)maxTokens
                 onText:(OCProviderTextBlock)onText
             completion:(OCProviderDoneBlock)completion;

/* drops the callbacks of the request in flight */
- (void)cancel;

@end
