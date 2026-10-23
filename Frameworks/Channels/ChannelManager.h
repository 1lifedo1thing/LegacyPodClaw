/* chat channels: each one turns platform traffic into channel messages and sends replies back */

#import <Foundation/Foundation.h>

@interface OCChannelMessage : NSObject
@property (nonatomic, copy) NSString *channelId;      // "telegram", "discord", ...
@property (nonatomic, copy) NSString *chatId;         // where the reply goes
@property (nonatomic, copy) NSString *threadId;       // optional topic or thread
@property (nonatomic, copy) NSString *senderId;       // stable platform user id
@property (nonatomic, copy) NSString *senderAddress;  // extra identity, such as an irc hostmask
@property (nonatomic, copy) NSString *senderName;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSString *messageId;
@property (nonatomic, retain) NSDate *timestamp;
@property (nonatomic, assign) BOOL isGroup;
@end

@protocol OCChannel;

/* how a channel hands inbound messages to its owner; called on the main thread */
@protocol OCChannelDelegate <NSObject>
- (void)channel:(id<OCChannel>)channel didReceiveMessage:(OCChannelMessage *)message;
@end

/* plugins may supply their own channels by conforming to this protocol */
@protocol OCChannel <NSObject>
@required
@property (nonatomic, readonly) NSString *channelId;
@property (nonatomic, readonly) BOOL isConnected;
@property (nonatomic, readonly) BOOL isConfigured;
@property (nonatomic, assign) id<OCChannelDelegate> messageDelegate;
- (void)start;
- (void)stop;
- (void)sendMessage:(NSString *)text toChatId:(NSString *)chatId threadId:(NSString *)threadId;
@optional
- (void)sendTypingIndicator:(NSString *)chatId;
- (NSDictionary *)statusInfo;
@end

@class OCChannelManager;

@protocol OCChannelManagerDelegate <NSObject>
- (void)channelManager:(OCChannelManager *)manager didReceiveMessage:(OCChannelMessage *)message;
@end

@interface OCChannelManager : NSObject <OCChannelDelegate>

@property (nonatomic, assign) id<OCChannelManagerDelegate> delegate;
@property (nonatomic, readonly) NSArray *channels;

/* a second channel with the same id is refused */
- (BOOL)registerChannel:(id<OCChannel>)channel;
- (void)removeChannel:(NSString *)channelId;
- (void)removeAllChannels;
- (id<OCChannel>)channelForId:(NSString *)channelId;

- (void)startAll;
- (void)stopAll;

- (void)sendMessage:(NSString *)text channelId:(NSString *)channelId
             chatId:(NSString *)chatId threadId:(NSString *)threadId;
- (void)sendTypingIndicator:(NSString *)channelId chatId:(NSString *)chatId;

- (NSDictionary *)allChannelStatus;

@end

/* removes markdown marks for platforms that show them literally */
NSString *OCStripMarkdown(NSString *markdown);
/* splits text into pieces no longer than the limit, preferring line breaks */
NSArray *OCSplitText(NSString *text, NSUInteger maxChars);
/* comma or whitespace separated list from a preference string */
NSArray *OCListFromString(NSString *value);
