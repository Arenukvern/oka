import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

/// Diagnostic only: captures the one normal window owned by the given PID.
/// No activation, app launch, focus restoration, or permission request.
@main
struct WindowCaptureProbe {
    @MainActor static func main() async {
        do {
            guard CommandLine.arguments.count == 4,
                  let owner = Int32(CommandLine.arguments[1]), owner > 0 else {
                throw NSError(domain: "capture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "PID PNG RECEIPT required"])
            }
            let png = URL(fileURLWithPath: CommandLine.arguments[2])
            let receipt = URL(fileURLWithPath: CommandLine.arguments[3])
            guard !FileManager.default.fileExists(atPath: png.path),
                  !FileManager.default.fileExists(atPath: receipt.path) else {
                throw NSError(domain: "capture", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Existing capture output refused"])
            }
            // Establish AppKit/WindowServer context without an activating app.
            NSApplication.shared.setActivationPolicy(.prohibited)
            guard CGPreflightScreenCaptureAccess() else {
                throw NSError(domain: "capture", code: 10,
                              userInfo: [NSLocalizedDescriptionKey: "Existing Screen Recording grant unavailable"])
            }
            if #available(macOS 14.0, *) {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    true, onScreenWindowsOnly: false)
                let windows = content.windows.filter {
                    $0.owningApplication?.processID == owner && $0.windowLayer == 0
                }
                guard windows.count == 1, let window = windows.first else {
                    throw NSError(domain: "capture", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "Expected one owned normal window; found \(windows.count)"])
                }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let rect = filter.contentRect
                let scale = Double(filter.pointPixelScale)
                let width = Int(ceil(rect.width * scale))
                let height = Int(ceil(rect.height * scale))
                guard width > 0, height > 0, width <= 8192, height <= 8192,
                      width * height <= 32_000_000 else {
                    throw NSError(domain: "capture", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "Capture dimensions exceed diagnostic budget"])
                }
                let config = SCStreamConfiguration()
                config.width = width
                config.height = height
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config)
                guard let destination = CGImageDestinationCreateWithURL(
                    png as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    throw NSError(domain: "capture", code: 5)
                }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else {
                    throw NSError(domain: "capture", code: 6)
                }
                let row: [String: Any] = [
                    "pid": owner, "windowId": window.windowID,
                    "windowFrameWidth": window.frame.width,
                    "windowFrameHeight": window.frame.height,
                    "contentWidthPoints": rect.width, "contentHeightPoints": rect.height,
                    "pointPixelScale": scale,
                    "imageWidth": image.width, "imageHeight": image.height,
                    "isOnScreen": window.isOnScreen,
                    "backend": "ScreenCaptureKit desktop-independent window",
                    "limit": "Owned window image; no compositor presentation timestamp or native input proof"
                ]
                try JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted, .sortedKeys])
                    .write(to: receipt, options: .atomic)
            } else {
                throw NSError(domain: "capture", code: 7,
                              userInfo: [NSLocalizedDescriptionKey: "macOS 14+ required"])
            }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
