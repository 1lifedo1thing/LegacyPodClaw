ARCHS = armv7
TARGET = iphone:clang:14.5:6.0

include $(THEOS)/makefiles/common.mk

TOOL_NAME = clawpodd
clawpodd_FILES = main.m SecretServer.m
clawpodd_FRAMEWORKS = Foundation CoreFoundation IOKit Security
clawpodd_CFLAGS = -fno-objc-arc -Wno-deprecated-declarations -I../Frameworks/System
clawpodd_INSTALL_PATH = /usr/bin
clawpodd_CODESIGN_FLAGS = -Sentitlements.plist
clawpodd_LDFLAGS = -ldl

include $(THEOS_MAKE_PATH)/tool.mk
