TARGET := iphone:clang:16.5:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = RadiantTidal
RadiantTidal_FILES = $(wildcard src/*.m)
RadiantTidal_CFLAGS = -fobjc-arc -Wall
RadiantTidal_FRAMEWORKS = UIKit MediaPlayer QuartzCore CoreGraphics CoreText Metal AVFoundation
RadiantTidal_USE_MODULES = 0

include $(THEOS_MAKE_PATH)/tweak.mk
