/* provider catalogue, streaming transport and the client the agent talks to */

#import "ProviderRegistry.h"
#import "ProviderFormats.h"
#import "TLSClient.h"

NSString *const OCProviderErrorDomain = @"OCProvider";
NSString *const OCDefaultModelId = @"claude-sonnet-5-5";

static const NSUInteger kMaxErrorBodyBytes = 64 * 1024;

static NSError *ProviderError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:OCProviderErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Provider error"}];
}

#pragma mark - Catalogue

@interface OCProviderInfo ()
@property (nonatomic, copy) NSString *providerId;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, assign) OCProviderFormat format;
@property (nonatomic, copy) NSString *defaultBaseURL;
@property (nonatomic, copy) NSString *secretKey;
@property (nonatomic, assign) BOOL requiresKey;
@property (nonatomic, copy) NSString *defaultModel;
@property (nonatomic, copy) NSString *modelHint;
@property (nonatomic, retain) NSArray *suggestedModels;
@property (nonatomic, copy) NSString *baseURLPrefKey;
@end

@implementation OCProviderInfo

- (void)dealloc {
    [_providerId release]; [_displayName release]; [_defaultBaseURL release]; [_secretKey release];
    [_defaultModel release]; [_modelHint release]; [_suggestedModels release]; [_baseURLPrefKey release];
    [super dealloc];
}

static OCProviderInfo *MakeInfo(NSString *pid, NSString *name, OCProviderFormat format, NSString *base,
                                NSString *secret, BOOL requiresKey, NSString *hint) {
    OCProviderInfo *i = [[[OCProviderInfo alloc] init] autorelease];
    i.providerId = pid;
    i.displayName = name;
    i.format = format;
    i.defaultBaseURL = base;
    i.secretKey = secret;
    i.requiresKey = requiresKey;
    i.modelHint = hint;
    i.suggestedModels = @[];
    i.baseURLPrefKey = [pid isEqualToString:@"custom"] ? @"customBaseURL" : [pid stringByAppendingString:@"BaseURL"];
    return i;
}

+ (NSArray *)allProviders {
    static NSArray *all;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        OCProviderInfo *anthropic = MakeInfo(@"anthropic", @"Anthropic", OCProviderFormatAnthropic,
            @"https://api.anthropic.com", @"apiKey", YES, OCDefaultModelId);
        anthropic.defaultModel = OCDefaultModelId;
        anthropic.suggestedModels = @[@"claude-opus-5-5", @"claude-sonnet-5-5", @"claude-haiku-5-5", @"claude-fable-5-1"];
        all = [@[
            anthropic,
            MakeInfo(@"openai", @"OpenAI", OCProviderFormatOpenAI, @"https://api.openai.com/v1", @"openaiApiKey", YES, @"gpt-4o-mini"),
            MakeInfo(@"google", @"Google Gemini", OCProviderFormatOpenAI,
                     @"https://generativelanguage.googleapis.com/v1beta/openai", @"googleApiKey", YES, @"gemini-2.5-flash"),
            MakeInfo(@"groq", @"Groq", OCProviderFormatOpenAI, @"https://api.groq.com/openai/v1", @"groqApiKey", YES, @"llama-3.3-70b-versatile"),
            MakeInfo(@"together", @"Together AI", OCProviderFormatOpenAI, @"https://api.together.xyz/v1", @"togetherApiKey", YES,
                     @"meta-llama/Llama-3.3-70B-Instruct-Turbo"),
            MakeInfo(@"openrouter", @"OpenRouter", OCProviderFormatOpenAI, @"https://openrouter.ai/api/v1", @"openrouterApiKey", YES,
                     @"anthropic/claude-sonnet-5-5"),
            MakeInfo(@"mistral", @"Mistral", OCProviderFormatOpenAI, @"https://api.mistral.ai/v1", @"mistralApiKey", YES, @"mistral-small-latest"),
            MakeInfo(@"deepseek", @"DeepSeek", OCProviderFormatOpenAI, @"https://api.deepseek.com/v1", @"deepseekApiKey", YES, @"deepseek-chat"),
            MakeInfo(@"ollama", @"Ollama", OCProviderFormatOpenAI, nil, nil, NO, @"llama3.1"),
            MakeInfo(@"custom", @"Custom (OpenAI-compatible)", OCProviderFormatOpenAI, nil, @"customApiKey", NO, @"model-id"),
        ] retain];
    });
    return all;
}

+ (OCProviderInfo *)providerWithId:(NSString *)providerId {
    for (OCProviderInfo *i in [self allProviders])
        if ([i.providerId isEqualToString:providerId]) return i;
    return nil;
}

+ (NSString *)defaultProviderId { return @"anthropic"; }

