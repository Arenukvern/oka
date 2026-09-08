# Security Policy

## Supported versions

Oka is pre-1.0; only the latest published version receives security fixes.

## Reporting a vulnerability

Please do **not** open a public issue for security problems.

- Email: use the GitHub contact for [@Arenukvern](https://github.com/Arenukvern)
  or open a [GitHub security advisory](https://github.com/Arenukvern/oka/security/advisories/new).

Include: affected version/commit, reproduction steps, and impact. You can
expect an initial response within 7 days.

## Scope notes

- Oka executes local build tooling (`aapt2`, `javac`, `d8`, `apksigner`, …)
  and downloads artifacts from Google Maven / Maven Central into
  `~/.oka/cache/maven`. Reports involving artifact integrity, command
  injection via `oka.yaml` fields, or path traversal in cache handling are
  in scope.
- The AI-assisted Gradle conversion sends `build.gradle` text to the
  configured model provider (Apple Foundation Models / Gemini). Do not put
  secrets in Gradle files.
