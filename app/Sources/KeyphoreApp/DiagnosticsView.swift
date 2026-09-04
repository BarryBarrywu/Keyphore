import AppKit
import SwiftUI
import KeyphoreCore
import UniformTypeIdentifiers

struct DiagnosticsView: View {
    @ObservedObject var state: KeyphoreAppState
    @State private var saveFailed = false
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .font(.system(size: 12))
            .onAppear(perform: state.refreshDiagnosticReport)
    }

    private var content: some View {
        Group {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(AppCopy.value(.settingsDiagnosticDetails))
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                ForEach(state.reviewedDiagnosticReport.fields) { field in
                    LabeledContent(field.label) {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(field.value)
                            if let action = field.action {
                                Text(action)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .multilineTextAlignment(.trailing)
                    }
                }
                if let preview = state.reviewedDiagnosticReport.preview {
                    ForEach(Array(preview.enumerated()), id: \.offset) { _, line in Text(line).font(.caption) }
                }
            }
            Text(state.reviewedDiagnosticReport.privacyNotice)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !state.diagnosticReportIsReady || state.diagnosticReportIsRefreshing {
                ProgressView(AppCopy.value(.diagnosticCollecting))
            }
            Button(AppCopy.value(.diagnosticSave), action: save)
                .disabled(!state.diagnosticReportIsReady || state.diagnosticReportIsRefreshing)
            if saveFailed {
                Text(AppCopy.value(.diagnosticSaveFailed))
                    .foregroundStyle(.red)
            }
        }
    }

    private func save() {
        let reviewedReport = state.reviewedDiagnosticReport
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "Keyphore-Diagnostics.zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DiagnosticReportExporter().export(reviewedReport, to: url)
            saveFailed = false
        } catch {
            saveFailed = true
        }
    }
}

extension MenuState {
    var copyKey: AppCopyKey {
        switch self {
        case .configurationRequired: .configurationRequired
        case .configured: .configured
        case .ready: .ready
        }
    }
}

extension KeyboardHealth {
    var copyKey: AppCopyKey {
        switch self {
        case .unverified: .keyboardUnverified
        case .disconnected: .keyboardDisconnected
        case .unavailable: .keyboardUnavailable
        case .ambiguous: .keyboardAmbiguous
        case .connected(let protocolHealthy, _):
            protocolHealthy ? .protocolHealthy : .keyboardConnected
        }
    }
}
