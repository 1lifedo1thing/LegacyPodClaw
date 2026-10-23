/* text-only asks for springboard (overlay, nc widget, dashboard) through the provider chosen in the app */

#import <Foundation/Foundation.h>
#import "ProviderRegistry.h"

/* completion runs on the main queue; text is the whole reply, nil on an error */
typedef void(^OCQuickAskDone)(NSString *text, NSError *error);

@interface OCQuickAsk : NSObject

/* the provider in the prefs, or the default one when the prefs name none or an unknown one */
+ (OCProviderInfo *)providerForPrefs:(NSDictionary *)prefs;
/* the model the app would use: the modelId pref, else the provider default; nil when neither is set */
+ (NSString *)modelForPrefs:(NSDictionary *)prefs;
/* a base url and, when the provider needs one, a key are present */
+ (BOOL)isConfigured:(NSDictionary *)prefs;

- (id)initWithPrefs:(NSDictionary *)prefs;

@property (nonatomic, readonly, retain) OCProviderInfo *provider;
@property (nonatomic, readonly, copy) NSString *model;

/* history holds {role: user|assistant, content: text} dictionaries, oldest first */
- (void)askWithSystem:(NSString *)system
              history:(NSArray *)history
            maxTokens:(NSUInteger)maxTokens
               onText:(void(^)(NSString *delta))onText
           completion:(OCQuickAskDone)completion;

/* drops the callbacks of the request in flight */
- (void)cancel;

@end
