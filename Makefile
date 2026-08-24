.PHONY: help install global clean test lint check-contracts sync-version publish-dry-run publish logcat

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-15s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

install: ## Install dependencies
	dart pub get

global: ## Rebuild and install global version (clears snapshot cache)
	@echo "🔄 Deactivating current version..."
	@dart pub global deactivate oka 2>/dev/null || true
	@echo "🗑️  Clearing snapshot cache..."
	@rm -rf .dart_tool/pub/bin/oka
	@echo "📦 Installing global version..."
	@dart pub global activate --source path .
	@echo "✅ Done! Test with: oka --version"

clean: ## Clean build artifacts and caches
	@rm -rf .dart_tool
	@rm -rf build
	@echo "✅ Cleaned build artifacts"

test: ## Run tests
	dart test

lint: ## Run linter
	dart analyze

check-contracts: ## Run release contract gates (version sync, docs drift, changelog hygiene)
	bash tool/contracts/check_contracts.sh

sync-version: ## Sync all version touchpoints from VERSION
	bash tool/release/sync_version.sh

publish-dry-run: ## Dry-run pub.dev publish
	dart publish --dry-run

publish: ## Publish to pub.dev (requires publisher auth)
	dart publish --force

dev: ## Run oka locally without global install
	dart run bin/oka.dart

logcat: ## View logcat
	adb logcat | grep com.example.example/com.example.example.MainActivity

