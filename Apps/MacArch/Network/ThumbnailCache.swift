import ArchimedesCore
import CoreGraphics
import Foundation
import Observation

/// Small live pictures of a network's machines, for the canvas. Only the
/// machines shown are sampled, a few times a second, and each picture is
/// made off the main thread. The machines run whether or not they're
/// shown. (After MacBeeb's.)
@MainActor
@Observable
final class ThumbnailCache {
    /// The latest picture of each machine shown.
    private(set) var images: [UUID: CGImage] = [:]
    @ObservationIgnored private var shown: [UUID: (host: EmulatorHost, count: Int)] = [:]
    @ObservationIgnored private var lastFrame: [UUID: UInt64] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var working: Set<UUID> = []
    /// Pictures a second.
    static let rate = 10.0

    /// A view showing `host`'s picture has appeared.
    func show(_ id: UUID, host: EmulatorHost) {
        let count = (shown[id]?.host === host ? shown[id]?.count ?? 0 : 0) + 1
        shown[id] = (host, count)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1 / Self.rate, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
        }
    }

    /// One of the views showing it has gone.
    func hide(_ id: UUID) {
        guard let entry = shown[id] else { return }
        if entry.count > 1 {
            shown[id] = (entry.host, entry.count - 1)
        } else {
            shown[id] = nil
            if shown.isEmpty {
                timer?.invalidate()
                timer = nil
            }
        }
    }

    /// Forgets a machine that's been switched off.
    func forget(_ id: UUID) {
        images[id] = nil
        lastFrame[id] = nil
    }

    private func sample() {
        for (id, entry) in shown where !working.contains(id) {
            let frame = entry.host.frame
            guard frame.frameNumber != lastFrame[id], frame.width > 1 else { continue }
            lastFrame[id] = frame.frameNumber
            working.insert(id)
            DispatchQueue.global(qos: .utility).async {
                let image = Self.image(frame)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.working.remove(id)
                        if self.shown[id] != nil, let image { self.images[id] = image }
                    }
                }
            }
        }
    }

    /// The frame as an image, every other pixel across where it's wider
    /// than 640 (the card shows it a few hundred points wide).
    nonisolated static func image(_ f: VideoFrame) -> CGImage? {
        guard f.pixels.count >= f.width * f.height else { return nil }
        let step = f.width > 640 ? 2 : 1
        let width = f.width / step, height = f.height
        var small = [UInt32](repeating: 0, count: width * height)
        f.pixels.withUnsafeBufferPointer { source in
            small.withUnsafeMutableBufferPointer { out in
                for y in 0..<height {
                    let row = y * f.width
                    for x in 0..<width { out[y * width + x] = source[row + x * step] }
                }
            }
        }
        let data = small.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
