/* discord bot: gateway websocket for inbound, rest api for replies */

#import <Foundation/Foundation.h>
#import "ChannelManager.h"
#import "TLSWebSocket.h"

@interface OCDiscordChannel : NSObject <OCChannel, OCTLSWebSocketDelegate>
@property (nonatomic, assign) id<OCChannelDelegate> messageDelegate;
- (instancetype)initWithBotToken:(NSString *)token;
@end
