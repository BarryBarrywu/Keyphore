import SwiftUI
import KeyphoreCore

struct AgentIntegrationsView: View {
    @ObservedObject var state: KeyphoreAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppCopy.value(.integrationsDetail))
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(state.agentSourceSnapshots, id: \.source) { snapshot in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.source.displayName).font(.subheadline.weight(.medium))
                            Text(AppCopy.value(statusKey(snapshot)))
                                .font(.caption)
                                .foregroundStyle(statusColor(snapshot))
                        }
                        Spacer()
                        actions(snapshot)
                    }

                    if snapshot.source == .codex {
                        Text(AppCopy.value(.integrationsCodexManaged))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if snapshot.source == .pi {
                        Text(AppCopy.value(.integrationsPiSignals))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if state.agentIntegrationFailedSources.contains(snapshot.source) {
                        Text(AppCopy.value(.integrationsError))
                            .font(.caption).foregroundStyle(.red)
                    }
                    if state.agentIntegrationReview?.source == snapshot.source,
                       let review = state.agentIntegrationReview {
                        reviewDetails(review)
                    }
                }
                .padding(.vertical, 5)
                if snapshot.source != state.agentSourceSnapshots.last?.source { Divider() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert(
            AppCopy.value(.integrationsRemoveTitle),
            isPresented: Binding(
                get: { state.agentRemovalSource != nil },
                set: { if !$0 { state.cancelAgentIntegrationRemoval() } }
            ),
            presenting: state.agentRemovalSource
        ) { _ in
            Button(AppCopy.value(.integrationsRemove), role: .destructive) {
                state.confirmAgentIntegrationRemoval()
            }
            Button(AppCopy.value(.integrationsCancel), role: .cancel) {
                state.cancelAgentIntegrationRemoval()
            }
        } message: { source in
            Text("\(source.displayName): \(AppCopy.value(.integrationsRemoveMessage))")
        }
    }

    @ViewBuilder
    private func actions(_ snapshot: AgentSourceSnapshot) -> some View {
        if state.agentIntegrationWorkingSource == snapshot.source {
            ProgressView().controlSize(.small)
                .help(AppCopy.value(.integrationsWorking))
        } else if snapshot.source != .codex {
            if snapshot.available && (!snapshot.approved || snapshot.needsReview) {
                Button(AppCopy.value(.integrationsReview)) {
                    state.reviewAgentIntegration(snapshot.source)
                }
                .controlSize(.small)
            }
            if snapshot.installed {
                Button(AppCopy.value(.integrationsRemove), role: .destructive) {
                    state.requestAgentIntegrationRemoval(snapshot.source)
                }
                .controlSize(.small)
            }
        }
    }

    private func reviewDetails(_ review: AgentIntegrationReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppCopy.value(.integrationsReviewTitle)).font(.caption.weight(.semibold))
            reviewList(title: .integrationsEvents, values: review.events)
            reviewList(title: .integrationsFiles, values: review.files.map(\.path))
            Text(AppCopy.value(.integrationsPrivacy))
                .font(.caption2).foregroundStyle(.secondary)
            Button(AppCopy.value(.integrationsEnable)) {
                state.installReviewedAgentIntegration()
            }
            .disabled(state.agentIntegrationWorkingSource != nil)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func reviewList(title: AppCopyKey, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(AppCopy.value(title)).font(.caption.weight(.medium))
            ForEach(values, id: \.self) { value in
                Text(value)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusKey(_ snapshot: AgentSourceSnapshot) -> AppCopyKey {
        if snapshot.approved { return .integrationsEnabled }
        if !snapshot.available { return .integrationsUnavailable }
        if snapshot.needsReview { return .integrationsNeedsReview }
        return snapshot.installed ? .integrationsNeedsReview : .integrationsAvailable
    }

    private func statusColor(_ snapshot: AgentSourceSnapshot) -> Color {
        snapshot.approved ? .green : .secondary
    }
}
