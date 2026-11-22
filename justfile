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
    dart analyze --fatal-infos
    -cd example && flutter analyze

# Run release contract gates (version sync, docs drift, changelog hygiene)
check-contracts:
    bash tool/contracts/check_contracts.sh

# Build performance benchmarks against example/ (evidence in .steward/benchmark-summaries)
bench:
    bash tool/benchmarks/build_benchmarks.sh example

# Kernel/live-stack benchmarks: composition loop, delta pipeline, AOT exe
bench-kernel:
    bash tool/benchmarks/kernel_benchmarks.sh

# Publish the pub.dev train: dart_changesets CI does it — a pending
# .changesets/*.md intent lands a version PR (dart_changesets.yml); its
# merge tags every package and the per-tag publish workflow (OIDC) runs.

# Run oka locally without global install
dev:
    dart run packages/oka/bin/oka.dart

# View logcat
logcat:
    adb logcat | grep com.example.example/com.example.example.MainActivity
