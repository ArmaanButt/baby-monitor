//
//  BabyMonitorApp.swift
//  BabyMonitor
//
//  Created by Armaan Butt on 9/4/26.
//

import SwiftUI

@main
struct BabyMonitorApp: App {
    @StateObject private var roleStore = AppRoleStore()
    @StateObject private var camera = CameraCaptureController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(roleStore)
                .environmentObject(camera)
        }
    }
}
