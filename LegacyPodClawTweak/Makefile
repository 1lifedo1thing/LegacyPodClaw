ARCHS = armv7
TARGET = iphone:clang:14.5:6.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LegacyPodClawTweak
LegacyPodClawTweak_FILES = Tweak.xm ../Frameworks/System/TLSClient.m ../Frameworks/System/HTTPResponseParser.m ../Frameworks/System/SecretStore.m \
	../Frameworks/Providers/ProviderRegistry.m ../Frameworks/Providers/ProviderFormats.m ../Frameworks/Providers/QuickAsk.m
LegacyPodClawTweak_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore
LegacyPodClawTweak_LIBRARIES = sqlite3
LegacyPodClawTweak_CFLAGS = -Wno-deprecated-declarations -fno-objc-arc -I../Vendor/wolfssl/include -I../Vendor/wolfssl-build -I../Frameworks/System -I../Frameworks/Providers -I../Frameworks/Agent -I../Frameworks/Store -I../Frameworks/Memory -DWOLFSSL_USER_SETTINGS
LegacyPodClawTweak_OBJ_FILES += $(THEOS_PROJECT_DIR)/Vendor/libwolfssl.a

include $(THEOS_MAKE_PATH)/tweak.mk
