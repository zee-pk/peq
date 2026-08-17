import AppKit
import MetalKit
import SwiftUI

enum SpectrumMetalStyle {
    static let minimumBandCapacity = 256
}

enum SpectrumPlotLayout {
    static let channelGap: CGFloat = 16
    static let plotLeft: CGFloat = 70
    static let plotRight: CGFloat = 52
    static let plotTop: CGFloat = 24
    static let plotBottom: CGFloat = 26

    static func plotRects(in size: CGSize) -> [CGRect] {
        let channelHeight = max(0, (size.height - channelGap) / 2)
        return (0..<2).map { channel in
            let originY = CGFloat(channel) * (channelHeight + channelGap)
            return CGRect(
                x: plotLeft,
                y: originY + plotTop,
                width: max(1, size.width - plotLeft - plotRight),
                height: max(1, channelHeight - plotTop - plotBottom)
            )
        }
    }
}

struct SpectrumMetalView: NSViewRepresentable {
    let snapshot: SpectrumSnapshot
    let settings: SpectrumAnalyzerSettings
    let onRenderFPS: (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard context.coordinator.attach(to: view) else {
            view.isPaused = true
            let label = NSTextField(labelWithString: "Metal renderer unavailable")
            label.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
            return view
        }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.renderer?.submit(snapshot, settings: settings)
        context.coordinator.renderer?.onMeasuredFPS = onRenderFPS
        context.coordinator.renderer?.updatePreferredFrameRate()
    }

    final class Coordinator {
        fileprivate var renderer: SpectrumMetalRenderer?

        func attach(to view: MTKView) -> Bool {
            do {
                renderer = try SpectrumMetalRenderer(view: view)
                return true
            } catch {
                NSLog("Spectrum Metal renderer initialization failed: %@", error.localizedDescription)
                return false
            }
        }
    }
}

private enum SpectrumMetalRendererError: LocalizedError {
    case noDevice
    case commandQueueCreationFailed
    case shaderFunctionMissing(String)
    case vertexBufferCreationFailed

    var errorDescription: String? {
        switch self {
        case .noDevice:
            return "No Metal device is available."
        case .commandQueueCreationFailed:
            return "The Metal command queue could not be created."
        case .shaderFunctionMissing(let name):
            return "The Metal shader function '\(name)' was not found."
        case .vertexBufferCreationFailed:
            return "The Metal vertex buffers could not be allocated."
        }
    }
}

private struct SpectrumVertex {
    let position: SIMD2<Float>
    let color: SIMD4<Float>
    let meterCoordinate: SIMD2<Float>
    let isMeter: Float
}

private struct SpectrumStyleUniforms {
    let darkRed: SIMD4<Float>
    let orangeRed: SIMD4<Float>
    let orange: SIMD4<Float>
    let yellow: SIMD4<Float>
    let thresholds: SIMD4<Float>
    let segments: SIMD4<Float>

    init(settings: SpectrumAnalyzerSettings) {
        let darkRedSize = Self.sanitizedRegionSize(Float(settings.darkRedRegionPercent))
        let orangeRedSize = Self.sanitizedRegionSize(Float(settings.orangeRedRegionPercent))
        let orangeSize = Self.sanitizedRegionSize(Float(settings.orangeRegionPercent))
        let yellowSize = Self.sanitizedRegionSize(Float(settings.yellowRegionPercent))
        let requestedTotal = darkRedSize + orangeRedSize + orangeSize + yellowSize

        let regionSizes: SIMD4<Float>
        if requestedTotal.isFinite, requestedTotal > 0 {
            regionSizes = SIMD4(darkRedSize, orangeRedSize, orangeSize, yellowSize) / requestedTotal
        } else {
            regionSizes = SIMD4(0.38, 0.22, 0.20, 0.20)
        }

        let requestedGap = Float(settings.ledGapPercent)
        let gapPercent = requestedGap.isFinite ? min(100, max(0, requestedGap)) : 18
        let requestedSegmentCount = Float(settings.ledSegmentCount)
        let segmentCount = requestedSegmentCount.isFinite ? max(1, requestedSegmentCount) : 48

        darkRed = SIMD4(Self.color(settings.darkRedRGB), 1)
        orangeRed = SIMD4(Self.color(settings.orangeRedRGB), 1)
        orange = SIMD4(Self.color(settings.orangeRGB), 1)
        yellow = SIMD4(Self.color(settings.yellowRGB), 1)
        thresholds = SIMD4(regionSizes.x, regionSizes.x + regionSizes.y, regionSizes.x + regionSizes.y + regionSizes.z, 0)
        segments = SIMD4(segmentCount, gapPercent / 100, 0, 0)
    }

