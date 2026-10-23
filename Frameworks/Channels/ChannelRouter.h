/* routes allowed channel messages to one agent session per chat and sends each reply back to that chat */

#import <Foundation/Foundation.h>
#import "ChannelManager.h"
#import "Agent.h"

@interface OCChannelRouter : NSObject <OCChannelManagerDelegate, OCAgentDelegate>

@property (nonatomic, retain) OCChannelManager *manager;
@property (nonatomic, retain) OCModelConfig *modelConfig;
@property (nonatomic, copy) NSString *systemPrompt;
/* channel runs get this agent's tools, read at the start of each run; ignored while toolsEnabled is off */
@property (nonatomic, assign) OCAgent *toolSource;
/* off by default: chat text is untrusted, so it gets no tools unless the user turns them on */
@property (nonatomic, assign) BOOL toolsEnabled;
@property (nonatomic, assign) NSUInteger maxContextTokens;

/* senders or chats that may talk to the bot; an empty list ignores every message on that channel */
- (void)setAllowedSenders:(NSArray *)senders forChannel:(NSString *)channelId;

/* stops every run and forgets every chat */
- (void)reset;
/* forgets the chats of one channel; a run already in progress still ends and replies */
- (void)resetChannel:(NSString *)channelId;

@end
