# Scratch extraction and retirement audit

Owner: visualization delivery lane, 2026-10-13. This is a retirement plan, not a
blanket authorization to remove other agents' or unrelated scratch work.

| Existing path | Extracted owner / value | Retirement condition |
| --- | --- | --- |
| `~/xs/scratch/ecsly_visualization_preview` (2.3 GiB) | Source → ecsly examples + dogfood tool; browser lifecycle → oka_web; raw diagnostics → studio validation/raw_history, hashed manifest | Finish optional native tooling/evaluation extraction, update all active references, validate canonical/scaffold/dogfood, prove no live process uses this root |
| `~/xs/scratch/ecsly_visualization_tokens` | Pure Dart tokens → ecsly examples/visualization_tokens | Verify consumer/scaffold paths use canonical package |
| `~/xs/scratch/ecsly_visualization_from_skill` (129 MiB) | Historical scaffold baseline; source largely a generated copy | Preserve unique differences/test receipts, then classify as regenerable |
| `~/xs/scratch/ecsly_visualization_resident_from_skill` (130 MiB) | Historical resident scaffold baseline | Same unique-diff/receipt check; fresh canonical scaffold test replaces active use |
| `~/xs/scratch/pdg_run10.log` | Unknown other lane | Establish owner before moving/deleting; do not touch in visualization cleanup |

110 historical diagnostics/research files (about 5.6 MB) were copied with SHA-256
provenance into the example-owned, gitignored raw history. This includes failed
native/background/capture and browser-shell runs. SDK caches, compiled bundles,
generated shader output and browser profiles are reproducible state, not durable
source. They must not be carried forward as unexplained gigabyte artifacts.

Active skill/docs links have been migrated to canonical owners. Raw forensic
provenance can name an old path; runnable code or
an active documentation link must not depend on it. Keep the source of a discarded
alternative and its failure evidence when it explains a current design constraint.

No scratch directory has been deleted by this audit. Cleanup is complete only
when package-owned source, evaluation definitions and evidence are verified, active
references are migrated, and process/profile ownership is resolved.

## Follow-up source audit

A hashed source-audit.json now retains the native background-launch probe, native
window capture, targeting adapter, browser candidate/dev/resident verification
programs, and unique files from both generated scaffold apps. These are diagnostic
sources, not qualified portable tooling: their absolute imports/dependency paths
still require extraction into the owning packages. The generated apps retain 12
and 16 differing files respectively, including their platform/manifest differences.

The preview footprint is dominated by .oka_cache (1.2 GB), build (686 MB), and
.dart_tool (421 MB). None is a source asset. A process scan after the supervised
trial found no process referencing a scratch visualization root; this observation
does not establish profile-lease reconciliation. Canonical skill references now
point into the owning example and archived evidence. The installed skill now routes to the canonical repository source, and a fresh scaffold
passes clean analysis and 10 tests.

The corrected source-only audit excludes .oka_cache and other session/generated
directories. It preserves all 83 preview source files, 12 differences in the first
generated app, 16 in the resident generated app, and both token-package files.
The previous installed skill is preserved separately before switching to a symlink.
The preview process-lease directory is empty; no owned scratch process was observed.
Removal of the four visualization roots can now be planned from these retained
sources/evidence. Optional native probes remain diagnostic source for later
qualification, and the unrelated pdg_run10.log has no established owner.

## Current retirement check

The 2026-10-13 follow-up checked all 223 current source files across the four
visualization roots against retained SHA-256 records or an identical archived
prototype baseline. It also verified all 110 historical evidence files. There
were no missing files or hash mismatches. The receipt is
`ecsly/examples/visualization_studio/validation/raw_history/2026-10-13/retirement-check.json`.
No scratch-referencing process or process-lease JSON file was observed. A focused
search of the canonical skills, ecsly tools, Oka kernel tools and validation docs
found scratch references only in this retirement document.

The reusable pieces now have these homes:

- Visualization app, resident viewer, three recipes and tests: ecsly
  `examples/visualization_studio`; presentation tokens: `examples/visualization_tokens`.
- Scaffold and usage instructions: ecsly `.agents/skills/ecsly-visualization`.
- Real browser/build/reload experiments: ecsly `tool/visualization_dogfood` and
  `tool/visualization_dev_cohort`; browser lifecycle and session mechanisms: Oka.
- Discarded native/background probes, generated-app differences and failed-run
  evidence: the hashed local raw-history archive. These remain diagnostic source;
  they need not remain executable in scratch to support later extraction.

The four visualization directories are therefore removal candidates after a
fresh process check immediately before deletion. The archive is gitignored local
data: this establishes preservation on this machine, not a durable remote backup.
Do not delete that archive together with scratch. No deletion was performed.

`pdg_run10.log` identifies `last_answer/tool/gates/paired_device_gate.dart` and a
failed Android APK build. It is a separate Last Answer diagnostic, not visualization
source. Leave the original in place until that lane confirms retention or disposal;
its local connection addresses should not be copied into public example content.

Native launch source extraction: the archived background_launch.swift probe is
now generalized in Oka tool/native_preview/native_launch_probe.swift. It accepts
explicit app/output/posture, refuses an existing instance, writes launch intent,
requires an unlocked logged-in console session and verifies returned-app teardown.
The ecsly supervised native wrapper resolves that explicit editable Oka dependency
and retains the probe source hash. Native window capture/automation diagnostics
remain archived pending separate portability and runtime qualification.
