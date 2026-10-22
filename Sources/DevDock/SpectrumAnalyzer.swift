import Accelerate
import Combine
import Foundation

/// Turns the EQ's recent output into 40 log-spaced levels (0...1) for the glow behind the
/// EQ curve. Runs at 30 fps, only while the player is open and the EQ engine is running.
/// Main thread only.
final class SpectrumAnalyzer: ObservableObject {
    static let binCount = 40
    private static let fftSize = 2048

    @Published private(set) var levels: [Float] = Array(repeating: 0, count: binCount)

    private let eq: EQController
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private var timer: Timer?
    private var bins: [Range<Int>] = []
    private var binsSampleRate: Double = 0

    init(eq: EQController) {
        self.eq = eq
        let log2n = vDSP_Length(log2(Double(Self.fftSize)))
        self.log2n = log2n
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        var window = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        self.window = window
    }

    deinit {
        timer?.invalidate()
        vDSP_destroy_fftsetup(setup)
    }

    func setActive(_ active: Bool) {
        if active, timer == nil {
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
            // .common keeps it running while you drag a slider.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !active, let timer {
            timer.invalidate()
            self.timer = nil
            levels = Array(repeating: 0, count: Self.binCount)
        }
    }

    private func tick() {
        let n = Self.fftSize
        var samples = [Float](repeating: 0, count: n)
        let copied = samples.withUnsafeMutableBufferPointer { buffer in
            eq.copyRecentSamples(into: buffer.baseAddress!, count: n)
        }
        guard copied == n, let sampleRate = eq.sampleRate else {
            decay()
            return
        }
        if sampleRate != binsSampleRate {
            bins = Self.makeBins(sampleRate: sampleRate, fftSize: n)
            binsSampleRate = sampleRate
        }

        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))

        let half = n / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { realBuffer in
            imag.withUnsafeMutableBufferPointer { imagBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        // Full-scale sine is about -6 dB after this normalization. Music sits far lower, so
        // map -75...-15 dB to 0...1, with a +3 dB/octave tilt so highs aren't always flat.
        let normalization = Float(n * n)
        var next = levels
        for (index, range) in bins.enumerated() {
            var peak: Float = 0
            for bin in range where magnitudes[bin] > peak {
                peak = magnitudes[bin]
            }
            let centerHz = Double(range.lowerBound + range.upperBound) / 2 * sampleRate / Double(n)
            let tilt = Float(3 * log2(max(centerHz, 1) / 1000))
            let decibels = 10 * log10(peak / normalization + 1e-12) + tilt
            let target = min(max((decibels + 75) / 60, 0), 1)
            let previous = next[index]
            // Fast attack, slow fall.
            next[index] = target > previous
                ? previous + (target - previous) * 0.6
                : previous * 0.86 + target * 0.14
        }
        levels = next
    }

    private func decay() {
        guard levels.contains(where: { $0 > 0.001 }) else { return }
        levels = levels.map { $0 * 0.85 }
    }

    private static func makeBins(sampleRate: Double, fftSize: Int) -> [Range<Int>] {
        let low = 30.0
        let high = min(18_000.0, sampleRate * 0.47)
        let half = fftSize / 2
        var ranges: [Range<Int>] = []
        var start = max(1, Int(low * Double(fftSize) / sampleRate))
        for i in 0..<binCount {
            let edge = low * pow(high / low, Double(i + 1) / Double(binCount))
            var end = Int((edge * Double(fftSize) / sampleRate).rounded())
            end = min(max(end, start + 1), half)
            if start >= end {
                start = max(end - 1, 0)
            }
            ranges.append(start..<end)
            start = end
        }
        return ranges
    }
}
