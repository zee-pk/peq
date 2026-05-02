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

    var body: some Scene {
        // No visible scenes – the window is managed by StatusBarController.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusBarController?
    private let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("peq launched")
        // .accessory = no dock icon, no main menu bar
        NSApp.setActivationPolicy(.accessory)
        appState.startMonitoring()
        statusController = StatusBarController(appState: appState)
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("peq terminating")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@MainActor
final class StatusBarController: NSObject, NSWindowDelegate {
    private let appState: AppState
    private let statusItem: NSStatusItem
    private var appWindow: NSPanel?

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "peq")
            button.target = self
            button.action = #selector(toggleWindow(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            NSLog("peq status item configured")
        } else {
            NSLog("peq failed to create status item button")
        }
    }

    @objc private func toggleWindow(_ sender: NSStatusBarButton) {
        if let window = appWindow, window.isVisible {
            window.orderOut(nil)
        } else {
            showWindow()
        }
    }

    private func showWindow() {
        if appWindow == nil {
            let hostingView = NSHostingController(
                rootView: ContentView()
                    .environmentObject(appState)
                    .frame(width: 760, height: 760)
            )

            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 760),
                styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.title = "peq"
            panel.isReleasedWhenClosed = false
            panel.contentViewController = hostingView
            panel.delegate = self
            panel.isMovableByWindowBackground = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            appWindow = panel
        }

        positionWindowNearStatusItem()
        appWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func positionWindowNearStatusItem() {
        guard let window = appWindow,
              let buttonFrame = statusItem.button?.window?.frame else { return }

        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        let windowSize = window.frame.size

        // Center the window horizontally under the status item
        var x = buttonFrame.midX - windowSize.width / 2
        let y = buttonFrame.minY - windowSize.height - 4

        // Clamp to screen edges
        x = max(screenFrame.minX + 8, min(x, screenFrame.maxX - windowSize.width - 8))

        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
