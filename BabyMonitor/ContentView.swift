//
//  ContentView.swift
//  BabyMonitor
//
//  Created by Armaan Butt on 9/4/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var roleStore: AppRoleStore

    var body: some View {
        Group {
            if let role = roleStore.selectedRole {
                SelectedRoleView(role: role)
            } else {
                RoleSelectionView()
            }
        }
#if targetEnvironment(macCatalyst)
        .frame(minWidth: 600, minHeight: 500)
#endif
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(AppRoleStore())
            .environmentObject(CameraCaptureController())
            .environmentObject(H264VideoEncoderController())
            .environmentObject(H264VideoPlaybackController())
            .environmentObject(RoomAudioCaptureController())
            .environmentObject(RoomAudioPlaybackController())
            .environmentObject(LocalConnectionController())
            .environmentObject(MediaPermissionController())
            .environmentObject(PerformanceDiagnosticsController())
    }
}
