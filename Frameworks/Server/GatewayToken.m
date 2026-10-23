#import "GatewayToken.h"
#import <stdlib.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <sys/stat.h>

NSString *const OCGatewayTokenPath = @"/var/mobile/Library/LegacyPodClaw/gateway-token";

enum { kTokenBytes = 32, kTokenHexLength = 64 };

static NSString *sCachedToken = nil;

BOOL OCGatewayConstantTimeEqual(NSString *candidate, NSString *expected) {
    if (!candidate || !expected) return NO;
    NSData *a = [candidate dataUsingEncoding:NSUTF8StringEncoding];
    NSData *b = [expected dataUsingEncoding:NSUTF8StringEncoding];
    if (!a || !b) return NO;
    const uint8_t *ab = [a bytes];
    const uint8_t *bb = [b bytes];
    NSUInteger alen = [a length];
    NSUInteger blen = [b length];
    volatile uint8_t diff = (alen == blen) ? 0 : 1;
    for (NSUInteger i = 0; i < blen; i++) {
        uint8_t x = (i < alen) ? ab[i] : 0;
        diff |= (uint8_t)(x ^ bb[i]);
    }
    return diff == 0;
}

static BOOL OCTokenLooksValid(const char *buf, size_t len) {
    if (len != kTokenHexLength) return NO;
    for (size_t i = 0; i < len; i++) {
        char c = buf[i];
        BOOL hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
        if (!hex) return NO;
    }
    return YES;
}

static BOOL OCEnsureTokenDirectory(NSString *dir) {
    const char *path = [dir fileSystemRepresentation];
    if (mkdir(path, 0700) != 0 && errno != EEXIST) return NO;
    struct stat st;
    // lstat so a planted symlink cannot redirect the secret elsewhere
    if (lstat(path, &st) != 0 || !S_ISDIR(st.st_mode)) return NO;
    if ((st.st_mode & 0777) != 0700 && chmod(path, 0700) != 0) return NO;
    return YES;
}

static NSString *OCReadTokenFile(void) {
    int fd = open([OCGatewayTokenPath fileSystemRepresentation], O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return nil;
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size != (off_t)kTokenHexLength) {
        close(fd);
        return nil;
    }
    if ((st.st_mode & 0077) != 0) fchmod(fd, 0600);
    char buf[kTokenHexLength];
    ssize_t n = read(fd, buf, sizeof(buf));
    close(fd);
    if (n != (ssize_t)kTokenHexLength || !OCTokenLooksValid(buf, (size_t)n)) return nil;
    return [[[NSString alloc] initWithBytes:buf length:(NSUInteger)n
                                   encoding:NSASCIIStringEncoding] autorelease];
}

static NSString *OCWriteNewTokenFile(void) {
    NSString *dir = [OCGatewayTokenPath stringByDeletingLastPathComponent];
    if (!OCEnsureTokenDirectory(dir)) return nil;

    uint8_t raw[kTokenBytes];
    arc4random_buf(raw, sizeof(raw));
    static const char hexDigits[] = "0123456789abcdef";
    char hex[kTokenHexLength];
    for (size_t i = 0; i < kTokenBytes; i++) {
        hex[i * 2] = hexDigits[raw[i] >> 4];
        hex[i * 2 + 1] = hexDigits[raw[i] & 0x0F];
    }
    memset(raw, 0, sizeof(raw));

    // write beside the target then rename, so a crash never leaves a half-written token
    NSString *tmpPath = [OCGatewayTokenPath stringByAppendingString:@".tmp"];
    const char *tmp = [tmpPath fileSystemRepresentation];
    unlink(tmp);
    int fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) return nil;
    fchmod(fd, 0600);
    ssize_t written = write(fd, hex, sizeof(hex));
    BOOL ok = (written == (ssize_t)sizeof(hex)) && fsync(fd) == 0;
    close(fd);
    if (!ok || rename(tmp, [OCGatewayTokenPath fileSystemRepresentation]) != 0) {
        unlink(tmp);
        return nil;
    }
    NSString *token = [[[NSString alloc] initWithBytes:hex length:sizeof(hex)
                                              encoding:NSASCIIStringEncoding] autorelease];
    memset(hex, 0, sizeof(hex));
    return token;
}

@implementation OCGatewayToken

+ (NSString *)currentToken {
    @synchronized (self) {
        if (sCachedToken) return [[sCachedToken retain] autorelease];
        NSString *token = OCReadTokenFile();
        if (!token) token = OCWriteNewTokenFile();
        if (!token) return nil;
        sCachedToken = [token copy];
        return [[sCachedToken retain] autorelease];
    }
}

+ (NSString *)regenerateToken {
    @synchronized (self) {
        NSString *token = OCWriteNewTokenFile();
        if (!token) return nil;
        [sCachedToken release];
        sCachedToken = [token copy];
        return [[sCachedToken retain] autorelease];
    }
}

+ (BOOL)isValidToken:(NSString *)candidate {
    NSString *expected = [self currentToken];
    if (!expected) return NO;
    return OCGatewayConstantTimeEqual(candidate, expected);
}

@end
