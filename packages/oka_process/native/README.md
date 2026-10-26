# posix-native helper (P1 — not built in this PR)

Rust + `libc` only. Prebuilt artifacts for:

- Linux: x64, arm64
- macOS: x64, arm64

Shipped inside the pub package with sha256 constants; copied to a `0700`
runtime directory and verified before exec. `posix-perl` remains the named
fallback.

Build and CI wiring is tracked in ADR-0052.
