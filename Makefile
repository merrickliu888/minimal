APP_NAME ?= Overlay
BUNDLE_ID ?= dev.overlay.app
CODESIGN_IDENTITY ?= -
ARCH ?= $(shell uname -m)
BUILD_DIR = build
MIN_MACOS = 15.0

SOURCES = $(shell find Sources -name '*.swift' -type f | LC_ALL=C sort)
TEST_SOURCES = $(shell find Tests -name '*.swift' -type f | LC_ALL=C sort) \
	Sources/Core/StreamJSON.swift \
	Sources/Core/AgentModels.swift \
	Sources/Core/OverlayInteractionModel.swift \
	Sources/Core/SessionStore.swift \
	Sources/Core/ClaudeCodeLauncher.swift \
	Sources/Core/GitInfo.swift

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
app: $(SOURCES) Package.swift Info.plist Overlay.entitlements
	swift build -c release
	@mkdir -p "$(MACOS_DIR)" "$(RESOURCES)"
	@cp "$(SPM_BIN)/$(APP_NAME)" "$(MACOS_DIR)/$(APP_NAME)"
	@# SwiftPM resource bundles (e.g. Textual's syntax highlighter grammars)
	@# must sit in Contents/Resources for Bundle.module to resolve.
	@for b in "$(SPM_BIN)"/*.bundle; do \
		[ -e "$$b" ] && cp -R "$$b" "$(RESOURCES)/" || true; \
	done
	@cp Info.plist "$(CONTENTS)/"
	@plutil -replace CFBundleName -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleDisplayName -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleExecutable -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleIdentifier -string "$(BUNDLE_ID)" "$(CONTENTS)/Info.plist"
	@codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" --entitlements Overlay.entitlements "$(APP_BUNDLE)"
	@echo "Built $(APP_BUNDLE)"

run: app
	open "$(APP_BUNDLE)"

test:
	@mkdir -p $(BUILD_DIR)
	swiftc -parse-as-library \
		-o $(BUILD_DIR)/overlay-tests \
		-sdk "$(SDK)" \
		-target $(ARCH)-apple-macosx$(MIN_MACOS) \
		$(TEST_SOURCES)
	$(BUILD_DIR)/overlay-tests

clean:
	rm -rf $(BUILD_DIR) .build
