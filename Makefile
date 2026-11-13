THEOS ?= $(CURDIR)/theos
ARCHS = arm64e
TARGET = iphone:clang:16.5:16.0
INSTALL_TARGET_PROCESSES = MobileSlideShow

include $(THEOS)/makefiles/common.mk

PACKAGE_NAME = com.simon.hidden-album
PACKAGE_VERSION = 0.1.0

TWEAK_NAME = HiddenAlbum
HiddenAlbum_FILES = Sources/Tweak.m Sources/HAAlbumInventory.m
HiddenAlbum_CFLAGS = -fobjc-arc -DAPELIN_BOOTSTRAP_ROOTHIDE=1
HiddenAlbum_FRAMEWORKS = Foundation UIKit Photos
HiddenAlbum_LIBRARIES = substrate
HiddenAlbum_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

BUNDLE_NAME = HiddenAlbumSettings
HiddenAlbumSettings_FILES = PreferenceBundle/Sources/HiddenAlbumSettingsRootListController.m PreferenceBundle/Sources/HiddenAlbumAlbumsController.m
HiddenAlbumSettings_CFLAGS = -fobjc-arc -DAPELIN_BOOTSTRAP_ROOTHIDE=1
HiddenAlbumSettings_FRAMEWORKS = Foundation UIKit Preferences
HiddenAlbumSettings_RESOURCE_DIRS = PreferenceBundle/Resources
HiddenAlbumSettings_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk
