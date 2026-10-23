/*
 * ToolInputCheck.h
 * LegacyPodClaw - pure checks OCToolDispatcher runs before a tool call
 *
 * Foundation only, so the host test target can build them.
 */

#import <Foundation/Foundation.h>

/* a key field longer than this cannot be shown in an alert, so the call is refused */
#define OC_TOOL_KEY_FIELD_MAX 1500

/* nil when the input fits the json schema's required keys and property types */
NSString *OCToolSchemaProblem(NSDictionary *schema, NSDictionary *input);

/* fields that decide what a call does; the user must see them whole */
NSArray *OCToolApprovalFields(void);

/* spaces, tabs, line breaks and control characters made visible */
NSString *OCToolVisibleText(NSString *value);

/* the approval fields as alert text; sets *tooLong and returns nil when one cannot be shown */
NSString *OCToolApprovalText(NSDictionary *input, BOOL *tooLong);

/* the largest length <= length that does not end inside a utf-8 sequence */
NSUInteger OCUtf8SafeLength(const uint8_t *bytes, NSUInteger length);
