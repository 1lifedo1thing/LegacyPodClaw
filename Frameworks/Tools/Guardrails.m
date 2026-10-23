/*
 * OCGuardrails.m
 * LegacyPodClaw - Safety Guardrails Implementation
 */

#import "Guardrails.h"
#import <sys/mount.h>

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
        @"/var/db/", @"/var/mobile/Library/Accounts/"
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
    NSString *resolved = [[path stringByStandardizingPath] stringByResolvingSymlinksInPath];
    if ([resolved hasPrefix:@"/private/var/"] || [resolved hasPrefix:@"/private/etc/"])
        resolved = [resolved substringFromIndex:[@"/private" length]];

    /* Read-only operations are more permissive */
    if (op == OCFileOpRead) {
        for (NSString *secret in _secretPaths) {
            if ([resolved hasPrefix:secret])
                return [OCGuardrailVerdict blockWithReason:
                    [NSString stringWithFormat:@"Access denied: %@ contains sensitive data", secret]];
        }
        return [OCGuardrailVerdict allow];
    }

    /* Write/edit/delete operations */
    for (NSString *blocked in _hardBlockPaths) {
        if ([resolved hasPrefix:blocked])
            return [OCGuardrailVerdict blockWithReason:
                [NSString stringWithFormat:@"BLOCKED: Cannot modify %@ (system-critical path)", blocked]];
    }

    for (NSString *confirm in _confirmPaths) {
        if ([resolved hasPrefix:confirm])
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
