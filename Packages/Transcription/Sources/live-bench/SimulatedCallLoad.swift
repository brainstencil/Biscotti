import Foundation
import Metal
import MetalPerformanceShaders
import Synchronization

/// Stands in for a video call while the replay runs: two threads busy 60% of
/// the time, and matrix multiplies that keep the GPU about 30% busy.
/// Reports call it "simulated call load".
final class SimulatedCallLoad: Sendable {
    static let cpuThreads = 2
    static let cpuDutyCycle = 0.6
    static let cpuPeriod: TimeInterval = 0.1
    static let gpuDutyCycle = 0.3
    /// GPU time per batch the batch size adapts to: long enough to measure,
    /// short enough that the load stays even.
    static let gpuBatchTarget: TimeInterval = 0.03
    static let matrixSize = 2048

    private let isRunning = Atomic(false)
    /// Keeps the busy loops' results alive so the compiler cannot drop them.
    private let sink = Atomic<UInt64>(0)

    /// Starts the load; it runs until `stop()`.
    /// - Throws: `BenchError.noMetalDevice` when there is no GPU to load.
    static func start() throws -> SimulatedCallLoad {
        guard MTLCreateSystemDefaultDevice() != nil else { throw BenchError.noMetalDevice }
        let load = SimulatedCallLoad()
        load.isRunning.store(true, ordering: .relaxed)
        for index in 0 ..< cpuThreads {
            let thread = Thread { load.runCPU() }
            thread.name = "live-bench call load CPU \(index)"
            thread.start()
        }
        let gpu = Thread { load.runGPU() }
        gpu.name = "live-bench call load GPU"
        gpu.start()
        return load
    }

    func stop() {
        isRunning.store(false, ordering: .relaxed)
    }

    /// How long to stay idle after `busy` seconds of work for `dutyCycle`.
    static func idleSeconds(afterBusy busy: TimeInterval, dutyCycle: Double) -> TimeInterval {
        busy * (1 - dutyCycle) / dutyCycle
    }

    /// The batch size that brings the next batch near `gpuBatchTarget`.
    static func nextBatchSize(current: Int, measuredSeconds: TimeInterval) -> Int {
        guard measuredSeconds > 0 else { return current }
        return min(64, max(1, Int((Double(current) * gpuBatchTarget / measuredSeconds).rounded())))
    }

    private func runCPU() {
        var value: UInt64 = 0x9E37_79B9_7F4A_7C15
        while isRunning.load(ordering: .relaxed) {
            let busyUntil = Date(timeIntervalSinceNow: Self.cpuPeriod * Self.cpuDutyCycle)
            while Date() < busyUntil {
                for _ in 0 ..< 10000 {
                    value ^= value << 13
                    value ^= value >> 7
                    value ^= value << 17
                }
            }
            sink.store(value, ordering: .relaxed)
            Thread.sleep(forTimeInterval: Self.cpuPeriod * (1 - Self.cpuDutyCycle))
        }
    }

    private func runGPU() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(), let matrices = Matrices(device: device) else { return }
        var batchSize = 1
        while isRunning.load(ordering: .relaxed) {
            guard let commandBuffer = queue.makeCommandBuffer() else { return }
            for _ in 0 ..< batchSize {
                matrices.multiply.encode(commandBuffer: commandBuffer, leftMatrix: matrices.left, rightMatrix: matrices.right, resultMatrix: matrices.result)
            }
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            let busy = commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
            batchSize = Self.nextBatchSize(current: batchSize, measuredSeconds: busy)
            Thread.sleep(forTimeInterval: Self.idleSeconds(afterBusy: busy, dutyCycle: Self.gpuDutyCycle))
        }
    }

    private struct Matrices {
        let left: MPSMatrix
        let right: MPSMatrix
        let result: MPSMatrix
        let multiply: MPSMatrixMultiplication

        init?(device: MTLDevice) {
            let size = SimulatedCallLoad.matrixSize
            let rowBytes = size * MemoryLayout<Float>.stride
            let descriptor = MPSMatrixDescriptor(rows: size, columns: size, rowBytes: rowBytes, dataType: .float32)
            let buffers = (0 ..< 3).compactMap { _ in device.makeBuffer(length: size * rowBytes, options: .storageModePrivate) }
            guard buffers.count == 3 else { return nil }
            left = MPSMatrix(buffer: buffers[0], descriptor: descriptor)
            right = MPSMatrix(buffer: buffers[1], descriptor: descriptor)
            result = MPSMatrix(buffer: buffers[2], descriptor: descriptor)
            multiply = MPSMatrixMultiplication(
                device: device,
                transposeLeft: false,
                transposeRight: false,
                resultRows: size,
                resultColumns: size,
                interiorColumns: size,
                alpha: 1,
                beta: 0
            )
        }
    }
}
