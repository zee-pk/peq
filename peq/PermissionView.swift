import SwiftUI

struct PermissionView: View {
    @ObservedObject var permissionManager: PermissionManager

    var body: some View {
        VStack(spacing: 0) {
            // Icon / header
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.15))
                        .frame(width: 80, height: 80)

                    MaterialIcon(name: MaterialIconName.permissions, size: 36)
                        .foregroundStyle(.orange)
                }

                Text("Permission Required")
                    .font(.title2.weight(.bold))

                Text("**peq** needs **Screen Recording** permission to tap into system audio and apply the equalizer.\n\nNo screen content is ever captured — only audio.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(32)
            .frame(maxWidth: .infinity)

            Divider()

            // What's needed
            VStack(alignment: .leading, spacing: 12) {
                permissionRow(
                    icon: MaterialIconName.music,
                    color: .blue,
                    title: "System Audio Recording",
                    description: "Required to read and process system-wide audio output"
                )
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)

            Divider()

            // Action buttons
            VStack(spacing: 10) {
                Button {
                    Task {
                        await permissionManager.requestPermissions()
                    }
                } label: {
                    MaterialIconLabel(title: "Request Permission", icon: MaterialIconName.raiseHand)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    permissionManager.openSystemSettings()
                } label: {
                    MaterialIconLabel(title: "Open System Settings", icon: MaterialIconName.settings)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Text("After granting access, you may need to restart peq.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private func permissionRow(
        icon: String,
        color: Color,
        title: String,
        description: String
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.opacity(0.15))
                    .frame(width: 36, height: 36)
                MaterialIcon(name: icon, size: 16)
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            MaterialIcon(name: MaterialIconName.error)
                .foregroundStyle(.orange)
        }
    }
}

#Preview {
    PermissionView(permissionManager: PermissionManager.shared)
        .frame(width: 440)
}
