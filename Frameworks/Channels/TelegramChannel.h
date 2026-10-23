/* telegram bot api: long-poll getUpdates for inbound, sendMessage for replies */

#import <Foundation/Foundation.h>
#import "ChannelManager.h"

@interface OCTelegramChannel : NSObject <OCChannel>
@property (nonatomic, assign) id<OCChannelDelegate> messageDelegate;
- (instancetype)initWithBotToken:(NSString *)token;
@end
