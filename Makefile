.DEFAULT_GOAL := help

APP := build/Conductor.app
INSTALL_DIR := /Applications

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

.PHONY: build
build: ## Compile the debug build
	swift build

.PHONY: test
test: ## Run the ConductorCore test suite
	swift test

.PHONY: run
run: ## Run the debug build without bundling it
	swift run Conductor

.PHONY: icon
icon: ## Redraw AppIcon.icns from Scripts/make-icon.swift
	@rm -rf build/Conductor.iconset
	@mkdir -p build
	swift Scripts/make-icon.swift build/Conductor.iconset
	iconutil -c icns build/Conductor.iconset -o Resources/AppIcon.icns

.PHONY: app
app: ## Build Conductor.app into build/
	./Scripts/bundle.sh

.PHONY: install
install: app ## Build and copy the app to /Applications
	rm -rf $(INSTALL_DIR)/Conductor.app
	cp -R $(APP) $(INSTALL_DIR)/Conductor.app
	@echo "installed $(INSTALL_DIR)/Conductor.app"

.PHONY: clean
clean: ## Remove build products
	rm -rf .build build
