# Visualization delivery qualification

This active work record preserves the full requested scope: extract reusable examples,
skills/docs/baselines; use Oka supervisor in real usage and improve required libraries;
apply the prior focus/latency recommendations; complete a visualization dogfood run.
It is not a release/adoption claim. Completed evidence belongs in the owning guides.

| Requirement | Owner / intended evidence | Current status |
| --- | --- | --- |
| Three recipes, resident model, reusable visual vocabulary | ecsly consuming example + tests | Canonical example: 21 tests and clean analysis; fresh scene-free Wasm scaffold: 11 tests, build and actual runtime pass; prior 14-effect multi-view proof retained |
| Canonical skill, evaluation cases and reproducible baseline | ecsly skill referencing example, held-out cases, benchmark JSON | Canonical routing/scaffold and one frozen novel implementation pair verified; baseline headless semantics refusal retained; broader independent promotion-grade cases pending |
| General browser page/session API, bounded lifecycle | oka_web API + unit/real consumer | Page API: 8 tests; ownership/probe regressions pass; real retained-browser consumer passed |
| Supervisor-managed visualization, health, lifecycle facts | supervisor plan + real start/observe/restart/stop receipts | Real job and single-service lifecycle pass; fresh-runner recovery after host SIGKILL passes; spawn-time crashes and detached browser trees remain unqualified |
| Correct declarative process argv | oka CLI real argument roundtrip, malformed preflight | 20 CLI tests including exact argv and nonzero job failure passed |
| Nonactivating launch policy | browser headless default; native platform API + unlocked desktop trial | Background native launch, integrated attach/reload/restart/quit pass; production native launch API remains open |
| Native background focus/frame waits and pixel correctness | toolkit/native real focused/background tests, capture before/after | Native Canvas background frame/capture and instrumented toolkit button effects/stale refusal pass with no OS activation events; OS AX window exposure, keyboard/widget focus and earlier transformed-capture causality remain open |
| Resident compiler and affected-module invalidation | DDC session baseline + fixed method/signature/import cohort | Flutter/DDC and native CLI method/signature/import cohorts pass; native restart, subsequent reload and detach pass; broader workload/invalidation closure pending |
| Multi-view host, per-view state and lifecycle | Flutter multi-view tests + real mount/remove/reapply | Scene-free shared-engine: 14 checks; single-view: six checks; 13 contracts pass |
| Immutable assets/cache validity and stable engine resources | cache hit/miss/stale controls + real navigation | Output manifest, snapshot serving, stale-byte refusal, revalidation and Canvas digest-loader/cache reuse pass; compiler input closure and broader deployment pending |
| Feature-scoped shader preparation / lazy optional effects | flutter_scene source owner, parity tests + first-frame cohort | Opt-in deferred lookup and structural presence tested in isolated web engine; broader material/native/default coverage, asset/texture policy and upstream adoption pending |
| Explicit first meaningful frame and startup owner timings | app/scene/GPU evidence separate from transport/cache/compiler | Per-world initialization/render-return trace and inspected early capture pass; compositor-presentation timestamp and controlled cold/warm cohorts remain pending |
| Swappable browser/native runtime lanes | same declared profile, versioned compatibility/perf receipts | Chrome JS/Wasm three-pair cohort with matching source/SDK/browser passes; shell failed frame wait; broader cold/warm, compositor and Ladybird/Dart-aware experiments open |
| One end-to-end visualization dogfood | generated source → supervisor → real interaction → pixels → teardown | Fresh scene-free scaffold: build + six real interactions + retained-browser/multi-view jobs + inspected pixels + teardown pass |

Recommendations must not be declared implemented merely because an adapter exists.
Research alternatives require explicit prototypes/compatibility results, not silent
production adoption. No fixed millisecond promise for arbitrary cold compilation is
made. Both successful and failed receipts are retained. Other agents' supervisor
planner/codemap-index, native automation bridge, and ecsly scene gesture work are
preserved; this lane owns only declared disjoint changes.

2026-10-13 canonical dogfood: `dogfood-ax-readiness-2026-10-13` records job
succeeded, six observed effects, zero runtime exceptions, and no compiler invocation
during the resident update. That update completed a Flutter frame in 31.100 ms.
Browser attachment took 3.288 s; app state 4.062 s; scene semantics 6.585 s. These
are one-run startup stages, not p95 or first meaningful compositor-frame guarantees.
Graph and linked-dark captures were independently inspected. No owned browser/worker
remained in the post-run process scan.

Real failures corrected two owners: Oka emitted window-size using `x` rather than
Chrome's documented comma syntax; shared CDP semantic targeting refused missing AX
projection immediately after a state transition. Window size now provides observed
1120×913 viewport; targeting polls absence within its existing deadline and still
refuses duplicate matches before input. Seven targeting tests pass, including missing
projection before click/focus. Earlier failed receipts remain alongside success.

Scratch retirement: source, unique generated-app differences and raw diagnostics
are archived with hashes; installed skill now routes to canonical source. See
scratch_extraction.md. No scratch directory was removed.

Job lifecycle regression: eight real-process provider tests pass, including delayed
zero/nonzero exit after handshake and cancellation after readiness with verified
owned-process death and lease cleanup. This does not prove forced-crash recovery
or service lifecycle readiness. Oka docs drift and changed-source analysis pass.

2026-10-13 multi-view slice: one public Flutter engine mounts independently
addressed worlds via ViewCollection/runWidget. Logical viewer IDs scope document
actions, state reads, semantics and checkpoint keys. Removing a view unregisters
only the matched instance and disposes its controller; remount restores validated
checkpoint data into a new world. The embedding host catalog is preserved and
collisions refuse. Public full-page behavior remains supported through optional
bridge arguments. Both real jobs pass with no runtime exceptions; the two-view
capture was inspected and owned processes stopped. These are small, potentially
contended runs, not a performance or arbitrary-view-count claim.

Skill guidance cases and raw paired answers are now example-owned. The first pair
was criterion-exposed; fresh prompt-only held-out seats produced no observed harmful
guidance regression, but the complete skill package was not immutable during
execution. Static/routing guidance and runtime quality remain separate. Stronger
held-out promotion and late native checkpoint-write races remain pending.

Baseline preservation: the consuming build tool now writes immutable build-trials
receipts and a latest pointer. A real build verified receipt serialization, consumer
source hashes and current release flags. The hash excludes the full SDK/dependency
and generated native shader closure; no reproducible-binary/cache-validity claim
follows. Source inspection confirms Scene's static initializer memoizes its future
across views, but currently prepares base/material/SMAA resources together.
Feature-scoped shader preparation and startup profiling remain pending.

2026-10-13 retained-code work:

- The canonical generated-consumer cohort changed an external token package's
  method, compatible signature and import through one Oka/Flutter DDC session,
  preserving runtime/document/camera/selection. The initial trial changed state
  but emitted twelve duplicate-definition exceptions. Flutter SIGUSR1 owned
  compile/apply and the old target also called DWDS reloadSources.
- The dev runner now injects one acknowledged platformReload owner; an unsafe
  signal-only target refuses before dispatch. New-output command correlation
  avoids reading an old acknowledgement. Real zero-runtime-error trials pass.
- A traced supervised run exposed a fixed 4,000 ms settle delay after Flutter's
  completed reload. Removing it from the acknowledged owner path preserved
  all three effects and continuity: method 1,617.631 ms (first edit), signature
  222.180 ms, import 222.470 ms in the final bounded trial. The prior traced
  signature/import were about 4,222/4,217 ms. These one-run code-effect timings
  do not establish millisecond cold startup or compositor presentation.
- A stock retained Flutter frontend reproducer now lives in Oka's kernel tool
  package, with SDK/output roots as inputs, immutable request artifacts and
  expected error-count gates. A tiny library recompiles in single-digit ms;
  this is compiler-only evidence, not an application/native reload guarantee.
- Real invalid source wrote a nonempty dill while exiting 254. The one-shot
  delta compiler now requires zero exit, complete matching zero-error terminal
  and a nonempty expected artifact, and removes only its failed owned temp
  directory. Three focused parser/real-compiler tests pass; dev composition
  and dependency tests bring the focused kernel run to eight passes.

The frontend protocol requires an accepted baseline. Native retention integration
must bind accept/reject to known consumer effects, preserve unknown effects without
replay and handle source/package/toolchain identity. It remains pending. Additional
latency work follows actual compiler/app/scene/presentation measurements.

2026-10-13 service lifecycle dogfood: the package-owned
`oka_supervisor/tool/service_lifecycle_dogfood.dart` accepts a fresh evidence
directory and refuses overwriting one. A real Dart service starts, is observed
read-only, exits with code 7, restarts once, stops through its identity-bearing
provider and refuses another restart at the same exhausted revision. Lifecycle
JSONL, per-stage plans, registry records and a cleanup result are retained in
`oka_supervisor/output/service-lifecycle-2026-10-13`. The run passed and verified
owned-process death and lease removal. The supervisor runner remained alive;
this does not qualify recovery after a supervisor-host crash.

A separate real service regression exposed stopped stdout draining after the
readiness handshake: a gated two-MiB flush could not finish. Service pumps now
remain attached until process exit. Synthetic identity/cleanup regressions also
cover unknown-stop lease retention, stale-stop preservation of a replacement
lease, and recycled/unverifiable inspection. These are distinct evidence scopes.

A real gated-job regression also reproduced unconditional lease deletion after
successful exit: a newer lease with the same ID disappeared. Job completion now
uses the same matching-PID/token guard. The regression passes after the fix.
The final focused provider run passes 13 tests; three real supervisor lifecycle
tests pass. Changed-source analysis, documentation drift and diff whitespace
checks pass. The final dogfood at
`oka_supervisor/output/service-lifecycle-with-stop-facts-2026-10-13` also retains
the independently verified owned-stop fact. All stages pass with cleanup verified.

