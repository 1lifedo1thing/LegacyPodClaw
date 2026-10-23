#import <Foundation/Foundation.h>

@class OCServerWebSocket;

@protocol OCServerWebSocketDelegate <NSObject>
- (void)serverWebSocket:(OCServerWebSocket *)ws didReceiveText:(NSString *)text;
- (void)serverWebSocketDidClose:(OCServerWebSocket *)ws;
@end

// the client-mode OCWebSocket masks its frames and cannot adopt an accepted socket, so inbound sessions need this
@interface OCServerWebSocket : NSObject <NSStreamDelegate>

@property (nonatomic, assign) id<OCServerWebSocketDelegate> delegate;
@property (nonatomic, assign) NSUInteger maxMessageSize;
@property (nonatomic, assign) NSUInteger maxPendingWriteBytes;
@property (nonatomic, readonly) BOOL isOpen;

- (instancetype)initWithInputStream:(NSInputStream *)input
                       outputStream:(NSOutputStream *)output
                        pendingData:(NSData *)pendingData;

- (void)startWithHandshakeResponse:(NSData *)handshake;
// writes a plain http error instead of the 101 and closes once it is sent
- (void)rejectWithResponse:(NSData *)response;
- (void)sendText:(NSString *)text;
- (void)closeWithCode:(uint16_t)code reason:(NSString *)reason;

@end
