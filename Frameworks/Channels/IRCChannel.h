/* irc client (rfc 2812) over plain tcp or wolfssl tls */

#import <Foundation/Foundation.h>
#import "ChannelManager.h"
#import "TLSClient.h"

@interface OCIRCChannel : NSObject <OCChannel, CPTLSConnectionDelegate>
@property (nonatomic, assign) id<OCChannelDelegate> messageDelegate;
@property (nonatomic, copy) NSString *password;     // server password, often accepted by nickserv
@property (nonatomic, retain) NSArray *channels;    // "#one", "#two"
- (instancetype)initWithServer:(NSString *)server port:(int)port useTLS:(BOOL)useTLS nickname:(NSString *)nick;
@end
