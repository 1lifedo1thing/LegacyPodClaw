/* slack app in socket mode, so no public url is needed; the app token opens the socket, the bot token posts */

#import <Foundation/Foundation.h>
#import "ChannelManager.h"
#import "TLSWebSocket.h"

@interface OCSlackChannel : NSObject <OCChannel, OCTLSWebSocketDelegate>
@property (nonatomic, assign) id<OCChannelDelegate> messageDelegate;
- (instancetype)initWithAppToken:(NSString *)appToken botToken:(NSString *)botToken;
@end
