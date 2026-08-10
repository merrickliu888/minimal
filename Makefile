APP_NAME ?= Minimal
BUNDLE_ID ?= dev.minimal.app
CODESIGN_IDENTITY ?= -
ARCH ?= $(shell uname -m)
BUILD_DIR = build
MIN_MACOS = 15.0
ICON_SOURCE = Assets/minimal-logo.png
ICONSET_DIR = $(BUILD_DIR)/Minimal.iconset
ICON_FILE = $(BUILD_DIR)/Minimal.icns

SOURCES = $(shell find Sources -name '*.swift' -type f | LC_ALL=C sort)
TEST_SOURCES = $(shell find Tests -name '*.swift' -type f | LC_ALL=C sort) \
	Sources/Core/StreamJSON.swift \
	Sources/Core/AgentModels.swift \
	Sources/Core/MinimalInteractionModel.swift \
	Sources/Core/SessionStore.swift \
	Sources/Core/ClaudeCodeLauncher.swift \
	Sources/Core/CodexLauncher.swift \
	Sources/Core/CodexStreamJSON.swift \
	Sources/Core/GitInfo.swift \
	Sources/Core/InlineTrigger.swift

empty :=
space := $(empty) $(empty)
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS)/MacOS
RESOURCES = $(CONTENTS)/Resources

SDK = $(shell xcrun --show-sdk-path)
SPM_BIN = .build/release

.PHONY: all app run test clean

all: app

# The app is built with SwiftPM (external dependency: Textual for markdown
# rendering); the bundle is still assembled by hand.
app: $(SOURCES) Package.swift Info.plist Minimal.entitlements $(ICON_FILE)
	swift build -c release
	@mkdir -p "$(MACOS_DIR)" "$(RESOURCES)"
	@cp "$(SPM_BIN)/$(APP_NAME)" "$(MACOS_DIR)/$(APP_NAME)"
	@# SwiftPM resource bundles (e.g. Textual's syntax highlighter grammars)
	@# must sit in Contents/Resources for Bundle.module to resolve. SwiftPM
	@# writes bundle files read-only, so stale copies must go before cp.
	@for b in "$(SPM_BIN)"/*.bundle; do \
		[ -e "$$b" ] || continue; \
		rm -rf "$(RESOURCES)/$$(basename "$$b")"; \
		cp -R "$$b" "$(RESOURCES)/"; \
	done
	@cp "$(ICON_FILE)" "$(RESOURCES)/"
	@cp Info.plist "$(CONTENTS)/"
	@plutil -replace CFBundleName -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleDisplayName -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleExecutable -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleIdentifier -string "$(BUNDLE_ID)" "$(CONTENTS)/Info.plist"
	@codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" --entitlements Minimal.entitlements "$(APP_BUNDLE)"
	@echo "Built $(APP_BUNDLE)"

$(ICON_FILE): $(ICON_SOURCE)
	@rm -rf "$(ICONSET_DIR)"
	@mkdir -p "$(ICONSET_DIR)"
	@sips -z 16 16 "$(ICON_SOURCE)" --out "$(ICONSET_DIR)/icon_16x16.png" >/dev/null
	@sips -z 32 32 "$(ICON_SOURCE)" --out "$(ICONSET_DIR)/icon_16x16@2x.png" >/dev/null
	@sips -z 32 32 "$(ICON_SOURCE)" --out "$(ICONSET_DIR)/icon_32x32.png" >/dev/null
	@sips -z 64 64 "$(ICON_SOURCE)" --out "$(ICONSET_DIR)/icon_32x32@2x.png" >/dev/null
	@sips -z 128 128 "$(ICON_SOURCE)" --out "$(ICONSET_DIR)/icon_128x128.png" >/dev/null
	@sips -z 256 256 "$(ICON_SOURCE)" --out "$(ICONSET_DIR)/icon_128x128@2x.png" >/dev/null
	@sips -z 256 256 "$(ICON_SOURCE)" --out "$(ICONSET_DIR)/icon_256x256.png" >/dev/null
	@sips -z 512 512 "$(ICON_SOURCE)" --out "$(ICONSET_DIR)/icon_256x256@2x.png" >/dev/null
	@sips -z 512 512 "$(ICON_SOURCE)" --out "$(ICONSET_DIR)/icon_512x512.png" >/dev/null
	@cp "$(ICON_SOURCE)" "$(ICONSET_DIR)/icon_512x512@2x.png"
	@iconutil -c icns "$(ICONSET_DIR)" -o "$(ICON_FILE)"
	@rm -rf "$(ICONSET_DIR)"

run: app
	open "$(APP_BUNDLE)"

test:
	@mkdir -p $(BUILD_DIR)
	swiftc -parse-as-library \
		-o $(BUILD_DIR)/minimal-tests \
		-sdk "$(SDK)" \
		-target $(ARCH)-apple-macosx$(MIN_MACOS) \
		$(TEST_SOURCES)
	$(BUILD_DIR)/minimal-tests

clean:
	rm -rf $(BUILD_DIR) .build
