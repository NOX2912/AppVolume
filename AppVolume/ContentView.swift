import SwiftUI

struct ContentView: View {
    @Environment(AudioController.self) private var controller
    @State private var loginItem = LoginItem()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("App Volumes").font(.headline)
                Spacer()
                Label(controller.outputDeviceName, systemImage: "hifispeaker")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if controller.permission == .denied {
                PermissionBanner { controller.recheckPermission() }
                Divider()
            }

            if controller.apps.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "speaker.zzz").font(.title2).foregroundStyle(.secondary)
                    Text("No app is playing audio.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(controller.apps) { app in
                            AppRow(app: app)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let error = controller.lastError {
                Divider()
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Toggle("Launch at Login", isOn: Binding(
                        get: { loginItem.isEnabled },
                        set: { loginItem.set($0) }
                    ))
                    .toggleStyle(.checkbox)
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                        .keyboardShortcut("q")
                }
                if let error = loginItem.error {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 340)
    }
}

private struct AppRow: View {
    @Environment(AudioController.self) private var controller
    let app: AudioApp

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).lineLimit(1)
                HStack(spacing: 8) {
                    Button {
                        controller.toggleMute(app.id)
                    } label: {
                        Image(systemName: app.muted ? "speaker.slash.fill" : speakerSymbol)
                            .frame(width: 18)
                            .foregroundStyle(app.muted ? .red : .primary)
                    }
                    .buttonStyle(.borderless)
                    .help(app.muted ? Text("Unmute") : Text("Mute"))

                    Slider(value: Binding(
                        get: { app.volume },
                        set: { controller.setVolume($0, for: app.id) }
                    ), in: 0...1)
                    .controlSize(.small)
                    .disabled(app.muted)

                    Text(verbatim: "\(Int((app.volume * 100).rounded())) %")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    private var speakerSymbol: String {
        switch app.volume {
        case 0: "speaker.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }
}

private struct PermissionBanner: View {
    let recheck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("System audio access required", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.subheadline.bold())
            Text("AppVolume needs the “Screen & System Audio Recording → System Audio Recording Only” permission to change app volumes.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open System Settings") { NSWorkspace.shared.open(AudioPermission.settingsURL) }
                Button("Check Again", action: recheck)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
