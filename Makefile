# Wrapper around CableScope's common dev commands. Full command/argument details
# live in the "Commands" section of AGENTS.md — this just shortcuts the ones
# typed most often, without duplicating subcommand specifics.

.PHONY: help build test test-kit test-cli run-cli run-app bundle bundle-release open xcodegen clean

help: ## List all available commands
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

build: ## Build CableKit / CableScopeCLI / CableScopeApp
	swift build

test: ## Run all tests (CableKitTests + CableScopeCLITests)
	swift test

test-kit: ## Run CableKitTests only (see AGENTS.md for --filter down to a class/method)
	swift test --filter CableKitTests

test-cli: ## Run CableScopeCLITests only
	swift test --filter CableScopeCLITests

run-cli: ## Run the CLI (defaults to pretty; pass ARGS for another subcommand, e.g. make run-cli ARGS="watch --interval 2")
	swift run CableScopeCLI $(if $(ARGS),$(ARGS),pretty)

run-app: ## Run the menu bar App directly (unbundled SwiftPM executable, no notification support)
	swift run CableScopeApp

bundle: ## Bundle a Debug .app (scripts/bundle_app.sh debug)
	./scripts/bundle_app.sh debug

bundle-release: ## Bundle a Release .app (scripts/bundle_app.sh release)
	./scripts/bundle_app.sh release

open: bundle ## Bundle a Debug .app and launch it
	open build/CableScope.app

xcodegen: ## Generate CableScope.xcodeproj (needed for Widget / App Store builds, not checked in)
	xcodegen generate

clean: ## Remove build artifacts (.build / build / xcodeproj)
	rm -rf .build build CableScope.xcodeproj

.DEFAULT_GOAL := help
