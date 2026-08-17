import AppKit

@MainActor
final class GainHUDController {
    private let panel: NSPanel
    private let contentView = GainHUDContentView()
    private var dismissWorkItem: DispatchWorkItem?
    private var presentationID = 0

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 130),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.level = .statusBar
        panel.contentView = contentView
    }

    func show(gainDb: Double) {
        dismissWorkItem?.cancel()
        presentationID += 1
        let currentPresentationID = presentationID

        contentView.update(gainDb: gainDb)
        positionOnActiveScreen()
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        let workItem = DispatchWorkItem { [weak self] in
            self?.dismiss(presentationID: currentPresentationID)
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
    }

    private func positionOnActiveScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }

        let panelSize = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - panelSize.width / 2,
            y: visibleFrame.midY - panelSize.height / 2
        ))
    }

    private func dismiss(presentationID: Int) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.presentationID == presentationID else { return }
                self.panel.orderOut(nil)
            }
        }
    }
}

private final class GainHUDContentView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Cambridge Audio")
    private let gainLabel = NSTextField(labelWithString: "")
    private let shadowContainer = NSView()
    private let visualEffectView = NSVisualEffectView()
    private let tintView = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true

        shadowContainer.wantsLayer = true
        shadowContainer.layer?.cornerRadius = 18
        shadowContainer.layer?.cornerCurve = .continuous
        shadowContainer.layer?.shadowColor = NSColor.black.cgColor
        shadowContainer.layer?.shadowOpacity = 0.28
        shadowContainer.layer?.shadowRadius = 16
        shadowContainer.layer?.shadowOffset = CGSize(width: 0, height: -4)
        shadowContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shadowContainer)

        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 18
        visualEffectView.layer?.cornerCurve = .continuous
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false
        shadowContainer.addSubview(visualEffectView)

        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.01).cgColor
        tintView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(tintView)

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center

        gainLabel.font = .monospacedDigitSystemFont(ofSize: 38, weight: .semibold)
        gainLabel.textColor = .labelColor
        gainLabel.alignment = .center

        let stack = NSStackView(views: [titleLabel, gainLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        tintView.addSubview(stack)

        NSLayoutConstraint.activate([
            shadowContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            shadowContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            shadowContainer.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            shadowContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            visualEffectView.leadingAnchor.constraint(equalTo: shadowContainer.leadingAnchor),
            visualEffectView.trailingAnchor.constraint(equalTo: shadowContainer.trailingAnchor),
            visualEffectView.topAnchor.constraint(equalTo: shadowContainer.topAnchor),
            visualEffectView.bottomAnchor.constraint(equalTo: shadowContainer.bottomAnchor),
            tintView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            tintView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            tintView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: tintView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: tintView.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        shadowContainer.layer?.shadowPath = CGPath(
            roundedRect: shadowContainer.bounds,
            cornerWidth: 18,
            cornerHeight: 18,
            transform: nil
        )
    }

    func update(gainDb: Double) {
        gainLabel.stringValue = gainDb.formatted(.number.precision(.fractionLength(0...1))) + " dB"
    }
}
