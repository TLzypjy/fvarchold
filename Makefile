DEBUG = 0
FINALPACKAGE = 1

ARCHS = arm64 arm64e

# Share the SDK and deployment targets across schemes.
include AxsFVArcHoldBuild.mk
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AxsFVArcHold
AxsFVArcHold_FILES = $(wildcard Hooks/*.xm Sources/*.m)
AxsFVArcHold_CFLAGS = -I./Headers -I./Sources
AxsFVArcHold_FRAMEWORKS = UIKit Foundation CoreFoundation
AxsFVArcHold_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
