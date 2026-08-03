APP_NAME ?= Assistant
BUNDLE_ID ?= dev.assistant.overlay
CODESIGN_IDENTITY ?= -
ARCH ?= $(shell uname -m)
BUILD_DIR = build
MIN_MACOS = 14.0

SOURCES = $(shell find Sources -name '*.swift' -type f | LC_ALL=C sort)
TEST_SOURCES = $(shell find Tests -name '*.swift' -type f | LC_ALL=C sort) \
	Sources/Core/StreamJSON.swift \
	Sources/Core/AgentModels.swift \
	Sources/Core/OverlayInteractionModel.swift \
	Sources/Core/SessionStore.swift \
	Sources/Core/ClaudeCodeLauncher.swift

empty :=
space := $(empty) $(empty)
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS)/MacOS
RESOURCES = $(CONTENTS)/Resources

SDK = $(shell xcrun --show-sdk-path)

.PHONY: all app run test clean

all: app

app: $(SOURCES) Info.plist Assistant.entitlements
	@mkdir -p "$(MACOS_DIR)" "$(RESOURCES)"
	swiftc -parse-as-library \
		-o "$(MACOS_DIR)/$(APP_NAME)" \
		-sdk "$(SDK)" \
		-target $(ARCH)-apple-macosx$(MIN_MACOS) \
		-O \
		$(SOURCES)
	@cp Info.plist "$(CONTENTS)/"
	@plutil -replace CFBundleName -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleDisplayName -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleExecutable -string "$(APP_NAME)" "$(CONTENTS)/Info.plist"
	@plutil -replace CFBundleIdentifier -string "$(BUNDLE_ID)" "$(CONTENTS)/Info.plist"
	@codesign --force --options runtime --sign "$(CODESIGN_IDENTITY)" --entitlements Assistant.entitlements "$(APP_BUNDLE)"
	@echo "Built $(APP_BUNDLE)"

run: app
	open "$(APP_BUNDLE)"

test:
	@mkdir -p $(BUILD_DIR)
	swiftc -parse-as-library \
		-o $(BUILD_DIR)/assistant-tests \
		-sdk "$(SDK)" \
		-target $(ARCH)-apple-macosx$(MIN_MACOS) \
		$(TEST_SOURCES)
	$(BUILD_DIR)/assistant-tests

clean:
	rm -rf $(BUILD_DIR)
