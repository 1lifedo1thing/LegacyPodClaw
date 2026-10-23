/* settings for one chat channel; tokens go to the keychain through clawpodd, never to the plist */

#import <UIKit/UIKit.h>

@interface OCChannelSettingsViewController : UITableViewController <UIAlertViewDelegate>

/* fields hold dictionaries: label, key, type (switch, text, secret or number), placeholder */
- (id)initWithTitle:(NSString *)title fields:(NSArray *)fields footer:(NSString *)footer;

/* the field lists for the built-in channels, keyed by channel id */
+ (NSArray *)channelIds;
+ (NSString *)titleForChannel:(NSString *)channelId;
+ (NSArray *)fieldsForChannel:(NSString *)channelId;
+ (NSString *)footerForChannel:(NSString *)channelId;
/* the short state both the channel list and the channel screen show: Off, Connecting…, Retrying, Connected or Stopped */
+ (NSString *)stateTextForChannel:(NSString *)channelId;

@end
