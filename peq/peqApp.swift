//
//  peqApp.swift
//  peq
//
//  Created by Muhammad Zeeshan on 01.05.2026.
//

import AppKit
import SwiftUI

@main
struct peqApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("peq") {
            ContentView()
                .environmentObject(appState)
                .frame(width: 760, height: 760)
                .task {
                    appState.startMonitoring()
                    appDelegate.installStatusItem(appState: appState)
                }
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("peq launched")
        NSApp.setActivationPolicy(.regular)
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("peq terminating")
    }

    func installStatusItem(appState: AppState) {
        guard statusController == nil else { return }
        NSLog("peq installing status item")
        statusController = StatusBarController(appState: appState)
    }
}

@MainActor
final class StatusBarController {
    private let appState: AppState
    private let statusItem: NSStatusItem
    private let popover = NSPopover()

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: 56)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "peq")
            button.imagePosition = .imageLeading
            button.title = "peq"
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            NSLog("peq status item configured")
        } else {
            NSLog("peq failed to create status item button")
        }

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 760, height: 760)
        popover.contentViewController = NSHostingController(
            rootView: ContentView()
                .environmentObject(appState)
                .frame(width: 740)
        )
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
