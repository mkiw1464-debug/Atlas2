export THEOS ?= $(HOME)/theos

TARGET = iphone:clang:16.5:14.0
INSTALL_TARGET_PROCESSES = FreeFire

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AtlasMod
AtlasMod_FILES = AtlasMod.mm
AtlasMod_CFLAGS = -fobjc-arc -O2 -w
AtlasMod_FRAMEWORKS = UIKit Foundation CoreGraphics ReplayKit CFNetwork
AtlasMod_PRIVATE_FRAMEWORKS = 

ARCHS = arm64

include $(THEOS)/makefiles/tweak.mk