+ (NSArray *)allSecretKeys {
    NSMutableArray *keys = [NSMutableArray array];
    for (OCProviderInfo *i in [self allProviders]) if (i.secretKey) [keys addObject:i.secretKey];
    return keys;
}

@end

@implementation OCProviderToolCall
- (void)dealloc { [_callId release]; [_name release]; [_input release]; [super dealloc]; }
@end

@implementation OCProviderResult
- (void)dealloc { [_text release]; [_toolCalls release]; [_stopReason release]; [_rawContent release]; [super dealloc]; }
@end

#pragma mark - Plain http transport

/* only for plain http to a local server such as ollama; https always goes through wolfssl */
@interface _OCPlainHTTPStream : NSObject {
    NSURLConnection *_conn;
    NSMutableData *_errorBody;
    NSInteger _status;
    void (^_onChunk)(NSData *);
    void (^_done)(NSData *, NSInteger, NSError *);
}
- (void)start:(NSURLRequest *)req onChunk:(void(^)(NSData *))onChunk done:(void(^)(NSData *, NSInteger, NSError *))done;
- (void)cancel;
@end

@implementation _OCPlainHTTPStream

- (void)start:(NSURLRequest *)req onChunk:(void(^)(NSData *))onChunk done:(void(^)(NSData *, NSInteger, NSError *))done {
    _onChunk = [onChunk copy];
    _done = [done copy];
    _errorBody = [[NSMutableData alloc] init];
    /* the connection retains its delegate until it finishes */
    _conn = [[NSURLConnection alloc] initWithRequest:req delegate:self startImmediately:YES];
}

- (void)cancel {
    [_conn cancel];
    [self _finish:nil error:nil];
}

- (void)_finish:(NSData *)body error:(NSError *)error {
    void (^done)(NSData *, NSInteger, NSError *) = [_done autorelease];
    _done = nil;
    [_onChunk release]; _onChunk = nil;
    [_conn release]; _conn = nil;
    if (done) done(body, _status, error);
}

- (void)connection:(NSURLConnection *)c didReceiveResponse:(NSURLResponse *)response {
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) _status = [(NSHTTPURLResponse *)response statusCode];
}

- (void)connection:(NSURLConnection *)c didReceiveData:(NSData *)data {
    if ([_errorBody length] + [data length] <= kMaxErrorBodyBytes) [_errorBody appendData:data];
    if (_onChunk) _onChunk(data);
}

- (void)connectionDidFinishLoading:(NSURLConnection *)c {
    [self _finish:_errorBody error:nil];
}

- (void)connection:(NSURLConnection *)c didFailWithError:(NSError *)error {
    [self _finish:nil error:error];
}

- (void)dealloc {
    [_conn release]; [_errorBody release]; [_onChunk release]; [_done release];
    [super dealloc];
}

@end

#pragma mark - Client

@interface OCProviderClient () {
    NSString *_apiKey;
    NSString *_baseURL;
    NSUInteger _generation;
    _OCPlainHTTPStream *_plain;
}
@end

@implementation OCProviderClient

- (id)initWithInfo:(OCProviderInfo *)info apiKey:(NSString *)apiKey baseURL:(NSString *)baseURL {
    if ((self = [super init])) {
        _info = [info retain];
        _apiKey = [apiKey copy];
        NSString *base = [baseURL length] ? baseURL : info.defaultBaseURL;
        while ([base hasSuffix:@"/"]) base = [base substringToIndex:[base length] - 1];
        _baseURL = [base copy];
    }
    return self;
}

- (void)dealloc {
    [_plain cancel];
    [_plain release]; [_info release]; [_apiKey release]; [_baseURL release];
    [super dealloc];
}

- (void)cancel {
    _generation++;
    [_plain cancel];
    [_plain release]; _plain = nil;
}

- (NSError *)_configurationError:(NSString *)model {
    if ([_baseURL length] == 0)
        return ProviderError(-1, [NSString stringWithFormat:@"Set a base URL for %@ in Settings.", _info.displayName]);
    NSString *scheme = [[[NSURL URLWithString:_baseURL] scheme] lowercaseString];
    if (![scheme isEqualToString:@"https"] && ![scheme isEqualToString:@"http"])
        return ProviderError(-1, [NSString stringWithFormat:@"The %@ base URL must start with https://", _info.displayName]);
    if (_info.requiresKey && [_apiKey length] == 0)
        return ProviderError(-2, [NSString stringWithFormat:@"Set an API key for %@ in Settings.", _info.displayName]);
    if ([model length] == 0)
        return ProviderError(-3, [NSString stringWithFormat:@"Set a model ID for %@ in Settings.", _info.displayName]);
    return nil;
}

