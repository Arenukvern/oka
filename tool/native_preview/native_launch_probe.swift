import AppKit
import CoreGraphics
import Foundation

// Extracted from the archived ecsly launch probe. Launch/stop only the returned app.
// This is a bounded qualification executable, not a resident process manager.
guard (3...5).contains(CommandLine.arguments.count) else {
  fputs("usage: native_launch_probe APP OUTPUT [background|hidden] [CONFIG_JSON]\n", stderr)
  exit(64)
}
let appURL = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard !FileManager.default.fileExists(atPath: output.path) else {
  fputs("Refusing to overwrite launch evidence\n", stderr); exit(64)
}
let posture = CommandLine.arguments.count >= 4 ? CommandLine.arguments[3] : "background"
guard ["background", "hidden"].contains(posture) else { exit(64) }
let workspace = NSWorkspace.shared
let clock = DispatchTime.now().uptimeNanoseconds
func elapsedUs() -> Int { Int((DispatchTime.now().uptimeNanoseconds-clock)/1000) }
func write(_ record: [String: Any]) throws {
  try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
  let bytes = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
  try bytes.write(to: output)
  print(String(data: bytes, encoding: .utf8)!)
}
let baseline = workspace.frontmostApplication
let session = CGSessionCopyCurrentDictionary() as? [String: Any]
let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
let console = session?["kCGSSessionOnConsoleKey"] as? Bool ?? false
let loginDone = session?["kCGSessionLoginDoneKey"] as? Bool ?? false
let desktopReady = session != nil && !locked && console && loginDone &&
  baseline != nil && baseline?.bundleIdentifier != "com.apple.loginwindow"
var record: [String: Any] = ["schema": 1, "posture": posture, "screenLocked": locked,
  "onConsole": console, "loginDone": loginDone, "desktopReady": desktopReady,
  "baselinePid": Int(baseline?.processIdentifier ?? 0), "appPath": appURL.path]
guard desktopReady else {
  record["passed"] = false; record["gap"] = "interactive_desktop_unavailable"
  try write(record); exit(2)
}
guard let bundleID = Bundle(url: appURL)?.bundleIdentifier else {
  record["passed"] = false; record["gap"] = "invalid_app_bundle"
  try write(record); exit(2)
}
guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
  record["passed"] = false; record["gap"] = "existing_application_refused"
  try write(record); exit(2)
}
var events = [[String: Int]]()
let observer = workspace.notificationCenter.addObserver(
  forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
) { note in
  if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
    events.append(["pid": Int(app.processIdentifier), "atUs": elapsedUs()])
  }
}
let configuration: [String: Any]
if CommandLine.arguments.count == 5 {
  configuration = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[4]))) as? [String: Any] ?? [:]
} else { configuration = [:] }
let completionFile = configuration["completionFile"] as? String
let observationBudget = configuration["observationBudgetSeconds"] as? Double ?? 30
if observationBudget <= 0 || observationBudget > 120 { exit(64) }
let config = NSWorkspace.OpenConfiguration()
if let environment = configuration["environment"] as? [String: String] {
  config.environment = ProcessInfo.processInfo.environment.merging(environment) { _, supplied in supplied }
}
config.activates = false
config.hides = posture == "hidden"
config.createsNewApplicationInstance = true
config.addsToRecentItems = false
var owned: NSRunningApplication?
var completed = false
var failure: String?
var timedOut = false
record["phase"] = "launch_requested"
try write(record)
workspace.openApplication(at: appURL, configuration: config) { app, error in
  owned = app; failure = error?.localizedDescription; completed = true
  // A late callback cannot leave a newly launched process behind.
  if timedOut { app?.terminate() }
}
let launchDeadline = Date(timeIntervalSinceNow: 10)
while !completed && Date() < launchDeadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
timedOut = !completed
if timedOut {
  // Retain the observer for a bounded late completion; uncertainty is a failure.
  let lateDeadline = Date(timeIntervalSinceNow: 20)
  while !completed && Date() < lateDeadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
}
record["phase"] = completed ? "launch_completed" : "launch_outcome_unknown"
record["launchTimedOut"] = timedOut
record["launchUs"] = elapsedUs()
let settle = Date(timeIntervalSinceNow: 1.5)
while Date() < settle { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
let ownerPid = owned?.processIdentifier ?? 0
if let completion = completionFile {
  let observationDeadline = Date(timeIntervalSinceNow: observationBudget)
  while !FileManager.default.fileExists(atPath: completion) && Date() < observationDeadline {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
  }
  record["observationCompleted"] = FileManager.default.fileExists(atPath: completion)
}
let after = workspace.frontmostApplication?.processIdentifier ?? 0
let activated = events.contains { $0["pid"] == Int(ownerPid) }
let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let normalWindows = windows.filter {
  ($0[kCGWindowOwnerPID as String] as? Int) == Int(ownerPid) &&
  ($0[kCGWindowLayer as String] as? Int) == 0
}
record["pid"] = Int(ownerPid); record["afterPid"] = Int(after)
record["completed"] = completed; record["error"] = failure ?? ""
record["activationEvents"] = events; record["ownedAppActivated"] = activated
record["normalWindowCount"] = normalWindows.count
record["normalWindowIds"] = normalWindows.compactMap { $0[kCGWindowNumber as String] as? Int }
record["onScreenWindowCount"] = normalWindows.filter { $0[kCGWindowIsOnscreen as String] as? Bool == true }.count
record["presentationVerified"] = false
var stopped = owned == nil && completed
if let app = owned {
  app.terminate()
  let stopDeadline = Date(timeIntervalSinceNow: 5)
  while !app.isTerminated && Date() < stopDeadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
  if !app.isTerminated {
    record["forceTerminateRequested"] = app.forceTerminate()
    let forceDeadline = Date(timeIntervalSinceNow: 2)
    while !app.isTerminated && Date() < forceDeadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
  }
  stopped = app.isTerminated
}
workspace.notificationCenter.removeObserver(observer)
record["teardownVerified"] = stopped
let passed = completed && !timedOut && failure == nil && ownerPid > 0 && !activated &&
  after == baseline?.processIdentifier && stopped && !normalWindows.isEmpty
record["passed"] = passed && (completionFile == nil || record["observationCompleted"] as? Bool == true)
try write(record)
exit(record["passed"] as? Bool == true ? 0 : 1)
