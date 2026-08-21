import AppKit
import MetalKit
import SwiftUI

enum SpectrumMetalStyle {
    static let minimumBandCapacity = 256
}

enum SpectrumPlotLayout {
    static let plotLeft: CGFloat = 50
    static let plotRight: CGFloat = 18
    static let plotTop: CGFloat = 12
    static let plotBottom: CGFloat = 28

    static func plotRect(in size: CGSize) -> CGRect {
        CGRect(
            x: plotLeft,
            y: plotTop,
            width: max(1, size.width - plotLeft - plotRight),
            height: max(1, size.height - plotTop - plotBottom)
        )
    }
}

struct SpectrumMetalView: NSViewRepresentable, Animatable {
    let snapshot: SpectrumSnapshot
    let settings: SpectrumAnalyzerSettings
    var chromeOpacity: Float
    let onRenderFPS: (Double) -> Void

    var animatableData: Float {
        get { chromeOpacity }
        set { chromeOpacity = newValue }
    }

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
        context.coordinator.renderer?.submit(snapshot, settings: settings, chromeOpacity: chromeOpacity)
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
    let segments: SIMD4<Float>

    init(settings: SpectrumAnalyzerSettings) {
        let requestedGap = Float(settings.ledGapPercent)
        let gapPercent = requestedGap.isFinite ? min(100, max(0, requestedGap)) : 18
        let requestedSegmentCount = Float(settings.ledSegmentCount)
        let segmentCount = requestedSegmentCount.isFinite ? max(1, requestedSegmentCount) : 48

        segments = SIMD4(segmentCount, gapPercent / 100, 0, 0)
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
            float level = clamp(in.meterCoordinate.y, 0.0, 1.0);
            float cellPosition = fract(level * style.segments.x);
            if (level > 0.000001 && cellPosition >= (1.0 - style.segments.y)) {
                return float4(0.0, 0.0, 0.0, 1.0);
            }

            float centerGlow = 0.72 + (0.08 * (1.0 - abs((in.meterCoordinate.x * 2.0) - 1.0)));
            return float4(in.color.rgb * centerGlow, in.color.a);
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
    private var latestChromeOpacity: Float = 1
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
        let vertexCapacity = (supportedBandCount * ((SpectrumAnalyzerSettings.ledRegionCountRange.upperBound * 6) + 6)) + 256
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

    func submit(_ snapshot: SpectrumSnapshot, settings: SpectrumAnalyzerSettings, chromeOpacity: Float) {
        snapshotLock.lock()
        latestSnapshot = snapshot
        latestSettings = settings
        latestChromeOpacity = min(1, max(0, chromeOpacity))
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
        let chromeOpacity = latestChromeOpacity
        snapshotLock.unlock()

        vertices.removeAll(keepingCapacity: true)
        appendScene(snapshot: snapshot, settings: settings, chromeOpacity: chromeOpacity, size: view.bounds.size, to: &vertices)
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

    private func appendScene(snapshot: SpectrumSnapshot, settings: SpectrumAnalyzerSettings, chromeOpacity: Float, size: CGSize, to vertices: inout [SpectrumVertex]) {
        guard size.width > 0, size.height > 0 else { return }
        let plot = SpectrumPlotLayout.plotRect(in: size)
        appendGrid(in: plot, settings: settings, opacity: chromeOpacity, canvasSize: size, to: &vertices)
        appendMergedBars(snapshot: snapshot, settings: settings, in: plot, canvasSize: size, to: &vertices)
    }

    private func appendGrid(in plot: CGRect, settings: SpectrumAnalyzerSettings, opacity: Float, canvasSize: CGSize, to vertices: inout [SpectrumVertex]) {
        guard opacity > 0 else { return }
        let horizontal = SIMD4<Float>(1, 1, 1, 0.08 * opacity)
        let vertical = SIMD4<Float>(1, 1, 1, 0.05 * opacity)
        for db in SpectrumAnalyzerTuning.dbTicks(minimum: Float(settings.minimumDb), maximum: Float(settings.maximumDb)) {
            let y = yPosition(db, settings: settings, in: plot)
            appendRectangle(CGRect(x: plot.minX, y: y, width: plot.width, height: 1), topColor: horizontal, bottomColor: horizontal, canvasSize: canvasSize, to: &vertices)
        }
        for frequency in Self.frequencyTicks {
            let x = xPosition(frequency, in: plot)
            appendRectangle(CGRect(x: x, y: plot.minY, width: 1, height: plot.height), topColor: vertical, bottomColor: vertical, canvasSize: canvasSize, to: &vertices)
        }
    }

    private func appendMergedBars(snapshot: SpectrumSnapshot, settings: SpectrumAnalyzerSettings, in plot: CGRect, canvasSize: CGSize, to vertices: inout [SpectrumVertex]) {
        let count = min(snapshot.left.count, snapshot.right.count, snapshot.leftPeaks.count, snapshot.rightPeaks.count)
        guard count > 0 else { return }
        let cellWidth = plot.width / CGFloat(count)
        let gap = min(max(0, CGFloat(settings.bandGapPixels)), max(0, cellWidth - 1))
        let peakColor = SIMD4<Float>(0.78, 0.78, 0.78, 0.82)
        let totalRows = max(1, Int(settings.ledSegmentCount.rounded()))
        for index in 0..<count {
            let value = max(snapshot.left[index], snapshot.right[index])
            let peak = max(snapshot.leftPeaks[index], snapshot.rightPeaks[index])
            let x = plot.minX + CGFloat(index) * cellWidth + (gap / 2)
            let width = max(1, cellWidth - gap)
            let valueLevel = normalizedLevel(value, settings: settings)
            var lowerRow = 0
            for region in settings.ledRegions {
                let upperRow = min(totalRows, lowerRow + (region.rowCount ?? (totalRows - lowerRow)))
                let lowerLevel = Float(lowerRow) / Float(totalRows)
                let upperLevel = Float(upperRow) / Float(totalRows)
                let visibleUpperLevel = min(valueLevel, upperLevel)
                if visibleUpperLevel > lowerLevel {
                    let topY = plot.maxY - (CGFloat(visibleUpperLevel) * plot.height)
                    let bottomY = plot.maxY - (CGFloat(lowerLevel) * plot.height)
                    let color = Self.meterColor(region.colorRGB)
                    appendRectangle(
                        CGRect(x: x, y: topY, width: width, height: bottomY - topY),
                        topColor: color,
                        bottomColor: color,
                        meterTopLevel: visibleUpperLevel,
                        meterBottomLevel: lowerLevel,
                        canvasSize: canvasSize,
                        to: &vertices
                    )
                }
                lowerRow = upperRow
                if lowerRow >= totalRows || upperLevel >= valueLevel { break }
            }
            let peakY = min(max(plot.minY, yPosition(peak, settings: settings, in: plot)), plot.maxY - 2)
            appendRectangle(CGRect(x: x, y: peakY, width: width, height: 2), topColor: peakColor, bottomColor: peakColor, canvasSize: canvasSize, to: &vertices)
        }
    }

    private static func meterColor(_ values: [Double]) -> SIMD4<Float> {
        SIMD4(
            Float(values.indices.contains(0) ? values[0] : 0),
            Float(values.indices.contains(1) ? values[1] : 0),
            Float(values.indices.contains(2) ? values[2] : 0),
            0.92
        )
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
