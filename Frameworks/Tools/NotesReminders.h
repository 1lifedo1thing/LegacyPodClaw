/* notes go through notes.sqlite because ios 6 has no notes api; reminders go through eventkit */

#import <Foundation/Foundation.h>
#import "Agent.h"

@interface OCNotesReminders : NSObject

+ (NSArray *)allTools;

+ (OCToolDefinition *)createNoteTool;
+ (OCToolDefinition *)listNotesTool;
+ (OCToolDefinition *)readNoteTool;
+ (OCToolDefinition *)updateNoteTool;
+ (OCToolDefinition *)deleteNoteTool;
+ (OCToolDefinition *)searchNotesTool;

+ (OCToolDefinition *)createReminderTool;
+ (OCToolDefinition *)listRemindersTool;
+ (OCToolDefinition *)completeReminderTool;
+ (OCToolDefinition *)deleteReminderTool;
+ (OCToolDefinition *)listReminderListsTool;
+ (OCToolDefinition *)createReminderListTool;

@end
