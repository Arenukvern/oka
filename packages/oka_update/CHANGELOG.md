# Changelog

## 0.12.1

### Patch Changes

- **Release-train smoke cut — the first train where every published package
  has its own verified per-package pub.dev tag pattern
  (`<package>-v{{version}}`, repo `Arenukvern/oka`).**
  
  - Automated publishing verified server-side for all 17 published packages;
    `oka_service`, `oka_desktop`, `oka_google_play`, `oka_app_gallery`
    re-enabled after config drift, `oka_update` enabled for the first time.
  - No functional changes: the patch bumps exercise the OIDC publish legs
    end-to-end against the corrected tag patterns.
All notable changes to this package are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.12.0

See `packages/oka/CHANGELOG.md` for train-wide release notes.

## 0.11.0

Joins the release train: the air-channel authoring surface (ADR-0031),
planner eligibility, revision manifests, and the signed channel model
(ADR-0037) are published to pub.dev with the next train version.