2026-10-13 host-crash recovery: `oka_supervisor/tool/host_crash_dogfood.dart`
starts the existing service lifecycle worker, verifies the runner identity, sends
SIGKILL only to that runner, verifies the service survives with the recorded
identity, then starts a different runner. Its first converge is observation-only
and reports ready with no start/restart. A subsequent service failure restarts
once, stops with verified death and exhausts the recorded budget. The final
`output/host-crash-final-2026-10-13` receipt passes with no cleanup errors. Birth
facts are closed before publishing the birth receipt, so the killed runner's facts
remain retained. A prior 15-second birth-receipt timeout is preserved separately;
the current fixture uses a 60-second startup observation budget. This is not a
cold-start performance measurement or recovery proof for crashes during spawn,
detached browser descendants, native application windows or profile ownership.
The checked-in `test/host_crash_live_test.dart` independently invokes the tool
through the bounded process runner and passes on macOS. Birth and recovery runner
PIDs differ, and no process references the final evidence root after teardown.
Analysis of both tools and the new live test, docs drift and diff checks pass.

2026-10-13 visualization startup measurement: the canonical example records
monotonic timings per world, exposed through the existing viewer state. An app-owned
MeasuredScene delegates through the public renderViews seam, without changing
engine code or drawing policy. The supervised
`ecsly/tool/visualization_dogfood/output/startup-owner-timings-2026-10-13` trial
passes six effect checks with zero runtime exceptions and owned teardown. Its
early capture was inspected: nodes, links and labels are visible. Twelve Flutter
contracts and changed-source analysis pass. An initial API-mismatch compile failure
is retained in the build-trials history; the corrected build and runtime pass.

Within the world clock, static-resource initialization took 1,175.0 ms, initial
visual binding 5.6 ms, and the first renderer call 206.2 ms. First render return
occurred 1,457.2 ms after world creation; the first widget frame completed earlier,
at 87.8 ms while resources were still loading. Thus widget-frame readiness alone
would misstate useful scene readiness. Browser attachment was about 6.6 seconds
on its separate owner clock. Resident document update completed a Flutter frame
in 27.9 ms. This is one uncontrolled workload run, not a p95/cold-cache guarantee.
Render return does not establish GPU completion or compositor presentation; the
independent early capture supplies pixel evidence at a later observation. Initial
resource preparation and browser startup are measured optimization targets, while
controlled cache/shader variants remain necessary to attribute the causes.

2026-10-13 resident-engine cohort: the multi-view dogfood now waits for both
initial renderer returns before freezing state-isolation baselines, then creates
five fresh alpha worlds in the same engine. Every remount verifies checkpoint
restore and unchanged beta state. The final
`ecsly/tool/visualization_dogfood/output/resident-engine-consistent-clocks-2026-10-13`
trial passes 14 checks with no runtime exceptions, teardown and inspected final
pixels. `startup-cohort.json` preserves initial and warm timings and runtime IDs.
The five warm world-to-first-render-return times are 38.6, 38.0, 32.9, 34.1 and
35.6 ms. Public addView request to host observation ranges 71.1–82.6 ms, while
removal has its own separate timings. The preceding five-remount receipt included
removal in later host samples; preserve it but use the consistent-clock receipt
for those comparisons. Initial views overlap loading and are not independent
cold samples. This supports reusing a resident engine for this preview workload;
it does not qualify memory plateau, arbitrary scenes, p95, compositor presentation
or millisecond cold compilation. Feature-scoped engine preparation remains open.

2026-10-13 eager engine profile: ecsly `tool/scene_preparation_lab/prepare.dart`
now builds an isolated, explicitly sourced flutter_scene 0.23.0 copy and generated
consumer. Guarded source transformations add diagnostics while preserving eager
preparation; neither the package cache nor canonical app dependency is changed.
The source-anchor and replaced-override failures remain in separate owned outputs.
The corrected tool preserves all ECS overrides, and the consumer passes analysis,
release build and supervised six-interaction dogfood with zero runtime exceptions
and inspected early pixels. Relevant original/profiled source hashes are retained.

`engine-preparation-profile-2026-10-13` records 75 base shader entries compiled in
315.3 ms and 17 physical-material entries in 616.2 ms. Synchronous bundle
decode/compile totals 931.5 ms and may include GPU-driver waits; async phases overlap
and are not additive. Inclusive material preparation took 1,212.3 ms; mip-sampling
probe took 0.1 ms. First renderer return was 1,490.5 ms from world creation. This
measures a concrete candidate for unlit cold-start improvement: deferring unused
shader compilation, especially physical-material entries. No lazy policy has yet
been adopted or qualified, and lookup/reload/error semantics must be preserved.

2026-10-13 deferred shader prototype: the package-owned lab now includes an
opt-in lazy lookup transformation, enabled only by
`FLUTTER_SCENE_LAZY_WEB_SHADERS=true` in an explicitly generated consumer. Eager
behavior is the default. This does not change the installed engine or canonical
consumer dependency. The build driver now forwards declared additional Flutter
arguments and retains them in its immutable receipt.

The lazy startup trial passes all six interactions across three recipes with no
runtime exceptions. Six shader entries are compiled instead of the eager 92;
86 remain pending. PhysicalOpaque still compiles as a structural-loader validation
probe, so physical preparation has not been removed. First render return was
1,054.1 ms in that trial and 1,471.7 ms in the subsequent probe trial, compared
with 1,490.5 ms in the earlier eager profile. These uncontrolled runs do not prove
a stable timing win. The reduced compilation work is directly recorded.

`lazy-shader-reload-probe-2026-10-13` passes seven qualification actions, including
seven backend predicates: cached lookup, absent name returns null, byte/asset
reload preserving shader object identity, pending lookup after reload, a deliberately
invalid unused vertex shader failing at first use, and recovery after corrected
source. Same-source reload identity is not changed-shader pixel/pipeline-eviction
proof. The first-use error timing is intentional in the opt-in policy; eager
validation remains available. Final linked-view pixels were inspected and owned
teardown passed. The generated probe/consumer and both drivers analyze cleanly.

The probe consumer's release build took 418,732 ms under the current shared-machine
conditions. Its compiler and Flutter process were observed live and not restarted
on polling expiry. This is a separate compiler-path finding, not app startup; no
cause or representative build-time distribution is established. Broader material,
changed-shader reload, default-policy negative cases and upstream adoption remain
required before promoting this engine experiment.

2026-10-13 structural shader presence: the lab's new structural mode checks
pending entry names without compiling their shader. Native uses the existing
lookup fallback and remains live-unqualified. The positive O1 web trial passes
the six visual interactions plus eight shader predicates, including no compilation
from a presence query. At initial render five base shaders are compiled, with
zero physical-material shaders. The earlier lazy traces contain six compiles,
not seven; the retained count above has been corrected to match raw records.

A deliberately renamed PhysicalOpaque entry reproduced false readiness in the
original initializer: its error handler reset resources but fulfilled the future,
and the renderer was reached despite failed preparation. The structural copy
propagates the rejection; the preview records failure and displays the named error
without entering its renderer. `structural-presence-ax-nullable-2026-10-13` passes
that negative contract with no uncaught runtime exceptions and owned teardown.
The first corrected negative trial timed out because its observer expected a DOM
aria-label; captured pixels and AX already showed the error. The observer now uses
the shared CDP accessibility snapshot. Both error UI and positive linked-view pixels
were inspected. Canonical contracts pass 12 tests and changed-source analysis.

The successful structural build took 30,717 ms with explicit optimization-level=1;
it is not comparable to the earlier O4 build as a controlled speed ratio. An
Object?-typed initializer callback compile failure and observer-nullability compile
failure are preserved. Initialization rejection repair and structural preparation
remain in an isolated engine copy pending broader material/default/native and
upstream qualification. Full feature-scoped asset/texture loading remains open.

2026-10-13 material matrix: the lab can now generate a material fixture without
changing the canonical sink. A declared VIEWER_MATERIAL_MODE chooses unlit, basic
PBR or clearcoat spheres while keeping links unlit and retaining material objects
through color updates. Both lazy basic-PBR and clearcoat jobs pass six visual
interactions and the shader backend probe, with no runtime exceptions and inspected
shaded spheres. Their initial shader counts are seven and nine respectively.
Clearcoat creates four physical variants together; simple PBR uses the base
StandardCube and StandardNoShadowCube variants. These are measured preparation
boundaries, not a broad texture/transmission/native qualification.

The eager basic-PBR job passes all six interactions with 92 initial compiles.
The same eager build passes the missing-physical-entry negative contract and owned
teardown. `scene_preparation_lab/output/material-matrix-2026-10-13/summary.json`
links explicit immutable build receipts with runtime mode/policy, shader counts and
captures. The SDK-only summarize_matrix.dart reproduces this diagnostic summary;
all three builds have the same consumer source digest. Full served-bundle/SDK and
dependency provenance remains unqualified. Shared-machine build durations are
77.549 s (clearcoat lazy), 43.182 s (basic PBR lazy), and 256.958 s (basic PBR eager),
all at O1; no causal timing ratio is asserted. The eager compiler was observed live;
its OS sample provided no usable call graph. Source analysis and diff checks pass.

