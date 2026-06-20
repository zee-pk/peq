//
//  peqApp.swift
//  peq
//
//  Created by Muhammad Zeeshan on 01.05.2026.
//

import AppKit
import IOKit.hidsystem
import SwiftUI
import ServiceManagement

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
    private var volumeHotkeyMonitor: VolumeHotkeyMonitor?
    private let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("peq launched")
        // .accessory = no dock icon, no main menu bar
        NSApp.setActivationPolicy(.accessory)
        
        if !UserDefaults.standard.bool(forKey: "hasRunBefore") {
            UserDefaults.standard.set(true, forKey: "hasRunBefore")
            try? SMAppService.mainApp.register()
        }
        
        statusController = StatusBarController(appState: appState)
        volumeHotkeyMonitor = VolumeHotkeyMonitor(appState: appState)
        volumeHotkeyMonitor?.start()
        
        Task {
            await PermissionManager.shared.checkPermissions()
            if PermissionManager.shared.hasScreenRecordingPermission {
                appState.startMonitoring()
            } else {
                statusController?.showPermissionWindow()
                // Poll until granted (e.g. user returns from System Settings)
                startPermissionPolling()
            }
        }
    }
    
    private func startPermissionPolling() {
        Task {
            while true {
                try? await Task.sleep(for: .seconds(2))
                await PermissionManager.shared.checkPermissions()
                if PermissionManager.shared.hasScreenRecordingPermission {
                    appState.startMonitoring()
                    statusController?.closePermissionWindow()
                    break
                }
            }
        }
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
    private var permissionWindow: NSPanel?

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.image = MaterialIconImage.make(
                MaterialIconName.status,
                size: 18,
                accessibilityDescription: "peq"
            )
            button.target = self
            button.action = #selector(toggleWindow(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            NSLog("peq status item configured")
        } else {
            NSLog("peq failed to create status item button")
        }
    }

    @objc private func toggleWindow(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        
        if event.type == .rightMouseUp {
            let menu = NSMenu()
            
            let toggleEQItem = NSMenuItem(
                title: appState.isProcessing ? "Disable EQ" : "Enable EQ",
                action: #selector(toggleEQ),
                keyEquivalent: ""
            )
            toggleEQItem.target = self
            menu.addItem(toggleEQItem)
            
            let bypassItem = NSMenuItem(
                title: "Bypass",
                action: #selector(toggleBypass),
                keyEquivalent: ""
            )
            bypassItem.target = self
            bypassItem.state = appState.settings.bypass ? .on : .off
            menu.addItem(bypassItem)
            
            menu.addItem(.separator())
            
            let launchAtLoginItem = NSMenuItem(
                title: "Launch at Login",
                action: #selector(toggleLaunchAtLogin),
                keyEquivalent: ""
            )
            launchAtLoginItem.target = self
            launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(launchAtLoginItem)
            
            let quitItem = NSMenuItem(
                title: "Quit",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
            menu.addItem(quitItem)
            
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            if let window = appWindow, window.isVisible {
                window.orderOut(nil)
            } else {
                showWindow()
            }
        }
    }
    
    @objc private func toggleEQ() {
        appState.setProcessing(!appState.isProcessing)
    }

    @objc private func toggleBypass() {
        appState.setBypass(!appState.settings.bypass)
    }
    
    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        if service.status == .enabled {
            try? service.unregister()
        } else {
            try? service.register()
        }
    }

    private func showWindow() {
        var needsInitialPositioning = false
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
            panel.title = "Parametric Equalizer"
            panel.isReleasedWhenClosed = false
            panel.contentViewController = hostingView
            panel.delegate = self
            panel.isMovableByWindowBackground = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            
            if UserDefaults.standard.string(forKey: "NSWindow Frame peqMainWindow") == nil {
                needsInitialPositioning = true
            }
            
            panel.setFrameAutosaveName("peqMainWindow")
            appWindow = panel
        }

        if needsInitialPositioning {
            positionWindowNearStatusItem()
        }
        
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

    // MARK: - Permission Window

    func showPermissionWindow() {
        if permissionWindow == nil {
            let hosting = NSHostingController(
                rootView: PermissionView(permissionManager: PermissionManager.shared)
                    .frame(width: 440)
            )
            hosting.view.setFrameSize(NSSize(width: 440, height: hosting.sizeThatFits(in: NSSize(width: 440, height: 9999)).height))

            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
                styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.title = "Permissions"
            panel.isReleasedWhenClosed = false
            panel.contentViewController = hosting
            panel.delegate = self
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.center()
            permissionWindow = panel
        }
        permissionWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closePermissionWindow() {
        permissionWindow?.orderOut(nil)
        permissionWindow = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

@MainActor
private final class VolumeHotkeyMonitor {
    private weak var appState: AppState?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        guard eventTap == nil else { return }

        guard let systemDefinedEventType = CGEventType(rawValue: UInt32(NSEvent.EventType.systemDefined.rawValue)) else {
            appState?.setVolumeHotkeyRemappingAvailable(false)
            return
        }
        let eventMask = CGEventMask(1 << systemDefinedEventType.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }

            let monitor = Unmanaged<VolumeHotkeyMonitor>
                .fromOpaque(refcon)
                .takeUnretainedValue()

            return MainActor.assumeIsolated {
                monitor.handle(event: event)
            }
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: refcon
        ) else {
            NSLog("peq volume hotkey event tap unavailable")
            appState?.setVolumeHotkeyRemappingAvailable(false)
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        appState?.setVolumeHotkeyRemappingAvailable(true)
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        runLoopSource = nil
        eventTap = nil
        appState?.setVolumeHotkeyRemappingAvailable(false)
    }

    private func handle(event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.type == .tapDisabledByTimeout || event.type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
                appState?.setVolumeHotkeyRemappingAvailable(true)
            } else {
                appState?.setVolumeHotkeyRemappingAvailable(false)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8,
              let appState,
              appState.isEQEffective else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = (nsEvent.data1 & 0xFFFF0000) >> 16
        let keyFlags = nsEvent.data1 & 0x0000FFFF
        let isKeyDown = ((keyFlags & 0xFF00) >> 8) == 0xA
        guard isKeyDown else { return nil }

        switch Int32(keyCode) {
        case NX_KEYTYPE_SOUND_UP:
            appState.adjustOutputGain(by: 0.5)
            return nil
        case NX_KEYTYPE_SOUND_DOWN:
            appState.adjustOutputGain(by: -0.5)
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
