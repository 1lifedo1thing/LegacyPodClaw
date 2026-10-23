/* generic webhook: inbound only through the authenticated gateway server, replies posted to a callback url */

#import <Foundation/Foundation.h>
#import "ChannelManager.h"

@interface OCWebhookChannel : NSObject <OCChannel>
@property (nonatomic, assign) id<OCChannelDelegate> messageDelegate;
- (instancetype)initWithCallbackURL:(NSString *)callbackURL bearerToken:(NSString *)token;
/* nil when accepted, otherwise the reason the payload was refused */
- (NSString *)handleInboundPayload:(NSDictionary *)payload;
@end
