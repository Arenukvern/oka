# Native preview launch qualification

This bounded AppKit probe was extracted from the archived ecsly visualization
experiment. It accepts an already built app, an unused receipt path and a posture:
`background` opens a visible app without requesting activation; `hidden` also
requests hiding. It refuses an unavailable/locked desktop or a running instance
with the same bundle ID. Launch intent is written before dispatch. It observes
activation notifications and the frontmost PID, discovers only the returned app's
normal windows, and verifies termination of that returned app. It does not restore
focus or terminate an unrelated application.

```sh
swiftc tool/native_preview/native_launch_probe.swift -o /owned/output/native-launch-probe
/owned/output/native-launch-probe /owned/app.app /owned/output/launch.json background
```

The package-owned ecsly `tool/visualization_dogfood` supervisor accepts
`native-background` and `native-hidden` scenarios for a separately scaffolded,
prebuilt macOS consumer. The wrapper compiles this probe from the explicitly
configured editable Oka dependency and retains source identity, logs and the
receipt. It requires exactly one app in the consumer's Debug products directory.
A receipt path is single-use, so recovery cannot silently repeat an unknown launch.

This is diagnostic tooling, not a new production AppTarget or an automatic
replacement for the native `flutter run` dev session. A successful trial proves
only its launch/focus/window/teardown observations. It does not prove a rendered
Flutter frame, background toolkit behavior, native capture, compile-channel
retention, or crash-time recovery of an NSWorkspace-dispatched launch. An unknown
launch outcome remains a failure with its intent receipt retained.

The optional CONFIG_JSON argument carries explicit environment entries and a
completion-file observation window (positive budget, at most 120 seconds). The
probe retains ownership while the driver observes runtime effects, then performs
the same focus and teardown checks. It does not create or attach a compiler.

Native-runtime qualification publishes engine discovery inside the app's sandbox
container; writing into an arbitrary repository output directory is refused by
the stock macOS debug sandbox. The consumer adapter is opt-in through
ECSLY_PREVIEW_DIAGNOSTICS and exposes registered state/action extensions over the
already running debug VM. The driver enumerates mounted viewer addresses rather
than choosing a process-global current viewer. The app sandbox stays enabled.

## Window capture prototype

`window_capture_probe.swift` is an opt-in macOS 14+ diagnostic using Apple's
[window-specific ScreenCaptureKit filter](https://developer.apple.com/documentation/screencapturekit/sccontentfilter)
and [screenshot API](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager).
It initializes a nonactivating AppKit context, preflights existing Screen
Recording access, and requires exactly one normal window for the supplied PID.
It does not launch an app, request permission, or restore focus.

```sh
swiftc -parse-as-library tool/native_preview/window_capture_probe.swift -o /owned/output/window-capture-probe
/owned/output/window-capture-probe OWNED_PID /owned/output/frame.png /owned/output/frame.json
```

Output paths must be unused. The receipt records window geometry in points,
pixel scale and actual PNG dimensions. The diagnostic caps dimensions at 8192
and total pixels at 32 million. It remains separate from universal automation's
capture backend. The ecsly `native-capture-sck` supervisor scenario retains both
legacy and ScreenCaptureKit captures plus probe source identity/logs.

The first CLI-only prototype failed WindowServer initialization; its receipt is
retained. Nonactivating AppKit initialization corrected it. The subsequent real
off-screen Canvas window produced a crisp 1600×1264 image at 2× scale with
unchanged foreground and owned teardown. Legacy capture was also full-resolution
in that run. This qualifies this observed capture, not an explanation of earlier
transformed images, superiority over legacy, arbitrary windows or presentation
timing. The visible viewport may contain only part of a scrollable document.
