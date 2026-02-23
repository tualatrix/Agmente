import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct SettingsView: View {
    @Binding var devModeEnabled: Bool
    @Binding var codexSessionLoggingEnabled: Bool
    @Binding var useHighPerformanceChatRenderer: Bool

    var body: some View {
        NavigationStack {
            Form {
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
                    Toggle("Developer mode", isOn: $devModeEnabled)
                    Text("Shows extra diagnostics like connection status on server cards.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Toggle("Codex session logging", isOn: $codexSessionLoggingEnabled)
                    Text("Writes per-session JSONL logs for Codex app-server. Stored in Application Support.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Chat Rendering") {
#if canImport(UIKit)
                    Toggle("Use high-performance chat list", isOn: $useHighPerformanceChatRenderer)
                    Text("Uses ListViewKit + MarkdownView renderer. Turn off to use the legacy SwiftUI transcript for A/B testing.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
#else
                    Text("High-performance chat list is currently available on iOS only.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
#endif
                }
            }
            .navigationTitle("Settings")
#if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
        }
    }
    
    private func openFeedbackEmail() {
        let email = "info@halliharp.com"
        let subject = "Agmente Feedback"
        let urlString = "mailto:\(email)?subject=\(subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        
        if let url = URL(string: urlString) {
#if canImport(UIKit)
            UIApplication.shared.open(url)
#elseif canImport(AppKit)
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
