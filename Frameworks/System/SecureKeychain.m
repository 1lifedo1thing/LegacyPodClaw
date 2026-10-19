/*
 * SecureKeychain.m
 * LegacyPodClaw - Secure Keychain Storage Implementation
 *
 * All items stored with:
 *   - kSecClassGenericPassword
 *   - kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly (no iCloud backup)
 *   - Service identifier scoped to app bundle
 */

#import "SecureKeychain.h"

#define KEYCHAIN_SERVICE @"pro.matthesketh.legacypodclaw"

@implementation CPSecureKeychain

+ (NSString *)serviceIdentifier {
    return KEYCHAIN_SERVICE;
}

#pragma mark - Base Operations

+ (NSMutableDictionary *)_baseQueryForKey:(NSString *)key {
    NSMutableDictionary *query = [NSMutableDictionary dictionaryWithCapacity:6];
    [query setObject:(id)kSecClassGenericPassword forKey:(id)kSecClass];
    [query setObject:key forKey:(id)kSecAttrAccount];
    [query setObject:KEYCHAIN_SERVICE forKey:(id)kSecAttrService];
    return query;
}

+ (BOOL)setData:(NSData *)data forKey:(NSString *)key error:(NSError **)error {
    if (!key || !data) {
        if (error) {
            *error = [NSError errorWithDomain:@"CPSecureKeychain" code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Key and data required"}];
        }
        return NO;
    }
    
    NSMutableDictionary *query = [self _baseQueryForKey:key];
    
    /* Check if item exists */
    OSStatus status = SecItemCopyMatching((CFDictionaryRef)query, NULL);
    
    if (status == errSecSuccess) {
        /* Update existing */
        NSDictionary *updateAttrs = @{
            (id)kSecValueData: data,
            (id)kSecAttrAccessible: (id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        };
        status = SecItemUpdate((CFDictionaryRef)query, (CFDictionaryRef)updateAttrs);
    } else {
        /* Add new */
        [query setObject:data forKey:(id)kSecValueData];
        [query setObject:(id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly forKey:(id)kSecAttrAccessible];
        status = SecItemAdd((CFDictionaryRef)query, NULL);
    }
    
    if (status != errSecSuccess) {
        if (error) {
            *error = [NSError errorWithDomain:@"CPSecureKeychain" code:status
                                     userInfo:@{NSLocalizedDescriptionKey: @"Keychain operation failed"}];
        }
        return NO;
    }
    
    return YES;
}

+ (NSData *)dataForKey:(NSString *)key {
    if (!key) return nil;
    
    NSMutableDictionary *query = [self _baseQueryForKey:key];
    [query setObject:(id)kSecReturnData forKey:(id)kSecReturnData];
    [query setObject:(id)kSecMatchLimitOne forKey:(id)kSecMatchLimit];
    
    CFDataRef dataRef = NULL;
    OSStatus status = SecItemCopyMatching((CFDictionaryRef)query, (CFTypeRef *)&dataRef);
    
    if (status != errSecSuccess || !dataRef) {
        return nil;
    }
    
    NSData *data = [(NSData *)dataRef autorelease];
    return data;
}

+ (BOOL)deleteTokenForKey:(NSString *)key error:(NSError **)error {
    if (!key) {
        if (error) {
            *error = [NSError errorWithDomain:@"CPSecureKeychain" code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Key required"}];
        }
        return NO;
    }
    
    NSMutableDictionary *query = [self _baseQueryForKey:key];
    OSStatus status = SecItemDelete((CFDictionaryRef)query);
    
    if (status != errSecSuccess && status != errSecItemNotFound) {
        if (error) {
            *error = [NSError errorWithDomain:@"CPSecureKeychain" code:status
                                     userInfo:@{NSLocalizedDescriptionKey: @"Keychain delete failed"}];
        }
        return NO;
    }
    
    return YES;
}

#pragma mark - String Operations

+ (BOOL)setToken:(NSString *)token forKey:(NSString *)key error:(NSError **)error {
    if (!token) {
        /* Delete if token is nil */
        return [self deleteTokenForKey:key error:error];
    }
    
    NSData *data = [token dataUsingEncoding:NSUTF8StringEncoding];
    return [self setData:data forKey:key error:error];
}

+ (NSString *)tokenForKey:(NSString *)key {
    NSData *data = [self dataForKey:key];
    if (!data) return nil;
    
    NSString *token = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [token autorelease];
}

#pragma mark - API Key Specific

+ (NSString *)_keyForProvider:(NSString *)provider {
    return [NSString stringWithFormat:@"api_key_%@", provider];
}

+ (BOOL)setAPIKey:(NSString *)apiKey forProvider:(NSString *)provider error:(NSError **)error {
    NSString *key = [self _keyForProvider:provider];
    return [self setToken:apiKey forKey:key error:error];
}

+ (NSString *)APIKeyForProvider:(NSString *)provider {
    NSString *key = [self _keyForProvider:provider];
    return [self tokenForKey:key];
}

+ (BOOL)deleteAPIKeyForProvider:(NSString *)provider error:(NSError **)error {
    NSString *key = [self _keyForProvider:provider];
    return [self deleteTokenForKey:key error:error];
}

#pragma mark - Migration

+ (BOOL)migrateFromPlist:(NSString *)plistPath error:(NSError **)error {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if (!prefs) {
        if (error) {
            *error = [NSError errorWithDomain:@"CPSecureKeychain" code:-2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to read plist"}];
        }
        return NO;
    }
    
    BOOL success = YES;
    NSMutableArray *failures = [NSMutableArray array];
    
    /* Migrate API key */
    NSString *apiKey = [prefs objectForKey:@"apiKey"];
    if (apiKey && [apiKey length] > 0) {
        NSError *err = nil;
        if (![self setAPIKey:apiKey forProvider:@"anthropic" error:&err]) {
            [failures addObject:@"apiKey"];
            success = NO;
        } else {
            NSLog(@"[SecureKeychain] Migrated apiKey to keychain");
        }
    }
    
    /* Migrate auth token */
    NSString *authToken = [prefs objectForKey:@"authToken"];
    if (authToken && [authToken length] > 0) {
        NSError *err = nil;
        if (![self setToken:authToken forKey:@"gateway_auth_token" error:&err]) {
            [failures addObject:@"authToken"];
            success = NO;
        }
    }
    
    /* Migrate daemon token */
    NSString *daemonToken = [prefs objectForKey:@"daemonAuthToken"];
    if (daemonToken && [daemonToken length] > 0) {
        NSError *err = nil;
        if (![self setToken:daemonToken forKey:@"daemon_auth_token" error:&err]) {
            [failures addObject:@"daemonAuthToken"];
            success = NO;
        }
    }
    
    /* Migrate device token */
    NSString *deviceToken = [prefs objectForKey:@"deviceToken"];
    if (deviceToken && [deviceToken length] > 0) {
        NSError *err = nil;
        if (![self setToken:deviceToken forKey:@"gateway_device_token" error:&err]) {
            [failures addObject:@"deviceToken"];
            success = NO;
        }
    }
    
    if (!success && error) {
        *error = [NSError errorWithDomain:@"CPSecureKeychain" code:-3
                                 userInfo:@{NSLocalizedDescriptionKey: 
                                            [NSString stringWithFormat:@"Failed to migrate: %@", 
                                             [failures componentsJoinedByString:@", "]]}];
    }
    
    return success;
}

+ (void)deleteAllKeychainItems {
    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    [query setObject:(id)kSecClassGenericPassword forKey:(id)kSecClass];
    [query setObject:KEYCHAIN_SERVICE forKey:(id)kSecAttrService];
    
    OSStatus status = SecItemDelete((CFDictionaryRef)query);
    if (status == errSecSuccess) {
        NSLog(@"[SecureKeychain] All items deleted");
    }
}

@end
