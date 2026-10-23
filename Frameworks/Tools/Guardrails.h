/*
 * OCGuardrails.h
 * LegacyPodClaw - Safety Guardrails System
 *
 * Stops file tools from changing system paths or reading secret stores.
 * Shell commands have no denylist: the user approves each one.
 * All checks are synchronous and cheap (string matching only).
 */

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSUInteger, OCGuardrailAction) {
    OCGuardrailAllow = 0,
    OCGuardrailConfirm,     /* Needs user confirmation */
    OCGuardrailBlock         /* Hard block, never allow */
};

@interface OCGuardrailVerdict : NSObject
@property (nonatomic, assign) OCGuardrailAction action;
@property (nonatomic, copy) NSString *reason;
+ (OCGuardrailVerdict *)allow;
+ (OCGuardrailVerdict *)confirmWithReason:(NSString *)reason;
+ (OCGuardrailVerdict *)blockWithReason:(NSString *)reason;
@end

typedef NS_ENUM(NSUInteger, OCFileOp) {
    OCFileOpRead = 0,
    OCFileOpWrite,
    OCFileOpEdit,
    OCFileOpDelete
};

@interface OCGuardrails : NSObject

+ (instancetype)shared;

/* Check a filesystem path before an operation */
- (OCGuardrailVerdict *)checkPath:(NSString *)path forOperation:(OCFileOp)op;

/* Check disk space — returns NO if below 50MB free */
- (BOOL)hasSufficientDiskSpace;
- (NSUInteger)freeDiskSpaceMB;

/* Rate limiting */
- (BOOL)allowFileWrite;       /* Max 5/min */

/* Max file write size in bytes (1MB) */
@property (nonatomic, readonly) NSUInteger maxFileWriteSize;

@end
