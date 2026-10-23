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

/* base64 sha-256 spki hashes of the leaf key; only the leaf is checked, so pin a key the server keeps across renewals */
+ (void)setPinnedSPKIHashes:(NSArray *)hashes forHost:(NSString *)host;

@end
