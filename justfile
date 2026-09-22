# oka — no-Gradle Flutter Android builds (ADR-0001).
# Run `just` to list recipes; `just <recipe>` to run one.

default:
    @just --list

# Install dependencies
install:
    dart pub get --no-example

# Rebuild and install global version from packages/oka (clears snapshot cache)
global:
    @echo "🔄 Deactivating current version..."
    @dart pub global deactivate oka 2>/dev/null || true
    @echo "🗑️  Clearing snapshot cache..."
    @echo "📦 Installing global version..."
    @dart pub global activate --source path packages/oka
    @echo "✅ Done! Test with: oka --version"

# Clean build artifacts and caches
clean:
    @rm -rf .dart_tool
    @rm -rf build
    @echo "✅ Cleaned build artifacts"

# Run tests: root cross-package suite + every package suite
test:
    dart test
    for pkg in packages/*/; do if [ -d "$pkg/test" ]; then echo "=== $pkg"; (cd "$pkg" && dart test) || exit 1; fi; done

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

# Dry-run the complete pub.dev package train
publish-dry-run:
    bash tool/release/publish_packages.sh --dry-run

# Publish the complete package train (requires publisher auth)
publish:
    bash tool/release/publish_packages.sh --publish

# Run oka locally without global install
dev:
    dart run packages/oka/bin/oka.dart

# View logcat
logcat:
    adb logcat | grep com.example.example/com.example.example.MainActivity