    private static func sanitizedRegionSize(_ value: Float) -> Float {
        value.isFinite ? max(0, value) : 0
    }

    private static func color(_ values: [Double]) -> SIMD3<Float> {
        SIMD3(Float(values.indices.contains(0) ? values[0] : 0), Float(values.indices.contains(1) ? values[1] : 0), Float(values.indices.contains(2) ? values[2] : 0))
    }
}

private final class SpectrumMetalRenderer: NSObject, MTKViewDelegate {
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct SpectrumVertex {
        float2 position;
        float4 color;
        float2 meterCoordinate;
        float isMeter;
    };

    struct SpectrumRasterData {
        float4 position [[position]];
        float4 color;
        float2 meterCoordinate;
        float isMeter;
    };

    struct SpectrumStyle {
        float4 darkRed;
        float4 orangeRed;
        float4 orange;
        float4 yellow;
        float4 thresholds;
        float4 segments;
    };

    vertex SpectrumRasterData spectrumVertex(const device SpectrumVertex *vertices [[buffer(0)]], uint vertexID [[vertex_id]]) {
        SpectrumRasterData out;
        out.position = float4(vertices[vertexID].position, 0.0, 1.0);
        out.color = vertices[vertexID].color;
        out.meterCoordinate = vertices[vertexID].meterCoordinate;
        out.isMeter = vertices[vertexID].isMeter;
        return out;
    }

