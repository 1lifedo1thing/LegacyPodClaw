/*
 * SharedFiles.h
 * LegacyPodClaw - small files the app, settings and SpringBoard pass to each other
 *
 * They live in a 0700 directory owned by mobile, not in /tmp, so other
 * users cannot plant a fake banner or badge.
 */

#import <Foundation/Foundation.h>
#import <sys/stat.h>

#define CP_SHARED_DIR @"/var/mobile/Library/LegacyPodClaw"
#define CP_BANNER_FILE @"banner.plist"
#define CP_BADGE_FILE @"badge.plist"

static inline NSString *CPSharedPath(NSString *name) {
    return [CP_SHARED_DIR stringByAppendingPathComponent:name];
}

static inline BOOL CPWriteSharedPlist(NSString *name, NSDictionary *plist) {
    mkdir([CP_SHARED_DIR fileSystemRepresentation], 0700);
    NSString *path = CPSharedPath(name);
    if (![plist writeToFile:path atomically:YES]) return NO;
    chmod([path fileSystemRepresentation], 0600);
    return YES;
}
