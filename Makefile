# LegacyPodClaw - Theos Makefile
# Target: All iOS 6 ARMv7 devices
# Full gateway + channels + providers + tools + media + plugins

INSTALL_TARGET_PROCESSES = LegacyPodClaw

ARCHS = armv7
TARGET = iphone:clang:14.5:6.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = LegacyPodClaw

LegacyPodClaw_FILES = \
	main.m \
	Classes/AppDelegate.m \
	Classes/UI/RootViewController.m \
	Classes/UI/ChatViewController.m \
	Classes/UI/ChatCell.m \
	Classes/UI/SessionListViewController.m \
	Classes/UI/SettingsViewController.m \
	Classes/UI/ChannelSettingsViewController.m \
	Classes/Utils/Logger.m \
	Classes/Services/ConnectionService.m \
	Classes/Services/VoiceService.m \
	Frameworks/WebSocket/WebSocket.m \
	Frameworks/Memory/MemoryPool.m \
	Frameworks/Store/Store.m \
	Frameworks/Gateway/GatewayClient.m \
	Frameworks/Chat/ChatSession.m \
	Frameworks/Agent/Agent.m \
	Frameworks/Server/HTTPServer.m \
	Frameworks/Server/GatewayServer.m \
	Frameworks/Server/GatewayToken.m \
	Frameworks/Server/ServerWebSocket.m \
	Frameworks/Channels/ChannelManager.m \
	Frameworks/Channels/ChannelRouter.m \
	Frameworks/Channels/TLSWebSocket.m \
	Frameworks/Channels/TelegramChannel.m \
	Frameworks/Channels/DiscordChannel.m \
	Frameworks/Channels/IRCChannel.m \
	Frameworks/Channels/SlackChannel.m \
	Frameworks/Channels/WebhookChannel.m \
	Frameworks/Providers/ProviderRegistry.m \
	Frameworks/Providers/ProviderFormats.m \
	Frameworks/Tools/ExtendedTools.m \
	Frameworks/Media/MediaPipeline.m \
	Frameworks/Plugin/PluginSDK.m \
	Frameworks/Tools/SystemMCP.m \
	Frameworks/Tools/Guardrails.m \
	Frameworks/Tools/ToolDispatcher.m \
	Frameworks/Tools/ToolInputCheck.m \
	Frameworks/Tools/SkillRegistry.m \
	Frameworks/Tools/NotesReminders.m \
	Frameworks/Tools/NotesDatabase.m \
	Frameworks/Tools/MusicDownloader.m \
	Frameworks/System/System.m \
	Frameworks/System/TLSClient.m \
	Frameworks/System/HTTPResponseParser.m \
	Frameworks/System/SecretStore.m

LegacyPodClaw_CFLAGS = \
	-IFrameworks/WebSocket \
	-IFrameworks/Memory \
	-IFrameworks/Store \
	-IFrameworks/Gateway \
	-IFrameworks/Chat \
	-IFrameworks/Agent \
	-IFrameworks/Server \
	-IFrameworks/Channels \
	-IFrameworks/Providers \
	-IFrameworks/Tools \
	-IFrameworks/Media \
	-IFrameworks/Plugin \
	-IFrameworks/System \
	-IClasses \
	-IClasses/UI \
	-IClasses/Utils \
	-IClasses/Services \
	-fobjc-arc-exceptions \
	-Wno-deprecated-declarations \
	-Wno-unused-variable \
	-Wno-objc-method-access \
	-Wno-incompatible-pointer-types \
	-Wno-objc-protocol-property-synthesis \
	-Wno-protocol \
	-IVendor/wolfssl/include \
	-IVendor/wolfssl-build \
	-DWOLFSSL_USER_SETTINGS \
	-DSECURITY_ENHANCED

LegacyPodClaw_OBJCFLAGS = -fno-objc-arc

LegacyPodClaw_FRAMEWORKS = UIKit Foundation Security CoreGraphics QuartzCore AudioToolbox AVFoundation SystemConfiguration CFNetwork IOKit EventKit

LegacyPodClaw_LIBRARIES = sqlite3

LegacyPodClaw_CFLAGS += -Os -ffast-math -fvisibility=hidden -fvisibility-inlines-hidden
# the __RESTRICT segment makes dyld ignore DYLD_INSERT_LIBRARIES, which clawpodd relies on
LegacyPodClaw_LDFLAGS = -dead_strip -ldl -Wl,-sectcreate,__RESTRICT,__restrict,/dev/null
LegacyPodClaw_OBJ_FILES += $(THEOS_PROJECT_DIR)/Vendor/libwolfssl.a

LegacyPodClaw_RESOURCE_DIRS = Resources

include $(THEOS_MAKE_PATH)/application.mk

SUBPROJECTS += LegacyPodClawPrefs LegacyPodClawTweak LegacyPodClawNC LegacyPodClawDaemon
include $(THEOS_MAKE_PATH)/aggregate.mk

# host tests run on macOS with the system sdk, not on the device
test:
	$(MAKE) -C Tests test
.PHONY: test
