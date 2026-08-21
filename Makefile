.DEFAULT_GOAL := help

APP_NAME := $(shell ./Scripts/bundle.sh --name)
APP := build/$(APP_NAME)
INSTALL_DIR := /Applications
# Every identifier this app has shipped under, so a rename does not leave the copy
# installed under the previous name behind.
APP_IDS := me.thales.conductor|me.thales.process-compose-macos

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

.PHONY: build
build: ## Compile the debug build
	swift build

.PHONY: test
test: ## Run the ProcessComposeCore test suite
	swift test

.PHONY: run
run: ## Run the debug build without bundling it
	swift run process-compose-macos

.PHONY: icon
icon: ## Redraw AppIcon.icns from Scripts/make-icon.swift
	@rm -rf build/AppIcon.iconset
	@mkdir -p build
	swift Scripts/make-icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

.PHONY: app
app: ## Assemble the .app into build/
	./Scripts/bundle.sh

.PHONY: install
install: app ## Build and copy the app to /Applications
	rm -rf "$(INSTALL_DIR)/$(APP_NAME)"
	cp -R "$(APP)" "$(INSTALL_DIR)/$(APP_NAME)"
	@for candidate in "$(INSTALL_DIR)"/*.app; do \
		if [ -d "$$candidate" ] && [ "$$candidate" != "$(INSTALL_DIR)/$(APP_NAME)" ]; then \
			case "$$(plutil -extract CFBundleIdentifier raw -o - "$$candidate/Contents/Info.plist" 2>/dev/null)" in \
				$(APP_IDS)) rm -rf "$$candidate"; echo "removed $$candidate";; \
			esac; \
		fi; \
	done
	@echo "installed $(INSTALL_DIR)/$(APP_NAME)"

.PHONY: clean
clean: ## Remove build products
	rm -rf .build build
