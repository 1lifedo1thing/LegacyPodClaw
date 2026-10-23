/* plugin loader with ownership checks; plugin tools always need the user's approval */

#import "PluginSDK.h"
#import <sys/stat.h>

NSString *const OCPluginDirectory = @"/Library/LegacyPodClaw/Plugins";

static const NSUInteger kMaxPlugins = 16;

static NSError *PluginError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"OCPlugin" code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

/* a path is trusted when root owns it, it is no symlink, and only root may write to it */
static NSString *UntrustedReason(NSString *path, BOOL allowGroupWrite) {
    struct stat st;
    if (lstat([path fileSystemRepresentation], &st) != 0) return @"cannot be read";
    if (S_ISLNK(st.st_mode)) return @"is a symbolic link";
    if (st.st_uid != 0) return @"is not owned by root";
    if (st.st_mode & S_IWOTH) return @"is writable by everyone";
    if (!allowGroupWrite && (st.st_mode & S_IWGRP)) return @"is writable by its group";
    return nil;
}

static NSString *UntrustedDirectory(NSString *directory) {
    NSString *reason = UntrustedReason(directory, NO);
    if (reason) return [NSString stringWithFormat:@"%@ %@", directory, reason];
    /* a parent that others can write would let them swap the whole directory */
    for (NSString *p = [directory stringByDeletingLastPathComponent]; [p length] > 1;
         p = [p stringByDeletingLastPathComponent]) {
        reason = UntrustedReason(p, YES);
        if (reason) return [NSString stringWithFormat:@"%@ %@", p, reason];
    }
    return nil;
}

static NSString *UntrustedBundle(NSString *bundlePath) {
    NSString *reason = UntrustedReason(bundlePath, NO);
    if (reason) return [NSString stringWithFormat:@"%@ %@", [bundlePath lastPathComponent], reason];
    NSDirectoryEnumerator *e = [[NSFileManager defaultManager] enumeratorAtPath:bundlePath];
    for (NSString *rel in e) {
        reason = UntrustedReason([bundlePath stringByAppendingPathComponent:rel], NO);
        if (reason) return [NSString stringWithFormat:@"%@/%@ %@", [bundlePath lastPathComponent], rel, reason];
    }
    return nil;
}

static BOOL ValidToolName(NSString *name) {
    if (![name isKindOfClass:[NSString class]] || [name length] == 0 || [name length] > 64) return NO;
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"] invertedSet];
    return [name rangeOfCharacterFromSet:bad].location == NSNotFound;
}

/* a fresh definition, so a plugin cannot turn confirmation off after it hands the tool over */
static OCToolDefinition *ConfirmedTool(id item) {
    NSString *name = nil, *desc = nil;
    NSDictionary *schema = nil;
    OCToolHandler handler = nil;
    NSTimeInterval timeout = 0;
    if ([item isKindOfClass:[OCToolDefinition class]]) {
        OCToolDefinition *t = item;
        name = t.name; desc = t.toolDescription; schema = t.inputSchema; handler = t.handler; timeout = t.timeout;
    } else if ([item isKindOfClass:[NSDictionary class]]) {
        name = [item objectForKey:@"name"];
        desc = [item objectForKey:@"description"];
        schema = [item objectForKey:@"inputSchema"];
        id h = [item objectForKey:@"handler"];
        if ([h isKindOfClass:NSClassFromString(@"NSBlock")]) handler = h;
        timeout = [[item objectForKey:@"timeout"] doubleValue];
    }
    if (!ValidToolName(name) || !handler) return nil;
    OCToolDefinition *tool = [[[OCToolDefinition alloc] init] autorelease];
    tool.name = name;
    tool.toolDescription = [desc isKindOfClass:[NSString class]] ? desc : @"";
    tool.inputSchema = [schema isKindOfClass:[NSDictionary class]] ? schema : @{@"type": @"object", @"properties": @{}};
    tool.handler = handler;
    if (timeout > 0) tool.timeout = MIN(timeout, 120.0);
    tool.requiresConfirmation = YES;
    return tool;
}

@interface OCPluginManager () {
    NSMutableDictionary *_plugins;
    NSMutableDictionary *_configs;
}
@end

@implementation OCPluginManager

- (instancetype)init {
    if ((self = [super init])) {
        _plugins = [[NSMutableDictionary alloc] initWithCapacity:8];
        _configs = [[NSMutableDictionary alloc] initWithCapacity:8];
    }
    return self;
}

- (void)dealloc {
    for (id<OCPlugin> plugin in [_plugins allValues]) {
        @try { [plugin deactivate]; } @catch (NSException *e) {}
    }
    [_plugins release]; [_configs release];
    [super dealloc];
}

- (NSArray *)loadedPlugins { return [_plugins allValues]; }

