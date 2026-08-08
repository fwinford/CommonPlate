//
//  CommonPlateiosApp.swift
//  CommonPlateios
//
//  Created by faith on 7/5/26.
//

import SwiftUI

@main
struct CommonPlateiosApp: App {
    // The narrowest UIKit bridge SwiftUI's app lifecycle needs for APNs
    // device-token callbacks (Week 3 Day 6 Slice 6A.2). See
    // `PushAppDelegate.swift`.
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(
                remoteNotificationRegistrar: appDelegate.remoteNotificationRegistrar,
                notificationRouter: appDelegate.notificationRouter
            )
        }
    }
}