2026-10-13 renderer-independent lane (user priority): the canonical preview now
separates scene mapping and renderer instrumentation from the ECS model, startup
trace, shell and resident host. PreviewViewportBuilder is a consumer injection seam;
Flutter Canvas renders the same three recipes and dispatches point selection
through ChangePreview. The scaffold accepts --renderer canvas and removes scene
source files, both scene dependencies and the engine hook. Its generated lockfile
and package graph contain neither flutter_scene nor ecsly_flutter_scene. Three
scene-free tests pass, including point picking and multi-view checkpoint isolation;
scene-free analysis passes. Oka dogfood build provenance now permits absent optional
source directories, and renderer readiness accepts Canvas paint return. The web build and six supervised visual interactions pass; bounded runtime
evidence is recorded below. Broader native/performance acceptance remains pending.

The optional scene dependency is updated to 0.24.3 and the consumer disposes its
owned Scene. The pre-existing isolated upstream build completed in 783,318 ms; its
concurrent test timed out acquiring the hook lock. Canonical upgraded analysis
passes; its full 13-test suite also passes.
This is neither a successful upgrade runtime claim nor a reason to duplicate the
compiler. Further engine fork optimization is deprioritized in favor of Oka and
ecsly mechanisms usable with no scene engine.

Canvas follow-up: the first supervised browser run failed its DOM-label readiness
check even though captured pixels and the shared AX tree contained the rendered
Canvas view. The worker now reads the typed shared accessibility snapshot for
viewport readiness. Failure artifacts are retained in canvas-dogfood-2026-10-13.
Canvas zoom now changes projection; its picking regression passes at both normal
and zoomed scale. Three engine-free tests and source analysis pass. Two successful
O1 build receipts record 86,696 ms and 46,099 ms; changed source and warm caches
prevent treating those as a controlled speed ratio. The corrected supervised run
is canvas-dogfood-ax-2026-10-13, completed successfully with owned teardown.

Corrected Canvas trial: result.json has passed=true, six observed effects and no
runtime exceptions; supervisor-result.json has ok=true and the supervisor process
exited zero after worker teardown. Graph and linked-dark captures were inspected.
The app clock records first Canvas paint returned at 190,300 us after world creation
and first widget frame completed at 225,000 us. The resident document update records
46,300 us to Flutter frame. These are not GPU/compositor-present deadlines. The
host trial reports browser-ready at 17,234,024 us and app-ready at 18,736,903 us;
this cold path is not millisecond startup. Retained browser/viewer sessions and
renderer-independent data updates remain the owned optimization direction.

2026-10-13 retained-browser qualification: Chrome reuse previously changed an
existing owned process lease to borrowed. The regression reproduced that downgrade;
reuse now preserves its owner unchanged and gives the borrower no PID artifact.
BrowserPageSession exposes its discovery endpoint for composable reuse through
BrowserSessionSpec.debugPort. Page stop sends one close request, then observes
removal with a terminating deadline; timeout reports an unknown effect without
replaying. Focused browser tests pass, including delayed removal and unobserved
closure; source analysis and the docs drift gate pass.

The first live retained trial failed a cleanup observation. The next retained its
input/output target IDs: sample zero passed but subsequent observations included
transient iframe/worker IDs. The runner now protects page targets and retains the
full typed target catalog. Failure directories remain intact. The corrected
canvas-retained-browser-pages-2026-10-13 job passes nine effects, no runtime
exceptions, and owned teardown. Its three browser-reuse times are 7,205 / 3,890 /
4,020 us; fresh page attachment times are 46,071 / 150,083 / 38,877 us. New-page
renderer observation takes 1,011,172 / 1,084,287 / 893,817 us. Owner runtime,
revision, selection, recipe, theme, time and serialized process lease remain
unchanged after each borrower. After supervisor exit, an independent OS lookup
finds no owner PID 94277 and the project process registry has no such PID record.
These are three sequential observations, not p95 or controlled JS comparison.
Browser reuse is millisecond-scale; new Flutter page boot still is not.

The first Canvas multi-view run verified ten effects (including addressed document
application, scoped zoom, removal and checkpoint restoration) before an old
DOM-aria-label remount observer timed out. Its failure capture and result remain
in canvas-multi-resident-2026-10-13. Remount readiness now checks both addressed
worlds' renderer-return and widget-frame marks, supporting both Canvas and the
optional scene adapter; screenshots remain the independent pixel evidence. The
corrected multi-view trial is canvas-multi-frame-2026-10-13.

Corrected scene-free multi-view job passes all 14 effects, no runtime exceptions,
owned teardown and supervisor exit zero. Its final two-view capture was inspected.
Five warm alpha worlds in one resident engine return their first Canvas paint at
33,601–38,099 us after world creation and finish their first Flutter frame at
45,601–53,300 us. Host addView-to-render observation is 91,143–147,810 us. Beta
remains unchanged while alpha restores its checkpoint. These clocks describe
separate operations and do not establish compositor presentation, p95, memory
plateau or JS parity. The controlling layers are now empirically distinct: Oka
owns process/page lifetimes; Flutter embedding retains the engine; the ecsly
consumer owns addressed worlds and renderer-independent document application.

2026-10-13 native launch extraction and supervised use: the archived launch probe
is now Oka-owned tool/native_preview/native_launch_probe.swift with explicit
app/output/posture, source identity, launch-intent recording, unlocked logged-in
console guard, existing-instance refusal and returned-app teardown observation.
A fresh Canvas-only macOS consumer analyzes cleanly and builds in debug; its
bundle ID is isolated from prior consumers. The native-background-focus-2026-10-13
job passes under Oka supervisor on an unlocked desktop: foreground PID remains
1589, no app activation event, one normal window, launched PID 9396 terminated
and independently absent afterward. Launch took 3,516,016 us. The window is
reported offscreen, so visible composition and pixels remain unqualified.

The native-hidden-focus-2026-10-13 trial preserves focus and verifies returned
process teardown but fails the window-existence requirement (normalWindowCount=0).
Its result is retained as a failed qualification, not reclassified as success.
The Oka native dev runner still delegates to FlutterRunTarget; the diagnostic
AppKit path is not silently adopted. The next owning seam must connect nonactivating
launch, VM/compiler attachment and background frame/automation evidence while
preserving one serving-tool owner. Source compilation, runtime launch and frame/
pixel evidence remain separate.

2026-10-13 native runtime qualification: the ECS consumer now has opt-in debug
VM discovery and state/apply/view-list extensions over its existing resident
registry. Discovery starts at engine bootstrap, independently of viewer mounting.
The driver uses Flutter MCP harness VmClient, not expression evaluation. The first
worker failed to compile because published harness 7.0.0 did not exhaust the
editable automation action union; the already fixed local harness is explicitly
overridden without modifying its source. Subsequent discovery attempts targeted
a repository output directory; the signed debug app is sandboxed and cannot
freely write there. Discovery now uses the launched app's own container temp
directory, preserving its sandbox. Failed receipts remain intact.

Native-runtime-container-2026-10-13 passes initial Canvas paint, resident document
revision and Flutter frame continuity under unchanged foreground focus. Its
data-to-frame time is 51,212 us. Native-runtime-pixels-2026-10-13 additionally
captures the owned OS window: changed title and graph pixels were inspected;
foreground PID remains unchanged, no activation event, owned app teardown and
container-discovery removal are verified. Data-to-frame time is 46,278 us. The
image is small and perspective-transformed, so full-resolution preview/capture
geometry is not qualified. No GPU/compositor-present timestamp is inferred.

The native driver dependency initially caused native hooks even for web-only
supervisor startup. Capture is now isolated in its own tool package; the parent
browser supervisor graph no longer includes universal_driver_macos/code_assets/
hooks. The repeated native-runtime-capture-isolated-2026-10-13 job passes runtime,
capture, focus preservation, app teardown and owned descriptor cleanup;
data-to-frame time is 56,654 us. Native capture still builds its own hooks in its
subprocess. Native dev serving-tool/compiler attachment, widget/global focus and
background native input remain separate pending qualification.

2026-10-13 native compiler attachment: experimental FlutterAttachSession is
owned by oka_dart_kernel and attaches to an explicit authenticated VM URI without
launching another app. It retains startup lines, reads acknowledgements from the
current command, and coalesces detach. A process fixture verifies exact attach
arguments, fresh acknowledgement after bounded-log rollover, and repeated detach.
Source analysis and the fixture pass. The first real attempt used unsupported
--no-pub (attach has a different option surface); that failed trial is preserved.
The adapter now uses the installed SDK's supported arguments.

Native-attach-options-2026-10-13 passes under Oka supervisor: one copied path
package method changes from design-1 to design-native-attach-2, observed through
the registered native resource. Flutter reports 13/1008 libraries reloaded in
325 ms (compile 42 ms, reload 82 ms, reassemble 75 ms). World identity, document,
selection and camera persist. Compiler detach exits zero and the app remains
alive/readable; only the original AppKit owner then terminates it. Foreground
PID stays unchanged, no activation event, app teardown and discovery cleanup
pass. The copied source is restored after the trial. This proves one method-edit
case, not signatures/imports/restart/crash parity or a completed dev-runner option.
The native dev runner's default launch path is not yet changed.

2026-10-13 native dev integration: --native-vm-uri explicitly attaches the Oka
dev runner to an externally owned macOS app; it does not launch another app.
VmJitTarget's optional platformReload callback owns the complete compile/apply
operation, skipping DevFS and a second raw VM reload. Parser tests reject web,
malformed URI and mismatched-device use; attach forwards extra SDK arguments.
Two native/web reload-owner tests and four dev composition/attachment tests pass.
Changed VM target and attachment library analyze cleanly. The dev runner has no
analyzer errors; pre-existing style diagnostics remain outside this narrow change.

