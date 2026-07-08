import AVFoundation
import Foundation

final class MicLevel {
    private let engine = AVAudioEngine()
    private var baseline: Float?
    private var baselineSamples: [Float] = []
    private var loudFrames = 0
    private var running = false
    var onLoud: (() -> Void)?

    var authorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestAccess(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func start() {
        guard !running else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            logLine("mic level: not authorized — grant Microphone access in System Settings")
            return
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            logLine("mic level: no input channel")
            return
        }
        baseline = nil
        baselineSamples = []
        loudFrames = 0
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        do {
            try engine.start()
            running = true
            logLine("mic level: listening")
        } catch {
            logLine("mic level: engine failed — \(error.localizedDescription)")
        }
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        logLine("mic level: stopped")
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        var sumSquares: Float = 0
        for index in 0..<frameCount {
            let sample = channel[index]
            sumSquares += sample * sample
        }
        let rms = sqrt(sumSquares / Float(frameCount))
        let decibels = 20 * log10(max(rms, 1e-7))

        if baselineSamples.count < 40 {
            baselineSamples.append(decibels)
            if baselineSamples.count == 40 {
                baseline = baselineSamples.reduce(0, +) / Float(baselineSamples.count)
            }
            return
        }
        guard let baseline else { return }
        if decibels > baseline + 12 {
            loudFrames += 1
        } else {
            loudFrames = 0
        }
        if loudFrames >= 3 {
            loudFrames = 0
            DispatchQueue.main.async { self.onLoud?() }
        }
    }
}
