# oka — no-Gradle Flutter Android builds (ADR-0001).
# Run `just` to list recipes; `just <recipe>` to run one.

default:
    @just --list

# Install dependencies
install:
    dart pub get

# Rebuild and install global version (clears snapshot cache)
global:
    @echo "🔄 Deactivating current version..."
    @dart pub global deactivate oka 2>/dev/null || true
    @echo "🗑️  Clearing snapshot cache..."
    @rm -rf .dart_tool/pub/bin/oka
    @echo "📦 Installing global version..."
    @dart pub global activate --source path .
    @echo "✅ Done! Test with: oka --version"

# Clean build artifacts and caches
clean:
    @rm -rf .dart_tool
    @rm -rf build
    @echo "✅ Cleaned build artifacts"

# Run tests
test:
    dart test

# Run linter (workspace members via dart analyze; example via flutter analyze)
lint:
    dart analyze
    -cd example && flutter analyze

# Run release contract gates (version sync, docs drift, changelog hygiene)
check-contracts:
    bash tool/contracts/check_contracts.sh

# Sync all version touchpoints from VERSION
sync-version:
    bash tool/release/sync_version.sh

# Build performance benchmarks against example/ (evidence in .steward/benchmark-summaries)
bench:
    bash tool/benchmarks/build_benchmarks.sh example

# Dry-run pub.dev publish
publish-dry-run:
    dart publish --dry-run

# Publish to pub.dev (requires publisher auth)
publish:
    dart publish --force

# Run oka locally without global install
dev:
    dart run bin/oka.dart

# View logcat
logcat:
    adb logcat | grep com.example.example/com.example.example.MainActivity