Native-dev-cli-2026-10-13 was refused before app launch: the desktop was locked.
The worker formerly masked this as a discovery timeout. It now detects a terminal
launcher before waiting for discovery and reports the named gap immediately.
Native-dev-refusal-2026-10-13 confirms interactive_desktop_unavailable with no
app launch. Source/adaptor integration is implemented and contract-tested, but
live integrated CLI reload/quit and restart remain unqualified until an unlocked
desktop trial. Do not replay the same refused launch or reinterpret lock-screen
evidence as focus correctness. Other active work remains possible.

2026-10-13 output identity: Oka WebBundleManifest captures canonical file/size/
SHA-256 rows and validates serialized identity. Four tests cover unchanged bytes
with timestamp differences, changed/added/removed files, manifest tampering,
traversal and symlink replacement. Changed source analysis passes. Build receipts
now use schema 2 and include outputBundle; prior receipts remain unmodified.
The rebuilt Canvas bundle has 41 files, 41,774,533 bytes and digest
31c59886607146620e9d01c3a57d57eba67d3e985da034b43be229dfd0e11bb8. This unchanged
warm build plus output capture took 2,701 ms; it is not a cold-build comparison.

Canvas-bundle-verified-2026-10-13 passes six real supervised interactions, no
runtime exceptions, matching build/output identity and teardown. The server
verifies each asset's exact bytes before delivery; unknown files are not served.
Bundle-preflight-refusal-2026-10-13 uses a copied bundle with an appended
JavaScript byte fixture and the original receipt: it refuses the mismatched
identity before host/browser startup (empty stages/checks). Original output is
unchanged. Negative shader fixtures verify original bytes before an explicitly
recorded response transformation, with separate source/served hashes. SDK and
dependency input closure, concurrent filesystem snapshot guarantees, content
addressed caching and browser hit/miss behavior remain pending.

2026-10-13 browser cache qualification: Oka cache policy is separate from bundle
verification, retaining no-store as the ordinary dogfood default. The revalidation
scenario uses per-file SHA-256 strong ETags and private/max-age=0/must-revalidate;
bytes are verified before conditional handling. Matching tags return 304, stale
tags return the current verified body. Two policy tests plus four bundle tests
pass and changed-source analysis is clean.

Browser-cache-revalidation-2026-10-13 passes seven effects, no runtime exceptions
and teardown. Nine actual server 304 responses include index/bootstrap/main JS,
CanvasKit JS/Wasm and fonts. The new viewer world completes a Flutter frame at
260,566 us from reload request-to-observation. Browser-cache-stale-tag-2026-10-13
passes the same effects and nine 304s, then sends a deliberately stale tag: 200
with the current main-JS ETag and 2,175,463 body bytes. Its 324,290-us field was
recorded after that additional fetch and is not a pure reload-frame duration;
future records capture the frame-observation time before the stale-tag control.
This is verified HTTP behavior, not p95 or a controlled JS/native speed ratio.
Input-cache validity and immutable content-addressed URL deployment remain open.

2026-10-13 renderer-independent scope reaffirmed: the user's requirement includes
no flutter_scene at all. Canvas remains the default scaffold; shared documents,
actions, checkpoints and preview lifecycle are independent of the optional scene
adapter. Scene-specific skill guidance is now explicitly conditional. The local
skill replay tool freezes and verifies 193 source files plus prompt-only inputs;
plugin-eval static analysis identifies instruction-budget failures (53/F), not a
behavioral result. Its generic benchmark proposal has not been executed. Novel
isolated baseline/candidate implementation trials remain open.

2026-10-13 fresh engine-free supervised dogfood:
`ecsly/tool/visualization_dogfood/output/canvas-cache-fresh-receipt-2026-10-13`
passes seven observed effects, no runtime errors, and supervisor job completion.
Resident document application completes a Flutter frame in 17,800 us; verified
revalidation into a new viewer observes a frame in 411,570 us, before the stale-tag
control. Nine server responses are verified 304s; a stale main-JS tag receives
200/current ETag and 2,175,463 bytes. The reloaded capture was inspected: graph
links, labels and controls are visible. These are individual observations, not
compositor timestamps or a controlled performance comparison.

The real run also motivated a tool-owned receipt preservation fix: supervise.dart
now refuses an existing evidence path before plan writes or worker dispatch.
Reusing the retained browser-cache-stale-tag trial exits 255; SHA-256 identities
of its plan/facts/worker result/supervisor result remain identical. Fresh dispatch
still succeeds. Source analysis passes. This is a sequential reuse guard, not
atomic cross-process evidence directory reservation.

2026-10-13 checkpoint lifecycle: the ecsly consuming host now injects serialized,
instance-bound checkpoint handles instead of independent SharedPreferences calls.
Three delayed-adapter regressions pass: old dispatched save settles before new
owner save, old queued save refuses, detached restore refuses, stale teardown
preserves replacement, and failed adapter calls do not poison subsequent work.
Canonical example has 16 passing tests and clean analysis. This closes the
process-local save/explicit-restore ownership gap; native durability, cross-tab
coordination and cached startup reads during an in-flight save remain distinct.

Fresh scaffold `canvas-checkpoint-consumer-2026-10-13` excludes both scene
packages, passes six consumer tests and builds through Oka. The real supervised
`canvas-checkpoint-multi-view-2026-10-13` job passes 14 observed effects with no
runtime errors: checkpoint restoration across five alpha remounts preserves the
beta world, camera, selection and document. Final two-view pixels were inspected
and the job completes after owned teardown. This browser trial confirms
integration; controlled delayed completions are covered by adapter regressions,
not injected into the browser's storage API.

2026-10-13 startup checkpoint follow-through: `launchPreview` now uses a serial
read barrier followed by preferences reload before initializing its world. The
one-shot bootstrap retains its future across rebuilds and renders a visible
storage failure without starting an unknown world or automatically retrying.
Delayed-save/latest-startup-read and bootstrap rebuild/failure regressions pass;
canonical source analysis is clean and all 19 tests pass. This supersedes the
cached startup-read limitation above for this host, while future writes,
cross-process concurrency and native storage durability remain separate.

The fresh `canvas-startup-consumer-2026-10-13` scaffold has neither scene
dependency, passes nine tests and builds through Oka. Its supervised
`canvas-startup-multi-view-2026-10-13` run passes 14 effects, zero runtime errors
and owned teardown; final two-view pixels were inspected. The integration trial
checks normal startup/remount behavior. The controlled delayed-write race remains
a separate adapter regression, not a native persistence or cross-process proof.

2026-10-13 immutable output serving: oka_web now offers WebBundleSnapshot over
the existing output manifest with an explicit payload budget and unmodifiable
typed-byte views. Manifest reads reject excess bytes during streaming. Captured
output remains stable after source mutation; direct/buffer write attempts refuse;
wrong digest, unknown paths and invalid asset URIs refuse. Snapshot, manifest and
cache-policy focused gates pass ten tests with clean changed-source analysis.

Real supervised `canvas-immutable-bundle-2026-10-13` passes seven effects and no
runtime errors while serving the 41,670,961-byte captured Canvas bundle. The HTTP
asset route includes digest 2977801adcf0a2f9e64a4ae57affa13cad6d6d4d9decaa1474a5d66f8c9f4098;
main JS receives 200, its verified hash, private/max-age=31536000/immutable; wrong
identity receives 404. Linked-dark pixels were inspected. The ordinary entry URL
remains no-store; full Flutter base/loader integration under digest URLs, input
cache closure and browser immutable-cache hit measurements remain open.

2026-10-13 full Canvas digest-loader qualification supersedes the entry-loader
and browser cache-hit gaps above for this tested profile. Example HTML now uses
a relative base; explicit public entrypointBaseUrl/assetBase/canvasKitBaseUrl
configuration is passed to both loader and engine. No digest is embedded into
the build, avoiding a content-identity cycle. The immutable scenario serves
only `/bundles/<digest>/...` and refuses root fallback.

`canvas-digest-loader-2026-10-13` passes eight effects and no runtime errors.
All nine initial resources load from digest dd853ee1c297827172f2d367354345a768806adb121a0eeb06d2bf8f4619bd69.
Reload records cache-served bootstrap/CanvasKit JS/main JS and disk-cache Wasm/
font responses, with one verified index revalidation. Fresh-engine frame is
observed at 327,688 us before the stale-tag control; this is one run, not a
controlled improvement or compositor measurement. Reloaded graph pixels were
inspected. `canvas-relative-base-multi-view-2026-10-13` passes 14 effects with no
errors, preserving the ordinary two-view host. Owned jobs/browser processes
finish and the post-run process scan finds no trial references. Input cache
closure, alternative browsers/renderers and broader deployment remain open.

2026-10-13 unlocked native CLI dogfood: fresh desktop preflight enabled the
pending trial. Real failures exposed three owners: nullable LaunchedApp.process
compatibility, conflicting quit/detach commands with an unawaited stdin flush,
and the dev runner's unclosed VM target wire keeping the process alive. Failed
unlocked/nullable-process/owned-detach trials remain retained. Input forwarding
now refuses absent process ownership; adapter stop owns quit/detach, its future
coalesces unknown teardown rather than replaying, attachment writes auto-drain,
and final cleanup closes runner-created targets only. Owned-launch adapters
retain their own quit command; borrowed attachment uses detach. Nine focused
dev/attach tests pass, including failed-stop once, back-to-back commands/detach
and caller-injected target preservation. Attachment-source analysis is clean;
the larger dev runner retains pre-existing style infos.

