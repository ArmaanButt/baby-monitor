import SwiftUI

struct SelectedRoleView: View {
    let role: DeviceRole

    var body: some View {
        switch role {
        case .monitor:
            MonitorView()
        case .viewer:
            ViewerView()
        }
    }
}
