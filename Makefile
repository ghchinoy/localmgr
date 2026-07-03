APP_NAME = LocalMgr
BUILD_DIR = .build/release
APP_DIR = $(APP_NAME).app
CONTENTS_DIR = $(APP_DIR)/Contents
MACOS_DIR = $(CONTENTS_DIR)/MacOS
RESOURCES_DIR = $(CONTENTS_DIR)/Resources

.PHONY: all build app run clean

all: app

build:
	swift build -c release

app: build
	@echo "Creating $(APP_DIR)..."
	mkdir -p $(MACOS_DIR)
	mkdir -p $(RESOURCES_DIR)
	cp $(BUILD_DIR)/$(APP_NAME) $(MACOS_DIR)/$(APP_NAME)
	cp Info.plist $(CONTENTS_DIR)/Info.plist
	cp AppIcon.icns $(RESOURCES_DIR)/AppIcon.icns 2>/dev/null || true
	cp AppIcon.png $(RESOURCES_DIR)/AppIcon.png 2>/dev/null || true
	# Copy SPM resource bundles if present
	cp -R $(BUILD_DIR)/*.bundle $(RESOURCES_DIR)/ 2>/dev/null || true
	# Flush LaunchServices icon cache
	touch $(APP_DIR)
	@echo "$(APP_DIR) bundle created successfully."

run: app
	open $(APP_DIR)

clean:
	rm -rf .build $(APP_DIR)
