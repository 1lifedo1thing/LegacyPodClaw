/*
 * OCGuardrails.m
 * LegacyPodClaw - Safety Guardrails Implementation
 */

#import "Guardrails.h"
#import <sys/mount.h>
#import <sys/param.h>
#import <stdlib.h>

@implementation OCGuardrailVerdict
+ (OCGuardrailVerdict *)allow {
    OCGuardrailVerdict *v = [[[self alloc] init] autorelease];
    v.action = OCGuardrailAllow; return v;
}
+ (OCGuardrailVerdict *)confirmWithReason:(NSString *)reason {
    OCGuardrailVerdict *v = [[[self alloc] init] autorelease];
    v.action = OCGuardrailConfirm; v.reason = reason; return v;
}
+ (OCGuardrailVerdict *)blockWithReason:(NSString *)reason {
    OCGuardrailVerdict *v = [[[self alloc] init] autorelease];
    v.action = OCGuardrailBlock; v.reason = reason; return v;
}
- (void)dealloc { [_reason release]; [super dealloc]; }
@end

/* Protected path prefixes */
static NSArray *_hardBlockPaths = nil;
static NSArray *_confirmPaths = nil;
static NSArray *_secretPaths = nil;

@interface OCGuardrails () {
    NSMutableArray *_writeTimestamps;
}
@end

/* "/var/Keychains" itself must match the "/var/Keychains/" rule, not only paths below it */
static BOOL PathIsUnder(NSString *path, NSString *dir) {
    NSString *bare = [dir hasSuffix:@"/"] ? [dir substringToIndex:[dir length] - 1] : dir;
    return [path isEqualToString:bare] || [path hasPrefix:[bare stringByAppendingString:@"/"]]
        || (![dir hasSuffix:@"/"] && [path hasPrefix:dir]);
}

/* the kernel resolves ".." after a symlink physically, and nsstring may not, so ask realpath for the longest existing prefix */
static NSString *PhysicalPath(NSString *path) {
    NSArray *parts = [path pathComponents];
    char resolved[PATH_MAX];
    for (NSUInteger i = [parts count]; i > 0; i--) {
        NSString *prefix = [NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(0, i)]];
        if (!realpath([prefix fileSystemRepresentation], resolved)) continue;
        NSArray *rest = [parts subarrayWithRange:NSMakeRange(i, [parts count] - i)];
        /* a dot segment below a missing directory has no physical meaning, so refuse it */
        if ([rest containsObject:@".."] || [rest containsObject:@"."]) return nil;
        NSString *base = [NSString stringWithUTF8String:resolved];
        return [rest count] ? [base stringByAppendingPathComponent:[NSString pathWithComponents:rest]] : base;
    }
    return nil;
}

@implementation OCGuardrails

+ (void)initialize {
    _hardBlockPaths = [@[
        @"/System/", @"/usr/lib/", @"/usr/libexec/", @"/usr/sbin/",
        @"/sbin/", @"/bin/", @"/boot/", @"/var/stash/",
        @"/usr/share/firmware", @"/usr/standalone"
    ] retain];

    _confirmPaths = [@[
        @"/Library/MobileSubstrate/", @"/etc/",
        @"/var/mobile/Library/Preferences/com.apple.",
        @"/var/mobile/Library/Preferences/pro.matthesketh.legacypodclaw"
    ] retain];

    _secretPaths = [@[
        @"/var/Keychains/", @"/var/mobile/Library/Mail/",
        @"/var/db/", @"/var/mobile/Library/Accounts/",
        @"/var/mobile/Library/SMS/", @"/var/mobile/Library/AddressBook/",
        @"/var/mobile/Library/Cookies/", @"/var/mobile/Library/Safari/",
        @"/var/mobile/Library/CallHistory/", @"/var/mobile/Library/Preferences/pro.matthesketh.legacypodclaw.plist"
    ] retain];
}

+ (instancetype)shared {
    static OCGuardrails *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _writeTimestamps = [[NSMutableArray alloc] init];
        _maxFileWriteSize = 1 * 1024 * 1024; /* 1MB */
    }
    return self;
}

- (void)dealloc {
    [_writeTimestamps release];
    [super dealloc];
}

#pragma mark - Path Checks

- (OCGuardrailVerdict *)checkPath:(NSString *)path forOperation:(OCFileOp)op {
    if (!path) return [OCGuardrailVerdict blockWithReason:@"No path provided"];

    if (![path isAbsolutePath]) return [OCGuardrailVerdict blockWithReason:@"Path must be absolute"];

    /* resolve symlinks and dot segments, then undo the /private prefix so /var and /etc rules still match */
    NSString *resolved = PhysicalPath(path);
    if (!resolved) return [OCGuardrailVerdict blockWithReason:@"Path cannot be resolved"];
    if ([resolved hasPrefix:@"/private/var/"] || [resolved hasPrefix:@"/private/etc/"] ||
        [resolved isEqualToString:@"/private/var"] || [resolved isEqualToString:@"/private/etc"])
        resolved = [resolved substringFromIndex:[@"/private" length]];

    /* Read-only operations are more permissive */
    if (op == OCFileOpRead) {
        for (NSString *secret in _secretPaths) {
            if (PathIsUnder(resolved, secret))
                return [OCGuardrailVerdict blockWithReason:
                    [NSString stringWithFormat:@"Access denied: %@ contains sensitive data", secret]];
        }
        return [OCGuardrailVerdict allow];
    }

    /* Write/edit/delete operations */
    for (NSString *blocked in _hardBlockPaths) {
        if (PathIsUnder(resolved, blocked))
            return [OCGuardrailVerdict blockWithReason:
                [NSString stringWithFormat:@"BLOCKED: Cannot modify %@ (system-critical path)", blocked]];
    }

    for (NSString *confirm in _confirmPaths) {
        if (PathIsUnder(resolved, confirm))
            return [OCGuardrailVerdict confirmWithReason:
                [NSString stringWithFormat:@"Modifying %@ requires confirmation", resolved]];
    }

    /* Check disk space for writes */
    if ((op == OCFileOpWrite || op == OCFileOpEdit) && ![self hasSufficientDiskSpace]) {
        return [OCGuardrailVerdict blockWithReason:
            [NSString stringWithFormat:@"Low disk space (%luMB free). Operation blocked.",
             (unsigned long)[self freeDiskSpaceMB]]];
    }

    return [OCGuardrailVerdict allow];
}

#pragma mark - Disk Space

- (BOOL)hasSufficientDiskSpace { return [self freeDiskSpaceMB] >= 50; }

- (NSUInteger)freeDiskSpaceMB {
    struct statfs stat;
    if (statfs("/var", &stat) == 0) {
        return (NSUInteger)((double)stat.f_bavail * stat.f_bsize / (1024 * 1024));
    }
    return 0;
}

#pragma mark - Rate Limiting

- (void)_pruneTimestamps:(NSMutableArray *)timestamps olderThan:(NSTimeInterval)seconds {
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-seconds];
    while ([timestamps count] > 0 && [[timestamps objectAtIndex:0] compare:cutoff] == NSOrderedAscending)
        [timestamps removeObjectAtIndex:0];
}

- (BOOL)allowFileWrite {
    [self _pruneTimestamps:_writeTimestamps olderThan:60];
    if ([_writeTimestamps count] >= 5) return NO;
    [_writeTimestamps addObject:[NSDate date]];
    return YES;
}

@end
