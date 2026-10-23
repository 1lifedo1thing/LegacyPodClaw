#import <Foundation/Foundation.h>

extern NSString *const OCGatewayTokenPath;

// a lan-reachable gateway needs a shared secret; this one lives in a 0600 file until keychain storage lands
@interface OCGatewayToken : NSObject

// nil means the token file could not be read or written, so callers must fail closed
+ (NSString *)currentToken;
+ (NSString *)regenerateToken;
+ (BOOL)isValidToken:(NSString *)candidate;

@end

// timing must not leak how many leading characters of a guess were right
BOOL OCGatewayConstantTimeEqual(NSString *candidate, NSString *expected);