`native-dev-wire-cleanup-2026-10-13` passes supervisor/runtime checks: reload 1 OK,
code design-1 → design-native-dev-2 in the same runtime/world, document/selection/
camera continuity, Oka exit 0, and original app readable after quit. The AppKit
owner then stops app PID 64554 with verified teardown. Foreground PID remains
1589, activationEvents is empty, and container discovery is removed. Source
method is restored to design-1 and no trial/compiler process remains in the
post-run scan. Native restart/signature/import, full-resolution pixels and widget
input remain separate qualification gaps.

2026-10-13 native session cohort: the first `native-dev-cohort-2026-10-13`
trial passes all three reload effects and receives restart OK, then fails on
querying an extension before the new isolate registers it. The driver reuses
the harness's read-only callExtensionUntil with bounded attempts and requires
new runtime identity plus initial Canvas paint/widget-frame marks. The corrected
cohort passes; `native-dev-restart-reload-2026-10-13` then additionally proves
another source reload after restart through the same Oka compiler session.

Final observations: method/signature/import changes complete in 388,399/188,994/
216,039 us source-to-observation in one uncontrolled run, all in the original
world with revision-2 document and camera/selection preserved. Restart receipt
reports 657 ms; observer sees a different world, current code and revision-1
document/applyCount 0. Reload 4 changes current code in that new world without
replacing it. Oka exits 0, app remains readable after quit, foreground PID 1589
is unchanged, activationEvents is empty, AppKit owner verifies teardown of PID
77644 and discovery removal. Copied source is restored. Changed driver analysis
is clean. These are runtime/owner/frame observations; native compositor pixels,
input, arbitrary edits, long-running loops and toolchain/input closure remain
separate. Earlier failures and successful intermediate cohort are retained.

2026-10-13 full-resolution native capture investigation: the universal macOS
driver currently uses CGWindowListCreateImage. Oka's opt-in window_capture_probe
uses ScreenCaptureKit's desktop-independent window filter and screenshot API,
with existing grant preflight, one explicitly owned PID/window, unused outputs
and recorded point/pixel geometry. No shared driver code/default was changed.
The first `native-sck-capture-2026-10-13` probe crashed at WindowServer
initialization; the original app still passed focus/teardown. Nonactivating
AppKit context initialization corrected the probe.

`native-sck-appkit-capture-2026-10-13` passes supervisor/runtime/focus/teardown:
owned PID 80638/window 1504 is off-screen, content/frame is 800×632 points at
2× scale, PNG is 1600×1264. Independently inspected PNG shows crisp untransformed
title, graph, links and labels. Legacy capture in the same run is also full-size
(1692×1356 including surrounding shadow). Thus full-resolution capture is observed
for this profile, but earlier tiny/transformed captures are not reproduced and
their cause remains unresolved. It is not evidence of SCK superiority or native
input/compositor timing. Source identity and both images are retained; foreground
PID 1589 remains unchanged, activation events are empty, discovery is removed
and original owner teardown is verified.

2026-10-13 native semantic input: `native-ax-input-2026-10-13` attempts PID-bound
MacosDriver input with assistive-client accessibility initialization and a unique
button locator. It refuses before dispatch: accessibility request reports zero
windows and the app snapshot contains menus but no Parse button. Focus and app
teardown pass separately. No native input success is claimed; the window-exposure
gap belongs to native host/AX integration and requires a new diagnostic before
another identical trial. The helper retains request/snapshot/failure and parent
runtime error receipts. Build hooks reported a modified-file rerun before input;
this is retained and does not explain the missing AX window.

A separate shared-driver targeting defect was corrected in MacosDriver's narrow
resolver: duplicate locators previously selected the first match. Semantic click,
setValue and elementAction now throw a structured protocol error before mutation;
stale-handle refresh refuses an ambiguous replacement tree. Four new regressions
and existing gates bring the focused driver run to 46 passes with clean analysis.
This is deterministic targeting proof, not native button delivery or keyboard
focus proof. The opt-in dogfood input helper also requires selection to actually
change, avoiding a pre-existing selected-state false positive.

The shared macOS driver's separate fake-bridge conformance/behavior group passes
13 tests after the targeting fix. These do not exercise OS windows or establish
the failed native input trial as successful. Unrelated formatter churn in the
test file was removed after proving its formatted candidate equals the edited
file; other agents' native bridge changes remain untouched.

2026-10-13 read-only AppKit diagnosis: a fresh engine-free consumer is prepared
with a debug-only window state channel and distinct bundle ID, preserving prior
app sources. Its native build, clean source analysis, nine consumer tests and
`native-window-state-2026-10-13` supervisor/runtime trial pass. AppKit reports
one app window, visible/not-hidden/not-miniaturized, content 800×600, with five
window accessibility children. It is neither key nor main, and is outside the
active Space. AppKit's app accessibility-window list is empty. This distinguishes
window existence/paint from accessibility exposure; causal Space-policy proof
requires a controlled variant. An opt-in startup collection-policy fixture is
being prepared separately; no default native launch or shared bridge behavior
has changed.

Native placement negative baselines: `native-ax-spaces-input-2026-10-13` uses
the declared canJoinAllSpaces/canJoinAllApplications/fullScreenAuxiliary profile.
The recorded collection mask is 262401, but active-Space membership remains false,
app accessibility windows remain zero, and the visible Oscillators button is not
exposed to AX. Input refuses before dispatch; focus/teardown pass independently.
`native-ax-floating-input-2026-10-13` additionally uses floating level (3) and
explicit non-key ordering. It retains the same AX absence and also fails the
existing normal-window criterion (normal-layer count zero); that criterion was
not changed. App teardown and discovery removal are verified. Neither profile
is adopted as a fix, and no further equivalent placement trial should be run
without a new host-lifecycle diagnostic or instrumented Flutter input surface.
The current desktop check reports the Codex app frontmost with on-console/login
complete and absent lock flags; login-window preflight refusal remains intact.

2026-10-13 existing-driver native/web effect and focus qualification:
`native-toolkit-real-2026-10-13-a` and `native-toolkit-effects-2026-10-13-b`
use the local Flutter MCP toolkit plus harness ToolkitDriver (Universal Automation
contract). The latter records four independently observed button effects: graph
→ simulation → linked, dark theme, and back to graph, preserving runtime/document
identity. A newer real toolkit snapshot forced between resolution and dispatch
produces `stale_snapshot`; the harness surfaces it once and the independent state
is unchanged. The native launch observer records foreground PID 1589 before and
after, no activation events, no owned-app activation, verified owned teardown and
container discovery cleanup. The first simulation capture and expanded dark graph
capture are retained. OS AX window exposure and keyboard/widget focus remain
separate open checks.

`web-effects-real-2026-10-13-b` records six observed CDP effects (selection, resident
document, recipe changes, simulation step, theme), no runtime errors, and owned
browser/server teardown. Its Universal Automation foreground observer records
510 samples, no PID changes, maximum sample gap 30.630 ms. This is a real headless
Chrome Flutter web run; a transition shorter than a sample gap is not excluded.
The initial `-a` run failed before browser startup because the consumer launcher
resolved its package configuration against the caller's working directory.
The supervisor now resolves its own package configuration relative to its script;
failed receipts are retained, and the multi-view rerun exercises the corrected
launch from the native child package directory. The native consumer also required
a local interface-source override; the preparation command now takes an explicit
automation root rather than leaving conflicting hosted/path sources.

Shared behavior remains in existing packages: ToolkitDriver now requires a unique
locator, binds click/type/set-value to the observed revision, and surfaces toolkit
refusal without replay. Its complete harness suite passes 71 tests. Preview code
uses the existing verifyEffect and ToolkitDriver, with app-specific observation
assertions only; no new automation protocol or toolkit verbs were introduced.

The corrected launcher rerun `web-effects-multiview-2026-10-13-c` passes fourteen
view-targeting/isolation/remount checks with no runtime errors. Its foreground
receipt records baseline PID 15595, 302 samples, no changes, and a 30.037 ms
maximum gap. The foreground baseline changed between the two independent web
runs; neither run changed its own observed baseline. Expanded native dark graph
and single-view web linked-dark captures were visually inspected.

2026-10-13 supervisor acquisition failure regression: blocking the lease
directory with a regular file reproduced an owned `sleep` process remaining
alive after `LeasedProcessProvider.start` threw. The fixture stopped its own
process after the failed assertion. Persistence now has an acquisition cleanup
path: verified spawn identity permits process-tree stop; missing identity
permits no live-root signal and yields an explicit unverified cleanup outcome.
Both paths use real processes and hostile filesystem state, rather than a mock
write exception. Existing four real supervisor service/crash/recovery checks
pass. This closes in-run persistence failure cleanup, not the SIGKILL window
between OS spawn and durable lease persistence, nor detached-descendant recovery.

After the identity guard, all fifteen `oka_core` process-provider tests and all
four real supervisor lifecycle/recovery tests pass. Changed-source analysis,
diff whitespace checks and Oka documentation drift pass. No broader production
readiness or spawn/persist atomicity is inferred from these bounded checks.

2026-10-13 process-tree teardown evidence: deterministic failures reproduced
post-signal probe loss reporting `stopped=true` and reparented descendants
escaping the force ladder. The shared tree library now retains pre-signal
identities/PIDs, verifies every signal, and returns unknown on a lost probe.
A recycled-descendant fixture receives no signal. A real leased process is
stopped while post-signal discovery is deliberately lost; its provider reports
unknown and retains its lease. This proves conservative reporting under a
controlled missing-probe condition, not a native OS discovery outage.

The caller also had an independent early-return bug: a real process root exited
while its delayed post-signal tree probe was pending, but `runBoundedProcess`
returned before verification. The regression failed against that implementation.
The deadline stop future is now awaited and its result exposes optional
`teardownVerified` (null for ordinary exits), plus unknown/error details.
Pre-detached children and the spawn/persist SIGKILL window remain separate gaps.

