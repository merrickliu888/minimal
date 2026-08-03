import AppKit
import Foundation
import ScreenCaptureKit

/// Captures the active display via ScreenCaptureKit, downscales it, and
/// writes a JPEG the agent can ingest as an image block.
enum ScreenshotCapturer {

    /// Max long-edge pixels sent to the model (matches Anthropic's vision
    /// guidance; larger images are downscaled server-side anyway).
    private static let maxDimension: CGFloat = 1568

    /// Capture the display containing `screen` (defaults to the screen with
    /// the mouse pointer, i.e. where the user is working). Returns the path
    /// of a temporary JPEG, or nil on failure/denied permission.
    static func captureActiveDisplay(screen: NSScreen?) async -> String? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let targetScreen = screen ?? screenUnderMouse()
            let displayID = targetScreen?.displayID
            guard let display = content.displays.first(where: { $0.displayID == displayID })
                ?? content.displays.first
            else { return nil }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            config.showsCursor = false
            config.captureResolution = .best

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return writeJPEG(image)
        } catch {
            NSLog("ScreenshotCapturer: capture failed: \(error)")
            return nil
        }
    }

    static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private static func writeJPEG(_ image: CGImage) -> String? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = min(1, maxDimension / max(width, height))
        let targetSize = NSSize(width: width * scale, height: height * scale)

        let nsImage = NSImage(cgImage: image, size: targetSize)
        let scaled = NSImage(size: targetSize)
        scaled.lockFocus()
        nsImage.draw(in: NSRect(origin: .zero, size: targetSize))
        scaled.unlockFocus()

        guard let tiff = scaled.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-screenshot-\(UUID().uuidString).jpg")
        do {
            try jpeg.write(to: url)
            return url.path
        } catch {
            NSLog("ScreenshotCapturer: write failed: \(error)")
            return nil
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
