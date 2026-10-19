/*
 * SecureKeychain.h
 * LegacyPodClaw - Secure Keychain Storage
 *
 * Replaces plaintext plist storage with iOS Keychain for sensitive data:
 *   - API keys
 *   - Authentication tokens
 *   - Daemon auth tokens
 *
 * Keychain provides:
 *   - Hardware-backed encryption (when available)
 *   - Access control with device passcode
 *   - Automatic locking when device locks
 *   - No backup to iCloud (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
 */

#import <Foundation/Foundation.h>
#import <Security/Security.h>

@interface CPSecureKeychain : NSObject

/* Service identifier for keychain items */
+ (NSString *)serviceIdentifier;

/* API Keys */
+ (BOOL)setAPIKey:(NSString *)apiKey forProvider:(NSString *)provider error:(NSError **)error;
+ (NSString *)APIKeyForProvider:(NSString *)provider;
+ (BOOL)deleteAPIKeyForProvider:(NSString *)provider error:(NSError **)error;

/* Generic token storage */
+ (BOOL)setToken:(NSString *)token forKey:(NSString *)key error:(NSError **)error;
+ (NSString *)tokenForKey:(NSString *)key;
+ (BOOL)deleteTokenForKey:(NSString *)key error:(NSError **)error;

/* Data storage (for binary secrets) */
+ (BOOL)setData:(NSData *)data forKey:(NSString *)key error:(NSError **)error;
+ (NSData *)dataForKey:(NSString *)key;

/* Bulk operations */
+ (BOOL)migrateFromPlist:(NSString *)plistPath error:(NSError **)error;
+ (void)deleteAllKeychainItems;

@end