Final changed-tree validation passes thirty-four focused core process/tree
checks and four real supervisor lifecycle/recovery checks. A real-root
post-signal probe exception also returns unverified teardown with its named
error rather than an unhandled timer failure. Changed-source analysis,
whitespace checks and Oka docs drift pass. Observed descendants are retained
within a stop invocation; this does not persist their identities across a
runner crash or discover a child detached before the initial tree snapshot.

2026-10-14 skill evidence extraction: stale native-background guidance in the
ecsly skill workflow was corrected to the verified toolkit route. The previous
287-line verification record is byte-preserved in the example-owned
`validation/skill_history`, with original path/link-base and SHA256 manifest.
The active reference is a current capability/evidence/boundary table linked to
owning runner commands. Static analysis around relocation reduces the deferred
estimate 11,450 → 7,379 tokens, score unchanged at 53/F; a subsequent evaluation
log append has its own final static report. Trigger/entrypoint instructions did
not change. Both original 193-file and new 199-file frozen replay inputs verify;
the new digest is f25b020aa963af17c2e050f7c0cfdb310726c72f4adc5bd8ac3f6653ba2b065a.
Active entrypoint/workflow/verification links, archive bytes, skill format and
freeze/verify analysis pass. No behavior benchmark or aesthetic promotion is
claimed; novel paired implementation evaluation and static budget work remain.

2026-10-14 original automation recommendation 6 (readiness rather than
sacrificial input) now has an owning-package fix. Real Chrome reproduced
`FlutterWebCdp.warmUpClick` pressing a control covering its fixed (680,500)
coordinate. The compatibility method now delegates to `waitForSemantics`: a
bounded app-enabled semantics and two-rAF wait, without pointer input or
`Page.bringToFront`. `typeFocused` and `popRoute` also avoid page activation.
The real Chrome fixture verifies no warm-up click, focused editable value,
route-pop effect and missing-semantics timeout. It uses a dynamic port and an
owned isolated profile, with finally-stop. Default harness suite passes 71
checks plus one explicitly skipped opt-in runtime test; that runtime test was
run separately and passed. Canonical toolkit skill and generated server skill
assets were updated from the owning source, not edited in plugin caches.

A real supervised Flutter Canvas run `web-readiness-real-2026-10-14` verifies
readiness leaves the complete resident state unchanged, followed by six
independently observed effects, no runtime errors, inspected linked-dark pixels
and owned teardown. Universal Automation foreground observation records 274
samples, baseline PID 445, no changes, maximum gap 28.181 ms. This is headless
Chrome; shorter transitions and headed-browser OS activation remain outside
this measurement. rAF readiness does not establish compositor presentation.
Original recommendations on richer/scoped native observations, declared widget
focus and the legacy clickText replay/last-match behavior remain distinct work.

2026-10-14 original automation recommendations 2/5, legacy click wrapper:
a real delayed toggle reproduced three clicks for one `FlutterWebCdp.clickText`
request before the effect appeared. The helper now delegates exact role/name
and ordered ancestor scope targeting to the existing CdpSemanticTargeting, and
one-dispatch effect observation to Universal Automation verifyEffect. No
input uses the wrapper's old substring/last-match geometry. `expect:` now uses
a uniquely resolved exact semantic name in the same scope; callers can supply
an independent application-state `effect:` predicate instead. Positive
`attempts * delay` sets one deadline, not a mutation retry count. The harness
minimum CDP constraint is aligned with the owning 0.3 targeting API; no hosted
publication is claimed. Canonical skill/generated assets now remove stale
bring-to-front and headless-incompatibility guidance.

Real Chrome regression verifies delayed effect with one click, duplicate-label
refusal with zero clicks, explicit-scope selection, missing effect with one
click and timeout, and satisfied baseline with no click. It also retains the
prior readiness/text/route checks. The 71-test harness gate passes with one
explicit opt-in skip; the real runtime test passes separately, and changed
source analysis/whitespace checks pass. The supervised Flutter Canvas run
`web-one-click-real-2026-10-14` drives Oscillators through this helper and an
independent state predicate, with six observed effects, no errors, inspected
linked-dark pixels and owned teardown. Its OS foreground sampler sees no
changes across 305 samples, maximum gap 46.333 ms; headless/sample limitations
remain. Generic legacy rect/text readers, declared native widget focus and
route-pop retry semantics are separate remaining work.

2026-10-14 declared widget focus implementation: ToolkitDriver now implements
the existing TargetedAutomationDriver interface. Exact/scoped resolution uses
Universal Automation resolveSemanticTarget, captures that snapshot revision, and
dispatches existing tap_widget/focus_widget extensions once. Focus requires the
toolkit's verified widget-focus result. Snapshots preserve focused=true/false/absent
without synthesizing false. Contract regressions cover exact targeting, revision
propagation, ambiguous refusal, viewer scope selection and stale/unverified focus
without replay. This adds no sealed action variant, toolkit verb or OS activation.

The prepared native consumer test scrolls to Frequency, requires a fresh focused
slider snapshot, and checks ArrowRight's application frequency delta independently.
The tested macOS SDK's normalized step is 0.1 over range 0.5..2.0, hence expected
0.15 Hz. `native-focus-key-2026-10-14-a` was refused before app launch: launch
receipt reports screenLocked=true and interactive_desktop_unavailable. No PID or
app activation was acquired. This is an environmental refusal, not successful
focus/key delivery; live proof remains open until a desktop-ready observation.
The previous button-only native proof remains its own unchanged evidence epoch.

The complete harness gate after this targeted API addition passes seventy-five
tests plus one explicit opt-in runtime skip. Changed driver/test/consumer analysis
and whitespace checks pass. Canonical toolkit skill/generated assets document the
interface and keep the blocked live-focus trial distinct from contract evidence.

2026-10-14 route-helper delayed-effect correction: real Chrome reproduced
`FlutterWebCdp.popRoute` popping two history entries while a route marker
remained visible for 1.5 seconds. The owning helper now dispatches one
history.back and observes with existing Universal Automation verifyEffect.
The default marker is an exact uniquely resolved accessible name in an optional
ancestor scope; `isPresent:` supports independent application route state.
Already-absent baseline skips history mutation, ambiguous markers refuse before
input, and unobserved effects time out without another pop.

The real regression verifies underlying hash preservation after delayed closure,
one-pop timeout, absent-baseline no-op, ambiguous-marker no-op, and retained
prior readiness/click/key-text checks. Browser ownership is required before
interaction; exit and temporary-profile removal are independently asserted.
The 75-test default harness gate passes with one explicit runtime skip; expanded
real Chrome run passes separately. The same real test runs as a declared Oka
supervisor CLI job in harness-owned `output/route-supervisor-2026-10-14-b`, with
ready fact and terminal CLI exit zero. The initial plan remains failed evidence: a
VM-only --packages option was incorrectly supplied to dart test, before browser
startup; the corrected plan uses native test argument resolution. No unrelated
registry or browser profile is used. Analysis/diff checks pass; skill/generated
assets and package guide/changelog are updated. These are controlled browser
history/DOM fixtures, not general Flutter Navigator or native focus acceptance.

2026-10-14 focused-editable effect observation correction: the wrapper's
lastEditableValue claimed focused/last-field behavior, but the shared selector
read selected the first DOM match. Real Chrome with an unfocused first decoy and
focused second field returned `untouched` after the actual field received
`background text`. The focused reader now follows document.activeElement through
open shadow roots, preserves empty string as a value, and has no DOM-order
fallback. typeFocused refuses missing/read-only/non-text editable targets before
Input.insertText. The old read name remains a deprecated compatibility alias.

Expanded real regression passes multi-field effect read, empty value, read-only
and missing-target refusal, shadow textarea input, prior route/click/readiness
checks, borrowed-session refusal and owned browser/profile teardown. The same
run is an Oka supervisor CLI job under harness-owned
`output/editable-supervisor-2026-10-14`, lastRun=succeeded. Named driver/test/manifest
and package-config hashes are unchanged before/after; they are direct-input
evidence, not full compiler closure. Seventy-five default harness tests pass plus
one explicit opt-in skip; real runtime passes separately. Analysis and whitespace
checks pass. Canonical skill/generated assets and package guidance are updated.
This is controlled headless browser evidence; native widget-key proof and
inaccessible/foreign-frame focus contexts remain unqualified.

2026-10-14 explicit scene-free Wasm lane: Oka's existing WebBuildTarget(extraArgs)
delegates --wasm to the matching Flutter SDK. The build emits JS fallback as well
as main.dart.mjs/main.dart.wasm, so runtime proof requires the app's compiled
dart.tool.dart2wasm flag, verified served program and browser crossOriginIsolated.
The new small WebIsolationPolicy exposes opt-in require-corp/credentialless
COOP+COEP headers without a server/compiler implementation or default change.
Source: https://docs.flutter.dev/platform-integration/web/wasm .

Retained failures: `wasm-runtime-2026-10-14-a` timed out before app readiness;
the consumer server lacked JavaScript MIME handling for .mjs. After correcting
that, `-b` and `wasm-bridge-diagnostic-2026-10-14-c` ran actual Wasm and selected
Parse, but resident application failed with a boxed Dart Future error. The strict
transaction accepts int, while JS-number dartify representation differs in Wasm.
The owning browser adapter now normalizes only safe finite integral numbers; the
resident int contract stays strict. Two tests cover valid representations and
fractional/nonfinite/unsafe/nonnumeric refusal without caller mutation.

