.PHONY: help install global clean test lint

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

dev: ## Run oka locally without global install
	dart run bin/oka.dart

