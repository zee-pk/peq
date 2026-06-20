import AppKit
import SwiftUI

enum MaterialIconName {
    static let addCircle = "add_circle"
    static let arrowDown = "keyboard_arrow_down"
    static let arrowUp = "keyboard_arrow_up"
    static let error = "error"
    static let health = "ecg_heart"
    static let menu = "format_list_bulleted"
    static let output = "volume_up"
    static let permissions = "privacy_tip"
    static let music = "queue_music"
    static let raiseHand = "pan_tool"
    static let save = "save"
    static let settings = "settings"
    static let status = "tune"
    static let trash = "delete"
    static let tune = "tune"
    static let warning = "warning"
}

struct MaterialIcon: View {
    let name: String
    var size: CGFloat = 18

    var body: some View {
        Image(name)
            .resizable()
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct MaterialIconLabel: View {
    let title: String
    let icon: String
    var iconSize: CGFloat = 18

    var body: some View {
        HStack(spacing: 6) {
            MaterialIcon(name: icon, size: iconSize)
            Text(title)
        }
    }
}

enum MaterialIconImage {
    static func make(_ name: String, size: CGFloat, accessibilityDescription: String) -> NSImage? {
        guard let sourceImage = NSImage(named: name) else { return nil }
        guard let image = sourceImage.copy() as? NSImage else { return nil }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}
