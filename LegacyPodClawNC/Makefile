ARCHS = armv7
TARGET = iphone:clang:14.5:6.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = LegacyPodClawNC
LegacyPodClawNC_FILES = LegacyPodClawNCController.m
LegacyPodClawNC_INSTALL_PATH = /System/Library/WeeAppPlugins
LegacyPodClawNC_FRAMEWORKS = UIKit Foundation
LegacyPodClawNC_RESOURCE_DIRS = Resources
LegacyPodClawNC_CFLAGS = -fno-objc-arc -Wno-deprecated-declarations -I../Frameworks/System -I../Frameworks/Providers

include $(THEOS_MAKE_PATH)/bundle.mk
