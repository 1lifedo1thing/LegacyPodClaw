/*
 * TLSClient.h
 * LegacyPodClaw - HTTPS client on wolfSSL (TLS 1.2/1.3)
 */

#import <Foundation/Foundation.h>

extern NSString *const CPTLSErrorDomain;

typedef void(^CPHTTPSCompletion)(NSData *data, NSInteger statusCode, NSError *error);
typedef void(^CPHTTPSStreamChunk)(NSData *chunk);

@interface CPTLSClient : NSObject

+ (void)request:(NSString *)urlString
         method:(NSString *)method
        headers:(NSDictionary *)headers
           body:(NSData *)body
     completion:(CPHTTPSCompletion)completion;

/* onChunk receives decoded body bytes on the main queue as they arrive */
+ (void)streamRequest:(NSString *)urlString
               method:(NSString *)method
              headers:(NSDictionary *)headers
                 body:(NSData *)body
              onChunk:(CPHTTPSStreamChunk)onChunk
           completion:(CPHTTPSCompletion)completion;

+ (void)postJSON:(NSString *)urlString
         headers:(NSDictionary *)headers
            body:(NSDictionary *)jsonBody
      completion:(void(^)(NSDictionary *json, NSError *error))completion;

/* base64 sha-256 spki hashes; pin intermediates or roots, never a leaf that rotates */
+ (void)setPinnedSPKIHashes:(NSArray *)hashes forHost:(NSString *)host;

@end

@class CPTLSConnection;

/* all callbacks arrive on the main queue */
@protocol CPTLSConnectionDelegate <NSObject>
- (void)connectionDidOpen:(CPTLSConnection *)connection;
- (void)connection:(CPTLSConnection *)connection didReceiveData:(NSData *)data;
- (void)connection:(CPTLSConnection *)connection didCloseWithError:(NSError *)error;
@end

/* a long-lived socket for irc and websockets; tls uses the same ca bundle and host check as requests */
@interface CPTLSConnection : NSObject

@property (nonatomic, assign) id<CPTLSConnectionDelegate> delegate;
@property (nonatomic, readonly) NSString *host;
@property (nonatomic, readonly) int port;
@property (nonatomic, readonly) BOOL useTLS;

- (id)initWithHost:(NSString *)host port:(int)port useTLS:(BOOL)useTLS;
- (void)open;
- (void)sendData:(NSData *)data;
/* no delegate callback follows a close the owner asked for */
- (void)close;

@end
