/* loadable plugins; only root-owned bundles load, so only a package installed as root can add code */

#import <Foundation/Foundation.h>
#import "Agent.h"
#import "ChannelManager.h"

extern NSString *const OCPluginDirectory;

@protocol OCPlugin <NSObject>
@required
@property (nonatomic, readonly) NSString *pluginId;
@property (nonatomic, readonly) NSString *pluginName;
@property (nonatomic, readonly) NSString *pluginVersion;

- (void)activate;
- (void)deactivate;

@optional
/* tool definitions or dictionaries with name, description, inputSchema and handler; see the readme */
- (NSArray *)providedTools;
/* objects that conform to OCChannel */
- (NSArray *)providedChannels;
- (void)configDidChange:(NSDictionary *)config;
@end

@interface OCPluginManager : NSObject

@property (nonatomic, readonly) NSArray *loadedPlugins;

/* refuses the whole directory unless it is root-owned and not group or world writable */
- (void)loadPluginsFromDirectory:(NSString *)directory;
- (BOOL)loadPluginAtPath:(NSString *)bundlePath error:(NSError **)error;
- (void)unloadPlugin:(NSString *)pluginId;

/* copies of every plugin tool with confirmation forced on */
- (NSArray *)allPluginTools;
- (NSArray *)allPluginChannels;

- (void)setConfig:(NSDictionary *)config forPlugin:(NSString *)pluginId;

@end
