import AppKit
import Combine
import Foundation
import ScreenCaptureKit

/// Checks whether the user has granted Screen Recording permission,
/// which is required for `CATapDescription` / `AudioHardwareCreateProcessTap`.
@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var hasScreenRecordingPermission: Bool = false

    static let shared = PermissionManager()

    private init() {}

    /// Performs an async check without showing the system prompt.
    func checkPermissions() async {
        hasScreenRecordingPermission = await Self.checkScreenRecording()
    }

    /// Requests permission if not already granted.
    /// The system will show its own permission dialog the first time.
    func requestPermissions() async {
        // Accessing SCShareableContent forces the OS to prompt the user.
        if !hasScreenRecordingPermission {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            hasScreenRecordingPermission = await Self.checkScreenRecording()
        }
    }

    /// Opens System Settings to the Screen Recording pane.
    func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Private

    private static func checkScreenRecording() async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return !content.displays.isEmpty
        } catch {
            return false
        }
    }
}
