/*
 * ToolDispatcher.h
 * LegacyPodClaw - the one path every tool call takes
 *
 * Checks the input against the tool schema, applies the path guardrails,
 * asks the user before a risky tool runs, enforces the tool timeout and
 * calls back exactly once on the main thread.
 */

#import <Foundation/Foundation.h>
#import "Agent.h"

@interface OCToolDispatcher : NSObject

+ (instancetype)shared;

+ (OCToolDefinition *)toolNamed:(NSString *)name inTools:(NSArray *)tools;

/* result is always an NSString; error is set when the call did not run or failed */
- (void)runTool:(OCToolDefinition *)tool
          input:(id)input
         caller:(OCToolCaller)caller
     completion:(void(^)(NSString *result, NSError *error))completion;

@end
