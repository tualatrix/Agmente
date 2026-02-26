import SwiftUI
#if os(macOS)
import AppKit
#endif

struct SettingsView: View {
    @Binding var devModeEnabled: Bool
    @Binding var codexSessionLoggingEnabled: Bool
    @Binding var useHighPerformanceChatRenderer: Bool

    @ViewBuilder
    private var settingsFormContainer: some View {
#if os(macOS)
        ScrollView {
            Form {
                settingsSections
            }
            .formStyle(.grouped)
            .frame(maxWidth: 620)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
#else
        Form {
            settingsSections
        }
#endif
    }

    @ViewBuilder
    private var settingsSections: some View {
        Section("Feedback") {
            Button {
                openFeedbackEmail()
            } label: {
                HStack {
                    Text("Send Feedback")
                    Spacer()
                    Image(systemName: "envelope")
                        .foregroundStyle(.secondary)
                }
            }
        }

        Section("Developer") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Developer mode", isOn: $devModeEnabled)
                Text("Shows extra diagnostics like connection status on server cards.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Codex session logging", isOn: $codexSessionLoggingEnabled)
                Text("Writes per-session JSONL logs for Codex app-server. Stored in Application Support.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
#if os(iOS)
        Section("Chat Rendering") {
            Toggle("Use high-performance chat list", isOn: $useHighPerformanceChatRenderer)
            Text("Uses ListViewKit + MarkdownView renderer. Turn off to use the legacy SwiftUI transcript for A/B testing.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
#endif
    }

    var body: some View {
        NavigationStack {
            settingsFormContainer
            .navigationTitle("Settings")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
        }
#if os(macOS)
        .frame(minWidth: 640, idealWidth: 680, minHeight: 420, idealHeight: 500)
#endif
    }
    
    private func openFeedbackEmail() {
        let email = "info@halliharp.com"
        let subject = "Agmente Feedback"
        let urlString = "mailto:\(email)?subject=\(subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        
        if let url = URL(string: urlString) {
#if os(iOS)
            UIApplication.shared.open(url)
#else
            NSWorkspace.shared.open(url)
#endif
        }
    }
}

#Preview {
    SettingsView(
        devModeEnabled: .constant(true),
        codexSessionLoggingEnabled: .constant(false),
        useHighPerformanceChatRenderer: .constant(true)
    )
}
