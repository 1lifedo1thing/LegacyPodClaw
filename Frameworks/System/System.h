/*
 * System.h
 * LegacyPodClaw - client for the clawpodd read-only info service
 */

#import <Foundation/Foundation.h>

/* all calls block until clawpodd replies, so do not call them on the main thread */
@interface CPDaemonClient : NSObject

+ (instancetype)shared;
- (BOOL)isDaemonRunning;
- (NSDictionary *)daemonStatus;
- (NSDictionary *)batteryInfo;
- (NSArray *)processList;
- (NSArray *)recentCrashes;

/* returns nil unless clawpodd allow-lists the key */
- (id)sysctl:(NSString *)key;

@end