Fresh canonical scaffold `canvas-wasm-fixed-consumer-2026-10-14` builds with
--wasm (24.890 s for that run), passes eleven tests and analysis. Real supervised
`wasm-runtime-fixed-2026-10-14-d` passes eight checks; `wasm-runtime-refusal-2026-10-14-e`
passes nine including direct bridge fractional-revision refusal with unchanged
state, six real effects, inspected linked-dark pixels and owned teardown. Runtime
flag is true, main.dart.wasm/skwasm resources are served verified, isolation and
SharedArrayBuffer are available. A subsequent JS consumer has the same recorded
consumer source digest and passes seven supervised checks with runtime flag false.
Its build is 14.183 s; these are separate one-run builds, not a controlled compiler
speed comparison. Named source digest excludes dependency/SDK closure. Renderer
thread count, compositor timing and statistically controlled performance remain
open. Canonical example passes twenty-one tests and analysis.


2026-10-14 bounded JS/Wasm comparative cohort: the reusable consumer
`bin/compare_lanes.dart` invokes the existing Oka supervisor, with three alternating
pairs, fixed 1120×1000 browser window, require-corp isolation and a fresh owned
browser/profile per trial. Both recorded consumer source digests match, as do SDK
and browser version. All six trials report nine checks including runtime mode,
refusal with unchanged state, readiness without input and six independent action
effects. Supervisor records report succeeded without corrupt records; Runtime
exception lists are empty. Final linked-dark captures in both modes were inspected.
Evidence is `ecsly/tool/visualization_dogfood/output/js-wasm-cohort-2026-10-14`.

Median worker-to-capture: JS 1764.642 ms, Wasm 1592.267 ms. Median resident
update-to-Flutter-frame: JS 16.670 ms, Wasm 17.951 ms. Actual served uncompressed
payloads: JS 7,952,709 bytes, Wasm 5,841,643 bytes. Worker timing excludes the
supervisor/worker compiler startup; OS/filesystem caches and host load are
uncontrolled. JS/CanvasKit versus Wasm/SkWasm changes both program and rendering
profile. CDP heap is not total process/GPU memory. Three runs per lane do not
establish p95, general superiority, compositor timing or compiler input closure.

Fresh web foreground observation `web-focus-2026-10-14-g.json` passes with
foreground PID445 unchanged across 259 samples, maximum gap29.426 ms, during
launch, six real effects and teardown. A separate read-only macOS session read
reports screenLocked=true and loginwindow foreground; this is explicitly a
locked-desktop observation, not an unlocked user-focus qualification. The pending
native slider/key trial was not relaunched through the locked preflight. Earlier
unlocked native toolkit button/stale-target evidence remains valid for its own
measured scope. Existing real Chrome harness regression passed again, including
readiness without input, focused editable/decoy/shadow-root checks, exact scoped
selection, delayed effects without redelivery and owned profile/process cleanup.


2026-10-14 command deadline refusal hardening (ADR-0046): a real owned sleep
with unavailable subtree discovery returned failed teardown but kept
runBoundedProcess waiting for root exit. The new regression failed its 2-second
observation bound before the fix; the fixture independently reaped its child.
The bounded-run API now returns completed failed-teardown evidence including
root PID, captured identity, rootExitObserved=false, exitCode -1 sentinel and
unresolved root survivor. A successful stop still awaits root exit, and root
exit still awaits tree verification. SystemProcessRunner exposes the existing
platform seams for composition and keeps TimeoutException with explicit
unverified cleanup/recovery diagnostics instead of claiming no survivors.

Replacing the sleep with a real writing child exposed a second failure:
canceling output subscriptions on refusal made that child exit. The final code
keeps draining bounded output until unresolved root exit; the fixture verifies
that the writer remains alive before its separate identity-checked cleanup.
The recorded capture stays bounded. Standalone runners can remain alive while
that drainage/recovery is unresolved; this is not a detached hard-deadline
runtime or crash-safe lease recovery claim.

Five focused refusal/verification checks pass. The final process-tree and
leased-provider suites pass as an Oka CLI supervisor job under
`.oka_cache/validation/deadline-refusal-2026-10-14-c`; status lastRun=succeeded,
no corrupt records. Its plan, facts, direct-source hashes and verified record
are retained; named source hashes remained unchanged during the job. Earlier
-a/-b jobs preserve the narrower preceding revisions. Three real supervisor
service/budget/SIGKILL-recovery tests pass separately. Whole oka_core analysis,
docs drift and whitespace checks pass. A mistakenly requested pair of absent
supervisor test filenames failed loading before any fixture started; the
correct existing files were discovered and used for the passing run.

Remaining owner gap: oka_core platform discovery/identity futures which never
complete still have no independent completion bound. Spawn-before-persist and
previously detached/cross-run descendant recovery also remain unqualified.


2026-10-14 novel implementation skill pair and reusable quantitative example:
the skill-eval-improve agent-with/without-skill workflow used two fresh agents
with the same task, SDK/package roots and inherited model/settings. Prompt,
rubric, skill guidance and oracle identities were frozen before evaluation;
original source bytes were archived and verified before later maintenance.
Both arms pass analysis, five model tests and Oka release compilation. Baseline
fails existing headless semantics readiness before input; skill-assisted passes
15 browser checks including 11 independent pointer effects and analytical
reference values, with no Runtime exceptions. Baseline's rendered desktop plots
were inspected despite inaccessible semantics. This is one task, not general
skill superiority or canonical promotion. The original absolute-selection-index
criterion has a recorded interpretation limit and was never reached by baseline.

The skill-assisted app is extracted to ecsly/examples/damped_oscillator, using
repository-relative dependencies and no scene package or copied token package.
Model/main/bridge bytes match the evaluated source; only package/test naming,
dependency inventory and single-view local-resource loader were adapted. The
example owns the parameterized task, original paired records, byte-preserving
source snapshots and hash manifests in validation/skill-eval-2026-10-14.
Archived Dart/YAML sources use .txt suffixes so they do not become live code or
nested packages. Frozen historical inputs remain separate from current guidance.

First post-extraction run failed an immediate Sample1 AX assertion; its later
failure AX and pixels showed Sample1. The next qualification epoch retains the
same label predicate and uses existing harness observation-only retry, never a
second click. Original paired records/oracle are unchanged. Fresh supervised
-damped-extracted-2026-10-14-b passes16 checks, status=succeeded/no corrupt
records, including narrow scrolling with unchanged domain state. Desktop and
320px scrolling captures show readable phase/time axes and selection controls.
Whole example analysis and five model tests pass after archival extraction;
dogfood scripts analyze clean and canonical skill structural validation passes.
Runtime exception lists are empty; the incidental favicon.ico404 remains a
separate recorded network log. Browser/node/API success does not prove native
controls, physical focus, compositor presentation or broad plotting quality.


2026-10-14 readonly process observation budgets: two real owned-child
regressions stalled initial identity and tree-discovery futures indefinitely;
both failed the original 3-second observation bound. The final process seam
shares a configurable observationBudget (default2s) across direct readonly
waits in each tree stop. Startup identity capture uses min(read budget,
remaining run deadline); elapsed capture time is subtracted before scheduling
teardown. Missing startup identity now refuses signals instead of recapturing
identity at deadline. Exhaustion returns unverified tracked processes.

The late-read regressions await actual completion of the released read, then
independently observe the original child still alive and zero signal-adapter
calls. Their fixture separately reaps the owned child. Aggregate-read exhaustion
and invalid-budget-before-spawn checks pass. The budget has its own timeout type,
so a mutating adapter TimeoutException retains its owner detail rather than being
misclassified as read-budget expiry. Five focused checks pass. This is a real
owned-process experiment with injected stalled reads, not a host OS outage trial.

Full oka_core tests pass as the final declared Oka supervisor job in
`.oka_cache/validation/observation-budget-2026-10-14-c`, lastRun=succeeded;
its named source hashes remain unchanged across the run. Earlier full-suite
revision records209 passes/2 skips; final adds the mutation-timeout distinction
regression. Three real supervisor service/restart-budget/SIGKILL-recovery checks
pass with the final seam. Whole-core analysis, docs drift and whitespace checks
pass. Plans, facts, hashes and verified job record remain under the owned output.

This closes unbounded direct observation awaits. Timeout does not cancel an
injected future or its resources. Mutating kill adapters remain awaited;
platform spawn, adapter-owned probe processes and total teardown completion
still have no new hard-runtime guarantee. Crash-safe spawn/persistence recovery
and previously detached/cross-run descendants remain separate open work.

2026-10-14 unlocked native toolkit focus/key qualification: run
`ecsly/tool/visualization_dogfood/output/native-focus-key-2026-10-14-b`
failed before focus because ToolkitDriver sent an untargeted scroll over Canvas.
The existing scroll extension accepts ref and snapshotId; the harness now
resolves a fresh unique scrollable node and refuses absent/ambiguous matches.
Run c then exposed semantics_owner_unavailable after a populated snapshot.
SemanticSnapshotService.semanticsOwner now uses the active RenderView owner,
matching snapshot traversal, instead of the legacy binding pipeline. Foreign
gesture-service edits were preserved. The owned native consumer was rebuilt.

Run d scrolled successfully but returned focus_refused; this remains an
intermittent focus-delivery/observation failure, with no keyboard proof from d.
Run e passed independent focused semantics, ArrowRight frequency 1.00 -> 1.15Hz,
four intended button effects, stale-snapshot refusal with unchanged state,
nonactivation and owned teardown. Runs f/g/h also passed runtime behavior.
Final h uses Universal Automation foreground-PID sampling: PID1589 unchanged,
327 samples, maximum gap24698us; NSWorkspace activationEvents=[], owned app
activated=false, desktop unlocked, teardownVerified=true. Sampling cannot rule
out transitions shorter than its gaps; toolkit key delivery is instrumented
Flutter delivery, not OS keyboard synthesis. No compositor visibility claim.