    fragment float4 spectrumFragment(SpectrumRasterData in [[stage_in]], constant SpectrumStyle &style [[buffer(1)]]) {
        if (in.isMeter > 0.5) {
            if (fract(in.meterCoordinate.y * style.segments.x) < style.segments.y) {
                return float4(0.0, 0.0, 0.0, 1.0);
            }

            float level = clamp(in.meterCoordinate.y, 0.0, 1.0);
            float3 meterColor;
            if (level < style.thresholds.x) {
                meterColor = style.darkRed.rgb;
            } else if (level < style.thresholds.y) {
                meterColor = style.orangeRed.rgb;
            } else if (level < style.thresholds.z) {
                meterColor = style.orange.rgb;
            } else {
                meterColor = style.yellow.rgb;
            }
            float centerGlow = 0.90 + (0.10 * (1.0 - abs((in.meterCoordinate.x * 2.0) - 1.0)));
            return float4(meterColor * centerGlow, 0.98);
        }
        return in.color;
    }
    """

    private static let frequencyTicks: [Float] = [20, 100, 1_000, 5_000, 10_000, 20_000]

    private weak var view: MTKView?
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let vertexBuffers: [MTLBuffer]
    private let vertexCapacity: Int
    private let inFlightSemaphore = DispatchSemaphore(value: 3)
    private var bufferIndex = 0
    private var vertices: [SpectrumVertex] = []
    private let snapshotLock = NSLock()
    private var latestSnapshot = SpectrumSnapshot.empty
    private var latestSettings = SpectrumAnalyzerSettings()
    private let measurementLock = NSLock()
    private var measuredFrameCount = 0
    private var measuredFrameStart = CACurrentMediaTime()

    var onMeasuredFPS: ((Double) -> Void)?

    init(view: MTKView) throws {
        guard let device = view.device else { throw SpectrumMetalRendererError.noDevice }
        guard let commandQueue = device.makeCommandQueue() else {
            throw SpectrumMetalRendererError.commandQueueCreationFailed
        }
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        guard let vertexFunction = library.makeFunction(name: "spectrumVertex") else {
            throw SpectrumMetalRendererError.shaderFunctionMissing("spectrumVertex")
        }
        guard let fragmentFunction = library.makeFunction(name: "spectrumFragment") else {
            throw SpectrumMetalRendererError.shaderFunctionMissing("spectrumFragment")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        let supportedBandCount = SpectrumMetalStyle.minimumBandCapacity
        let vertexCapacity = (supportedBandCount * 24) + 256
        let bufferLength = vertexCapacity * MemoryLayout<SpectrumVertex>.stride
        let buffers = (0..<3).compactMap { _ in device.makeBuffer(length: bufferLength, options: .storageModeShared) }
        guard buffers.count == 3 else { throw SpectrumMetalRendererError.vertexBufferCreationFailed }

        self.view = view
        self.commandQueue = commandQueue
        self.pipelineState = pipelineState
        self.vertexBuffers = buffers
        self.vertexCapacity = vertexCapacity
        super.init()
        vertices.reserveCapacity(vertexCapacity)

        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = max(60, view.window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60)
        view.delegate = self
    }

    func submit(_ snapshot: SpectrumSnapshot, settings: SpectrumAnalyzerSettings) {
        snapshotLock.lock()
        latestSnapshot = snapshot
        latestSettings = settings
        snapshotLock.unlock()
    }

    func updatePreferredFrameRate() {
        guard let view else { return }
        view.preferredFramesPerSecond = max(60, view.window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.preferredFramesPerSecond = max(60, view.window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60)
    }

    func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        inFlightSemaphore.wait()

        snapshotLock.lock()
        let snapshot = latestSnapshot
        let settings = latestSettings
        snapshotLock.unlock()

        vertices.removeAll(keepingCapacity: true)
        appendScene(snapshot: snapshot, settings: settings, size: view.bounds.size, to: &vertices)
        guard vertices.count <= vertexCapacity else {
            NSLog("Spectrum Metal vertex capacity exceeded: generated %d vertices, capacity is %d.", vertices.count, vertexCapacity)
            encoder.endEncoding()
            inFlightSemaphore.signal()
            return
        }

        commandBuffer.addCompletedHandler { [weak self, inFlightSemaphore] completedBuffer in
            inFlightSemaphore.signal()
            guard completedBuffer.status == .completed else {
                if let error = completedBuffer.error {
                    NSLog("Spectrum Metal command buffer failed: %@", error.localizedDescription)
                }
                return
            }
            self?.recordCompletedFrame()
        }

        let vertexBuffer = vertexBuffers[bufferIndex]
        bufferIndex = (bufferIndex + 1) % vertexBuffers.count
        vertices.withUnsafeBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                memcpy(vertexBuffer.contents(), baseAddress, bytes.count)
            }
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        var style = SpectrumStyleUniforms(settings: settings)
        encoder.setFragmentBytes(&style, length: MemoryLayout<SpectrumStyleUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func recordCompletedFrame() {
        measurementLock.lock()
        measuredFrameCount += 1
        let now = CACurrentMediaTime()
        let elapsed = now - measuredFrameStart
        guard elapsed >= 1 else {
            measurementLock.unlock()
            return
        }
        let fps = Double(measuredFrameCount) / elapsed
        measuredFrameCount = 0
        measuredFrameStart = now
        measurementLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onMeasuredFPS?(fps)
        }
    }

    private func appendScene(snapshot: SpectrumSnapshot, settings: SpectrumAnalyzerSettings, size: CGSize, to vertices: inout [SpectrumVertex]) {
        guard size.width > 0, size.height > 0 else { return }
        let plots = SpectrumPlotLayout.plotRects(in: size)
        let channels = [(snapshot.left, snapshot.leftPeaks), (snapshot.right, snapshot.rightPeaks)]

        for (plot, channel) in zip(plots, channels) {
            appendGrid(in: plot, settings: settings, canvasSize: size, to: &vertices)
            appendBars(values: channel.0, peaks: channel.1, settings: settings, in: plot, canvasSize: size, to: &vertices)
            appendBorder(around: plot, canvasSize: size, to: &vertices)
        }
    }

    private func appendGrid(in plot: CGRect, settings: SpectrumAnalyzerSettings, canvasSize: CGSize, to vertices: inout [SpectrumVertex]) {
        let horizontal = SIMD4<Float>(1, 1, 1, 0.16)
        let vertical = SIMD4<Float>(1, 1, 1, 0.10)
        for db in SpectrumAnalyzerTuning.dbTicks(minimum: Float(settings.minimumDb), maximum: Float(settings.maximumDb)) {
            let y = yPosition(db, settings: settings, in: plot)
            appendRectangle(CGRect(x: plot.minX, y: y, width: plot.width, height: 1), topColor: horizontal, bottomColor: horizontal, canvasSize: canvasSize, to: &vertices)
        }
        for frequency in Self.frequencyTicks {
            let x = xPosition(frequency, in: plot)
            appendRectangle(CGRect(x: x, y: plot.minY, width: 1, height: plot.height), topColor: vertical, bottomColor: vertical, canvasSize: canvasSize, to: &vertices)
        }
    }

    private func appendBars(values: [Float], peaks: [Float], settings: SpectrumAnalyzerSettings, in plot: CGRect, canvasSize: CGSize, to vertices: inout [SpectrumVertex]) {
        let count = min(values.count, peaks.count)
        guard count > 0 else { return }
        let cellWidth = plot.width / CGFloat(count)
        let gap = min(max(0, CGFloat(settings.bandGapPixels)), max(0, cellWidth - 1))
        let peakColor = SIMD4<Float>(1, 1, 1, 0.96)
        for index in 0..<count {
            let x = plot.minX + CGFloat(index) * cellWidth + (gap / 2)
            let width = max(1, cellWidth - gap)
            let y = yPosition(values[index], settings: settings, in: plot)
            appendRectangle(
                CGRect(x: x, y: y, width: width, height: plot.maxY - y),
                topColor: .zero,
                bottomColor: .zero,
                meterTopLevel: normalizedLevel(values[index], settings: settings),
                meterBottomLevel: 0,
                canvasSize: canvasSize,
                to: &vertices
            )
            let peakY = yPosition(peaks[index], settings: settings, in: plot)
            appendRectangle(CGRect(x: x, y: peakY, width: width, height: 2), topColor: peakColor, bottomColor: peakColor, canvasSize: canvasSize, to: &vertices)
        }
    }

    private func appendBorder(around plot: CGRect, canvasSize: CGSize, to vertices: inout [SpectrumVertex]) {
        let color = SIMD4<Float>(1, 1, 1, 0.32)
        appendRectangle(CGRect(x: plot.minX, y: plot.minY, width: plot.width, height: 1), topColor: color, bottomColor: color, canvasSize: canvasSize, to: &vertices)
        appendRectangle(CGRect(x: plot.minX, y: plot.maxY - 1, width: plot.width, height: 1), topColor: color, bottomColor: color, canvasSize: canvasSize, to: &vertices)
        appendRectangle(CGRect(x: plot.minX, y: plot.minY, width: 1, height: plot.height), topColor: color, bottomColor: color, canvasSize: canvasSize, to: &vertices)
        appendRectangle(CGRect(x: plot.maxX - 1, y: plot.minY, width: 1, height: plot.height), topColor: color, bottomColor: color, canvasSize: canvasSize, to: &vertices)
    }

    private func appendRectangle(
        _ rect: CGRect,
        topColor: SIMD4<Float>,
        bottomColor: SIMD4<Float>,
        meterTopLevel: Float = -1,
        meterBottomLevel: Float = -1,
        canvasSize: CGSize,
        to vertices: inout [SpectrumVertex]
    ) {
        guard rect.width > 0, rect.height >= 0 else { return }
        let topLeft = clipPosition(CGPoint(x: rect.minX, y: rect.minY), canvasSize: canvasSize)
        let topRight = clipPosition(CGPoint(x: rect.maxX, y: rect.minY), canvasSize: canvasSize)
        let bottomLeft = clipPosition(CGPoint(x: rect.minX, y: rect.maxY), canvasSize: canvasSize)
        let bottomRight = clipPosition(CGPoint(x: rect.maxX, y: rect.maxY), canvasSize: canvasSize)
        let isMeter: Float = meterTopLevel >= 0 ? 1 : 0
        vertices.append(SpectrumVertex(position: topLeft, color: topColor, meterCoordinate: SIMD2(0, meterTopLevel), isMeter: isMeter))
        vertices.append(SpectrumVertex(position: bottomLeft, color: bottomColor, meterCoordinate: SIMD2(0, meterBottomLevel), isMeter: isMeter))
        vertices.append(SpectrumVertex(position: topRight, color: topColor, meterCoordinate: SIMD2(1, meterTopLevel), isMeter: isMeter))
        vertices.append(SpectrumVertex(position: topRight, color: topColor, meterCoordinate: SIMD2(1, meterTopLevel), isMeter: isMeter))
        vertices.append(SpectrumVertex(position: bottomLeft, color: bottomColor, meterCoordinate: SIMD2(0, meterBottomLevel), isMeter: isMeter))
        vertices.append(SpectrumVertex(position: bottomRight, color: bottomColor, meterCoordinate: SIMD2(1, meterBottomLevel), isMeter: isMeter))
    }

    private func clipPosition(_ point: CGPoint, canvasSize: CGSize) -> SIMD2<Float> {
        SIMD2(Float((point.x / canvasSize.width) * 2 - 1), Float(1 - (point.y / canvasSize.height) * 2))
    }

    private func yPosition(_ db: Float, settings: SpectrumAnalyzerSettings, in plot: CGRect) -> CGFloat {
        let minimumDb = Float(settings.minimumDb)
        let maximumDb = Float(settings.maximumDb)
        let clamped = min(maximumDb, max(minimumDb, db))
        let fraction = CGFloat((clamped - minimumDb) / (maximumDb - minimumDb))
        return plot.maxY - fraction * plot.height
    }

    private func normalizedLevel(_ db: Float, settings: SpectrumAnalyzerSettings) -> Float {
        let minimumDb = Float(settings.minimumDb)
        let maximumDb = Float(settings.maximumDb)
        let clamped = min(maximumDb, max(minimumDb, db))
        return (clamped - minimumDb) / (maximumDb - minimumDb)
    }

    private func xPosition(_ frequency: Float, in plot: CGRect) -> CGFloat {
        plot.minX + CGFloat(log10f(frequency / 20) / 3) * plot.width
    }
}
