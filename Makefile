# CLT-only build path. Works today, with no Xcode installed.
#
# Assembles a real .app bundle rather than a bare binary, because UNUserNotificationCenter refuses to
# work outside a properly formed, code-signed bundle. Ad-hoc signing (`codesign -s -`) is enough for
# local use.

APP     := NotifyMe
BUILD   := build
BUNDLE  := $(BUILD)/$(APP).app
BIN     := $(BUNDLE)/Contents/MacOS/$(APP)
SRC     := $(shell find Sources -name '*.swift')

SWIFTC_FLAGS := -O \
                -target arm64-apple-macos13.0 \
                -framework AppKit \
                -framework UserNotifications \
                -framework ServiceManagement

.PHONY: all build run stop clean xcode fmt

all: build

$(BIN): $(SRC)
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	swiftc $(SWIFTC_FLAGS) -o $@ $(SRC)

## Regenerate the icon from Tools/icon. Vector-drawn at every size — a resampled 1024 turns the gap
## and the dot to porridge at 16pt, and those are the whole idea.
Resources/AppIcon.icns: Tools/icon/main.swift
	@mkdir -p Resources
	@swiftc -O -target arm64-apple-macos13.0 -o /tmp/ct-icon Tools/icon/main.swift -framework AppKit
	@/tmp/ct-icon Resources >/dev/null
	@iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
	@echo "regenerated Resources/AppIcon.icns"

build: $(BIN) Info.plist Resources/AppIcon.icns
	@cp Info.plist $(BUNDLE)/Contents/Info.plist
	@cp Resources/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	@codesign --force --sign - $(BUNDLE) 2>/dev/null
	@echo "built $(BUNDLE)"

## Relaunch the app. Kills any running copy first — two status items is worse than none.
run: build
	@pkill -x $(APP) 2>/dev/null || true
	@open $(BUNDLE)
	@echo "launched — look at the menu bar"

stop:
	@pkill -x $(APP) 2>/dev/null || true

## Regenerate NotifyMe.xcodeproj from project.yml. Run after adding or moving files.
xcode:
	xcodegen generate
	@echo "regenerated NotifyMe.xcodeproj"

clean:
	rm -rf $(BUILD)
