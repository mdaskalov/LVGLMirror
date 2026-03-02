//
//  LVGLMirrorApp.swift
//  LVGLMirror
//
//  Created by Milko Daskalov on 01.01.26.
//

import SwiftUI

#if os(macOS)
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
#endif

@main
struct LVGLMirrorApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif
    var body: some Scene {
        WindowGroup {
            LVGLView()
        }
#if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
#endif
    }
}
