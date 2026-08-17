THEOS_DEVICE_IP =
TARGET = iphone:clang:16.0:14.0
INSTALL_TARGET_PROCESSES = FreeFire

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AtlasMod
AtlasMod_FILES = AtlasMod.mm
AtlasMod_CFLAGS = -fobjc-arc -O2
AtlasMod_FRAMEWORKS = UIKit Foundation CoreGraphics ReplayKit CFNetwork

ARCHS = arm64

include $(THEOS)/makefiles/tweak.mk
