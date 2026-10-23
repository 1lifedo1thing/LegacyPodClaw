---
title: "Plugin SDK"
description: "Write a plugin that adds tools or chat channels"
weight: 4
---

A plugin is a `.bundle` that adds tools, chat channels or both. The protocol is in `Frameworks/Plugin/PluginSDK.h`.

## Where plugins load from

The app loads plugins from `/Library/LegacyPodClaw/Plugins` when it starts. The package makes this directory, owned by root with mode 0755.

The app refuses a plugin in these conditions:

- The plugin directory is not owned by root, or its group or others can write to it.
- A parent directory is not owned by root, or others can write to it.
- A file in the bundle is not owned by root, or its group or others can write to it.
- A path is a symbolic link.

Only a package that installs as root can thus add a plugin. The app loads at most 16 plugins.

## The OCPlugin protocol

The bundle's principal class must conform to `OCPlugin`:

```objc
@protocol OCPlugin <NSObject>
@required
@property (nonatomic, readonly) NSString *pluginId;
@property (nonatomic, readonly) NSString *pluginName;
@property (nonatomic, readonly) NSString *pluginVersion;
- (void)activate;
- (void)deactivate;
@optional
- (NSArray *)providedTools;
- (NSArray *)providedChannels;
- (void)configDidChange:(NSDictionary *)config;
@end
```

- `pluginId` must not be empty and must be unique.
- The app calls `activate` after it loads the plugin. If `activate` raises an exception, the app removes the plugin.

## Tools

`providedTools` returns an array. Each item is an `OCToolDefinition` or a dictionary with these keys:

| Key | Type | Notes |
|---|---|---|
| `name` | `NSString` | 1 to 64 characters: letters, digits, `_` and `-` |
| `description` | `NSString` | Sent to the model |
| `inputSchema` | `NSDictionary` | A JSON Schema object. The default is an empty object schema. |
| `handler` | block | `^(NSDictionary *params, OCToolResultBlock callback)` |
| `timeout` | `NSNumber` | Seconds. The maximum is 120. |

```objc
- (NSArray *)providedTools {
    return @[@{
        @"name": @"my_custom_tool",
        @"description": @"Does something useful",
        @"inputSchema": @{
            @"type": @"object",
            @"properties": @{@"query": @{@"type": @"string"}},
            @"required": @[@"query"]
        },
        @"handler": [[^(NSDictionary *params, OCToolResultBlock callback) {
            callback(@"done", nil);
        } copy] autorelease]
    }];
}
```

The app copies each tool into a new definition with `requiresConfirmation` set to `YES`. The user thus approves every plugin tool call. The app registers plugin tools after the built-in tools, so a plugin tool cannot replace a built-in tool.

## Channels

`providedChannels` returns objects that conform to `OCChannel` (`Frameworks/Channels/ChannelManager.h`):

- `channelId`, `isConnected`, `isConfigured` and `messageDelegate`
- `start`, `stop` and `sendMessage:toChatId:threadId:`
- Optional: `sendTypingIndicator:` and `statusInfo`

Call `[messageDelegate channel:self didReceiveMessage:msg]` on the main thread for each inbound message. A channel ID that another channel uses is refused.

Set the channel's allow list with the `<channelId>AllowedIds` preference in the settings file. An empty list ignores everyone.

## MCP servers

A plugin does not add MCP servers. To add MCP tools, set **Server 1** or **Server 2** in **Settings > LegacyPodClaw > Local Agent**.