- (void)loadPluginsFromDirectory:(NSString *)directory {
    BOOL isDir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:directory isDirectory:&isDir] || !isDir) return;
    NSString *reason = UntrustedDirectory(directory);
    if (reason) {
        NSLog(@"[Plugins] refusing to load plugins: %@", reason);
        return;
    }
    NSArray *items = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil]
                      sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *item in items) {
        if (![item hasSuffix:@".bundle"]) continue;
        if ([_plugins count] >= kMaxPlugins) { NSLog(@"[Plugins] plugin limit reached"); break; }
        NSError *error = nil;
        if (![self loadPluginAtPath:[directory stringByAppendingPathComponent:item] error:&error])
            NSLog(@"[Plugins] did not load %@: %@", item, [error localizedDescription]);
    }
}

- (BOOL)loadPluginAtPath:(NSString *)bundlePath error:(NSError **)error {
    NSString *reason = UntrustedBundle(bundlePath);
    if (!reason) reason = UntrustedDirectory([bundlePath stringByDeletingLastPathComponent]);
    if (reason) {
        if (error) *error = PluginError(-4, reason);
        return NO;
    }
    NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
    if (!bundle || ![bundle load]) {
        if (error) *error = PluginError(-1, @"Failed to load bundle code");
        return NO;
    }
    Class principal = [bundle principalClass];
    if (!principal || ![principal conformsToProtocol:@protocol(OCPlugin)]) {
        if (error) *error = PluginError(-3, @"Principal class does not conform to OCPlugin");
        return NO;
    }
    id<OCPlugin> plugin = nil;
    @try { plugin = [[[principal alloc] init] autorelease]; } @catch (NSException *e) { plugin = nil; }
    NSString *pid = [plugin pluginId];
    if (![pid isKindOfClass:[NSString class]] || [pid length] == 0 || [_plugins objectForKey:pid]) {
        if (error) *error = PluginError(-5, @"Plugin has no id or reuses one");
        return NO;
    }
    [self _registerPlugin:plugin];
    NSLog(@"[Plugins] loaded %@ %@", [plugin pluginName], [plugin pluginVersion]);
    return YES;
}

- (void)_registerPlugin:(id<OCPlugin>)plugin {
    NSString *pid = [plugin pluginId];
    [_plugins setObject:plugin forKey:pid];
    @try {
        NSDictionary *config = [_configs objectForKey:pid];
        if (config && [plugin respondsToSelector:@selector(configDidChange:)]) [plugin configDidChange:config];
        [plugin activate];
    } @catch (NSException *e) {
        NSLog(@"[Plugins] %@ raised while activating: %@", pid, [e reason]);
        [_plugins removeObjectForKey:pid];
    }
}

- (void)unloadPlugin:(NSString *)pluginId {
    id<OCPlugin> plugin = [_plugins objectForKey:pluginId];
    if (!plugin) return;
    @try { [plugin deactivate]; } @catch (NSException *e) {}
    [_plugins removeObjectForKey:pluginId];
}

- (NSArray *)allPluginTools {
    NSMutableArray *tools = [NSMutableArray array];
    for (id<OCPlugin> plugin in [_plugins allValues]) {
        if (![plugin respondsToSelector:@selector(providedTools)]) continue;
        NSArray *items = nil;
        @try { items = [plugin providedTools]; } @catch (NSException *e) { items = nil; }
        if (![items isKindOfClass:[NSArray class]]) continue;
        for (id item in items) {
            OCToolDefinition *tool = ConfirmedTool(item);
            if (tool) [tools addObject:tool];
            else NSLog(@"[Plugins] %@ offered an invalid tool", [plugin pluginId]);
        }
    }
    return tools;
}

- (NSArray *)allPluginChannels {
    NSMutableArray *channels = [NSMutableArray array];
    for (id<OCPlugin> plugin in [_plugins allValues]) {
        if (![plugin respondsToSelector:@selector(providedChannels)]) continue;
        NSArray *items = nil;
        @try { items = [plugin providedChannels]; } @catch (NSException *e) { items = nil; }
        if (![items isKindOfClass:[NSArray class]]) continue;
        for (id ch in items) if ([ch conformsToProtocol:@protocol(OCChannel)]) [channels addObject:ch];
    }
    return channels;
}

- (void)setConfig:(NSDictionary *)config forPlugin:(NSString *)pluginId {
    if (!config || !pluginId) return;
    [_configs setObject:config forKey:pluginId];
    id<OCPlugin> plugin = [_plugins objectForKey:pluginId];
    if ([plugin respondsToSelector:@selector(configDidChange:)]) {
        @try { [plugin configDidChange:config]; } @catch (NSException *e) {}
    }
}

@end
