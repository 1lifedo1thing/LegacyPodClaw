/*
 * SecretStore.h
 * LegacyPodClaw - API keys and tokens, held in the keychain by clawpodd
 */

#import <Foundation/Foundation.h>

/* gateway credentials, provider api keys and channel tokens */
@interface CPSecretStore : NSObject

+ (NSArray *)allSecretKeys;
+ (BOOL)isSecretKey:(NSString *)key;

/* nil when the secret is missing, the keychain is locked, or clawpodd is not running */
+ (NSString *)secretForKey:(NSString *)key;

/* a nil or empty value deletes the secret */
+ (BOOL)setSecret:(NSString *)value forKey:(NSString *)key;

@end
