import SwiftUI
import KeyphoreCore

struct DiagnosticsView: View {
    let snapshot: LifecycleSnapshot
    let menuState: MenuState

    var body: some View {
        Form {
            LabeledContent(AppCopy.value(.productName)) {
                Text(AppCopy.value(menuState.copyKey))
            }
            LabeledContent(AppCopy.value(.deviceName)) {
                Text(AppCopy.value(snapshot.keyboardHealth.copyKey))
            }
            LabeledContent(AppCopy.value(.currentSignal)) {
                Text(AppCopy.value(snapshot.currentSignal.presentation(in: snapshot.profile).copyKey))
            }
        }
        .formStyle(.grouped)
        .padding()
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
        case .disconnected: .keyboardDisconnected
        case .connected(let protocolHealthy):
            protocolHealthy ? .protocolHealthy : .keyboardConnected
        }
    }
}