- (void)streamWithModel:(NSString *)model system:(NSString *)system messages:(NSArray *)messages
                  tools:(NSArray *)tools maxTokens:(NSUInteger)maxTokens
                 onText:(OCProviderTextBlock)onText completion:(OCProviderDoneBlock)completion {
    [self cancel];
    if ([model length] == 0) model = _info.defaultModel;
    NSError *configError = [self _configurationError:model];
    if (configError) {
        OCProviderDoneBlock done = [[completion copy] autorelease];
        dispatch_async(dispatch_get_main_queue(), ^{ done(nil, configError); });
        return;
    }

    BOOL anthropic = _info.format == OCProviderFormatAnthropic;
    NSDictionary *body = anthropic
        ? OCAnthropicRequestBody(model, system, messages, tools, maxTokens ?: 1024)
        : OCOpenAIRequestBody(_info, model, system, messages, tools, maxTokens ?: 1024);
    NSData *bodyData = [NSJSONSerialization isValidJSONObject:body]
        ? [NSJSONSerialization dataWithJSONObject:body options:0 error:nil] : nil;
    if (!bodyData) {
        OCProviderDoneBlock done = [[completion copy] autorelease];
        dispatch_async(dispatch_get_main_queue(), ^{ done(nil, ProviderError(-4, @"The request could not be encoded")); });
        return;
    }

    NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        @"application/json", @"Content-Type", @"text/event-stream", @"Accept", nil];
    NSString *url;
    if (anthropic) {
        url = [_baseURL stringByAppendingString:@"/v1/messages"];
        [headers setObject:@"2023-06-01" forKey:@"anthropic-version"];
        if ([_apiKey length]) [headers setObject:_apiKey forKey:@"x-api-key"];
    } else {
        url = [_baseURL stringByAppendingString:@"/chat/completions"];
        if ([_apiKey length]) [headers setObject:[@"Bearer " stringByAppendingString:_apiKey] forKey:@"Authorization"];
    }

    OCStreamParser *parser = anthropic ? [[OCAnthropicStreamParser alloc] init] : [[OCOpenAIStreamParser alloc] init];
    [parser autorelease];
    NSUInteger gen = _generation;
    parser.onText = ^(NSString *delta) { if (gen == _generation && onText) onText(delta); };
    NSMutableData *pending = [NSMutableData data];

    void (^onChunk)(NSData *) = ^(NSData *chunk) {
        if (gen != _generation) return;
        [pending appendData:chunk];
        /* split on bytes so a multibyte character cut across chunks is not lost */
        const char *bytes = [pending bytes];
        NSUInteger len = [pending length], start = 0;
        for (NSUInteger i = 0; i < len; i++) {
            if (bytes[i] != '\n') continue;
            NSUInteger end = (i > start && bytes[i - 1] == '\r') ? i - 1 : i;
            if (end - start > 6 && memcmp(bytes + start, "data:", 5) == 0) {
                NSUInteger off = start + 5;
                if (bytes[off] == ' ') off++;
                NSData *json = [NSData dataWithBytesNoCopy:(void *)(bytes + off) length:end - off freeWhenDone:NO];
                id evt = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
                if ([evt isKindOfClass:[NSDictionary class]]) [parser handleEvent:evt];
            }
            start = i + 1;
        }
        if (start > 0) [pending replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
    };

    OCProviderDoneBlock done = [[completion copy] autorelease];
    OCProviderInfo *info = _info;
    void (^finish)(NSData *, NSInteger, NSError *) = ^(NSData *data, NSInteger status, NSError *error) {
        if (gen != _generation) return;
        if (!error && (status < 200 || status >= 300)) {
            NSString *msg = OCProviderErrorMessage(data);
            error = ProviderError(status, [NSString stringWithFormat:@"%@ returned HTTP %ld%@%@", info.displayName,
                                           (long)status, msg ? @": " : @"", msg ?: @""]);
        }
        if (!error && parser.streamError) error = ProviderError(-5, parser.streamError);
        done(error ? nil : [parser result], error);
    };

    if ([[[[NSURL URLWithString:url] scheme] lowercaseString] isEqualToString:@"https"]) {
        [CPTLSClient streamRequest:url method:@"POST" headers:headers body:bodyData onChunk:onChunk completion:finish];
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
                                                       cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:300];
    [req setHTTPMethod:@"POST"];
    [req setHTTPBody:bodyData];
    for (NSString *k in headers) [req setValue:[headers objectForKey:k] forHTTPHeaderField:k];
    _plain = [[_OCPlainHTTPStream alloc] init];
    [_plain start:req onChunk:onChunk done:finish];
}

@end
