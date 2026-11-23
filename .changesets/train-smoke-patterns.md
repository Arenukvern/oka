---
'oka_core': patch
'oka_harness': patch
'oka_process': patch
'oka_update': patch
'resource_composition': patch
---

**Release-train smoke cut — the first train where every published package
has its own verified per-package pub.dev tag pattern
(`<package>-v{{version}}`, repo `Arenukvern/oka`).**

- Automated publishing verified server-side for all 17 published packages;
  `oka_service`, `oka_desktop`, `oka_google_play`, `oka_app_gallery`
  re-enabled after config drift, `oka_update` enabled for the first time.
- No functional changes: the patch bumps exercise the OIDC publish legs
  end-to-end against the corrected tag patterns.
