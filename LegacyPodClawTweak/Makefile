ARCHS = armv7
TARGET = iphone:clang:14.5:6.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LegacyPodClawTweak
LegacyPodClawTweak_FILES = Tweak.xm ../Frameworks/System/TLSClient.m
LegacyPodClawTweak_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore Security
LegacyPodClawTweak_LIBRARIES = sqlite3
LegacyPodClawTweak_CFLAGS = -Wno-deprecated-declarations -Wno-unused-variable -fno-objc-arc -I../Vendor/wolfssl/include -I../Vendor/wolfssl-build -I../Frameworks/System -DWOLFSSL_USER_SETTINGS -DSECURITY_ENHANCED
LegacyPodClawTweak_OBJ_FILES += $(THEOS_PROJECT_DIR)/Vendor/libwolfssl.a

include $(THEOS_MAKE_PATH)/tweak.mk