The monitored Dart launcher emitted "File modified during build. Build must be
rerun", including h while the observing agent made no source edits. Runtime
effects are retained; these monitored launches are not clean build-readiness
receipts. The preceding explicit Flutter macOS build completed cleanly.
Focused harness tests31 pass; full harness77 pass/one opt-in skip; the opt-in
real Chrome test independently passes. Toolkit surface/scroll-axis/interaction
tests51 pass, affected-source analysis and whitespace checks pass. GitNexus
impact queries fail DB42/runtime40, so graph risk remains UNKNOWN.

Open: diagnose d's focus refusal without action replay, the launcher build
warning, and ToolkitDriver SetValueAction's semanticWrite=false inconsistency.
Backend enterText can focus/tap and SDK userUpdateTextEditingValue can request
focus; simply advertising semanticWrite=true would overstate the capability.

2026-10-14 toolkit focus frame observation: source inspection found the previous
three "frames" were16ms delays whenever framesEnabled=true. A controlled
withheld-frame widget regression fails the old loop (focus result completed
before a frame) and passes the new loop (result remains pending, then succeeds
after real completion). The existing focus dispatch now awaits endOfFrame,
retains the suspended-frame pump, and bounds each observation to1s. Missing
completion returns focus_frame_unobserved/verified=false after one dispatch.
A second real withheld-frame test observes that deadline and one focus handler
call; genuine refusal/focus-stealing tests continue passing. Toolkit focused
surface/scroll/interaction cohort52 passes; changed-source analysis is clean.
Old/new regression logs remain under the dogfood output's
`focus-frame-regression-2026-10-14` directory.

Rebuilt owned consumer and Oka native job `native-focus-key-2026-10-14-frame-a`
pass independent focused semantics, ArrowRight1.00→1.15Hz, the button flow and
stale refusal. Foreground PID1589 remains unchanged across716 samples, maximum
gap143713us; activation trace empty and owned teardown verified. This fixes a
demonstrated premature-observation failure class, not a statistical proof that
every cause of earlier d's focus refusal is eliminated. The Dart-launch build
warning remains; no compositor or OS keyboard-synthesis claim is added.

2026-10-14 native hook warning repair: hooks_runner traces the warning to a
dependency modified after its input cutoff. universal_driver_macos had reported
the relative path bridge/src/driver_bridge.swift; the consumer runner could not
find it and regards missing files as freshly modified (stored cutoff sentinel1).
The hook now resolves source via input.packageRoot and output via
input.outputDirectory. Its code asset no longer contains a double-slash path.
No SDK or hooks_runner source was patched and foreign driver edits were preserved.

The real consumer's two post-fix runs exit0 without the warning and reuse the
same dylib bytes and mtime. An initial cache fixture's argument guard refused
before native loading; retained separately, then fixed to permit zero-argument
commands. Package-owned opt-in native_hook_test copies sources into an owned
temporary consumer, builds/loads the native bridge, verifies warm reuse, changes
only copied Swift input and verifies rebuilding. It passes, as do46 driver tests
and changed-source analysis. This verifies both cache reuse and invalidation,
not just suppressed diagnostics or a static path assertion.

Oka job native-focus-key-2026-10-14-hookfix passes the actual native visualization
focus/key/button/stale-refusal flow and owned teardown, with clean launcher
output. Foreground PID1589 unchanged376 samples/maxgap26168us; activation trace
empty, desktop unlocked. The earlier build warning is fixed for this package
and consumer lane; other native hooks and compiler-input closure remain distinct.
Reusable tests, copied byte-hashed receipts and source snapshots live in
universal_driver_macos/validation/native-hook-2026-10-14. No release or adoption
claim is added.

2026-10-14 semantic text backend: existing enter_text now has an opt-in
semanticOnly mode. It uses ref-owned EditableText state, refuses missing/read-only
editables before fallback, and bypasses the SDK's focus request for an exactly
unchanged editing value. Default false retains existing behavior. Five real
Flutter widget scenarios invoke the actual tool registration and independently
observe controllers, focus nodes, formatter/onChanged and tap counts. Legacy
same-value entry takes focus; semanticOnly preserves the decoy, including changed
formatted text and clearing. This is Flutter framework/entry proof, not native
window/browser proof. Product callbacks can still redirect focus themselves.

The shared schema, typed EnterTextCommand, fmt_* handler, CLI catalog and VM
executor carry the option. Focus policy values must be booleans; targeted guards
refuse non-booleans before a permissive schema coercion could be followed by raw
typed-parser refusal or a silent false default. Existing defaults remain intact.
Final named-source verification and logs live in mcp_flutter/docs/evidence/
semantic-text-write-2026-10-14/final. The parent evidence epoch predates the final
typed guards and is retained. Pending: rebuilt native/web option qualification
and honest shared-driver capability/SetValueAction integration. No semanticWrite
support, hosted distribution or OS focus claim is added by these backend tests.

2026-10-14 rebuilt native semantic-write fixture: the package-owned Flutter widget
in mcp_toolkit/tool/semantic_write_fixture.dart is copied only into an explicitly
owned Canvas consumer by the existing dogfood tool. It exposes read-only Dart
controller/focus/callback observations; every mutation goes through the existing
ToolkitDriver InvokeAction/agent registry. The running enter_text catalog must
advertise the semanticOnly boolean before any write. Runs native-semantic-write-
2026-10-14-a and b each verify unchanged123/no callback, formatted"4 days"→4/
one callback, then clear/two callbacks, with target unfocused and decoy still
focused/unchanged. The slider/key/button/stale-refusal flow also passes.

Both full supervisor jobs fail later at OS capture: two layer0 windows are owned
by the process, so the existing one-normal-window oracle refuses. Its selection
rule is unchanged; the diagnostic now preserves window metadata. In b one window
is unnamed500x500 and another onscreen titled97x135. Their role/cause is not yet
established; do not call the second an IME window or discard it by size/title.
Run a's foreground PID1589 stayed unchanged across550 samples/maxgap27757us,
with empty activation trace and verified owned teardown; passed=false records the
child's capture failure, not a focus change. No completed native dogfood or pixel
quality claim follows from these semantic effects. The typed SetValueAction
capability mismatch and web option qualification remain open.

2026-10-14 explicit native host identity and visual-error regression: an optional
read-only MainFlutterWindow channel reports the actual host windowNumber,
controller attachment, frame and AppKit state. Before text focus only that host
exists; afterward the app also reports an invisible TUINSWindow/NSViewController
500x500. The Flutter host remains800x600 content, non-key/non-main/non-minimized.
CoreGraphics independently correlates both IDs and the owner PID. No window is
discarded by size/title. Explicit capture addresses the reported host ID through
the existing MacosDriver.windowScreenshot, after exact PID/layer0 membership;
unbound capture still refuses multiple normal windows. A live host ID supplied
under the observer's different PID refuses and creates no image.

Run native-window-identity-2026-10-14-c returned a successful worker result but
manual inspection found a red Flutter error screen. It is disqualified as a
visual dogfood, not erased. The fixture's global one-instance guard incorrectly
treated same-physical-view keyed viewport replacement as another view. It now
checks physical view ID and clears its active pointer only when disposing that
instance. A real keyed-replacement regression passes. Native qualification now
reads and retains the existing toolkit error buffer and refuses nonempty/missing
errors. The old compiled binary is a positive failure control: the new gate
rejects its captured StateError before readiness. Source/runtime epochs remain
separate. Copied fixture syntax is kept compatible with the consumer's declared
Dart3.10 language, even though the installed SDK is Dart3.13.4.

Rebuilt run native-window-identity-2026-10-14-d succeeds through the Oka supervisor:
three semantic writes preserve decoy focus, keyboard frequency delta and recipe/
theme/stale-refusal flows pass, error buffer=[], selected host PNG inspected with
readable graph/labels, wrong-owner capture refuses, and owned teardown verifies.
Foreground PID22839 unchanged444 samples/maxgap29841us, activationEvents=[].
Text fixture values reset on viewport replacement; the write receipts precede
recipe switching, while the final image shows the newly mounted fixture123.
No compositor timing, OS keyboard-event synthesis or typed SetValue claim.

Native fixture/host source and hashed positive/negative receipts are extracted
to mcp_flutter/docs/evidence/native-window-identity-2026-10-14. The offscreen
CG discovery remains a consumer diagnostic; generalizing that existing-driver
capability belongs in Universal Automation rather than another automation stack.

2026-10-14 offscreen discovery extraction: Universal Automation's existing
MacosDriver.windows now accepts onScreenOnly=false. An additive native symbol
and optional AllWindowListingBridge preserve the old ABI/on-screen default and
custom-bridge contract. The same normal-layer/PID query includes other Spaces
and hidden helpers; MacosWindow.toJson and nullable onScreen preserve missing
visibility as unknown. The consumer no longer creates a Swift discovery file,
temporary directory or discovery subprocess. It uses the existing driver for
both listing and exact-ID capture, keeping host/PID correlation and refusal.

Package driver suite48 passes; affected-source analysis is clean. Opt-in isolated
native-hook regression calls both old and new real APIs while checking build,
warm reuse and changed-source rebuilding. Native job native-ua-window-2026-10-14
succeeds via Oka with wrong-owner refusal, semantic/key/button/stale effects,
error buffer=[], inspected graph PNG and verified teardown. Foreground PID22839
unchanged339 samples/maxgap30998us, activationEvents=[]. Missing onScreen values
in this other-Space window list stay absent; no false visibility is inferred.
No speed comparison, compositor timing, hosted release or adoption claim.
