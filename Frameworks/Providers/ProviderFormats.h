/* wire formats for the two chat apis, kept apart from transport so each stays small */

#import <Foundation/Foundation.h>
#import "ProviderRegistry.h"

NSDictionary *OCAnthropicRequestBody(NSString *model, NSString *system, NSArray *messages,
                                     NSArray *tools, NSUInteger maxTokens);
NSDictionary *OCOpenAIRequestBody(OCProviderInfo *info, NSString *model, NSString *system,
                                  NSArray *messages, NSArray *tools, NSUInteger maxTokens);
/* reads the message out of a json error body, nil when there is none */
NSString *OCProviderErrorMessage(NSData *body);

@interface OCStreamParser : NSObject {
@protected
    OCProviderTextBlock _onText;
    NSString *_streamError;
}
@property (nonatomic, copy) OCProviderTextBlock onText;
/* set when the stream itself carried an error event */
@property (nonatomic, readonly) NSString *streamError;
- (void)handleEvent:(NSDictionary *)event;
- (OCProviderResult *)result;
@end

@interface OCAnthropicStreamParser : OCStreamParser
@end

@interface OCOpenAIStreamParser : OCStreamParser
@end
