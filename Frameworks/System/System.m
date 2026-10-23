/*
 * System.m
 * LegacyPodClaw - client for the clawpodd read-only info service
 */

#import "System.h"
#import <dlfcn.h>
#import <objc/message.h>

#define DAEMON_SERVICE @"pro.matthesketh.legacypodclaw.daemon"

@interface CPDaemonClient () {
    id _center;
}
@end

@implementation CPDaemonClient

+ (instancetype)shared {
    static CPDaemonClient *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        dlopen("/System/Library/PrivateFrameworks/AppSupport.framework/AppSupport", RTLD_NOW);
        Class centerClass = NSClassFromString(@"CPDistributedMessagingCenter");
        if (centerClass)
            _center = [[centerClass performSelector:@selector(centerNamed:) withObject:DAEMON_SERVICE] retain];
    }
    return self;
}

- (void)dealloc {
    [_center release];
    [super dealloc];
}

- (NSDictionary *)_send:(NSString *)name info:(NSDictionary *)info {
    if (!_center) return nil;
    typedef NSDictionary *(*SendFn)(id, SEL, NSString *, NSDictionary *);
    @try {
        NSDictionary *reply = ((SendFn)objc_msgSend)(_center, @selector(sendMessageAndReceiveReplyName:userInfo:),
                                                     name, info ?: @{});
        return [reply isKindOfClass:[NSDictionary class]] ? reply : nil;
    } @catch (NSException *e) {
        /* cpdmc throws when the daemon is not running */
        return nil;
    }
}

- (BOOL)isDaemonRunning {
    return [[[self _send:@"ping" info:nil] objectForKey:@"pong"] boolValue];
}

- (NSDictionary *)daemonStatus {
    return [self _send:@"status" info:nil] ?: @{@"running": @NO};
}

- (NSDictionary *)batteryInfo {
    return [self _send:@"battery" info:nil] ?: @{};
}

- (NSArray *)processList {
    return [[self _send:@"processes" info:nil] objectForKey:@"processes"] ?: @[];
}

- (NSArray *)recentCrashes {
    return [[self _send:@"crashes" info:nil] objectForKey:@"crashes"] ?: @[];
}

- (id)sysctl:(NSString *)key {
    if (!key) return nil;
    return [[self _send:@"sysctl" info:@{@"key": key}] objectForKey:@"value"];
}

@end
