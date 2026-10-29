import ArchimedesCore
import CGtk
import Foundation
import Observation

/// A picture of a machine's screen: 0xAARRGGBB pixels (BGRA in memory),
/// made off the main thread, shown as a GDK texture on it.
struct Pixels: Sendable {
    var width: Int
    var height: Int
    var pixels: [UInt32]

    /// The frame, every other pixel across where it's wider than 640 (a
    /// card shows it a few hundred pixels wide).
    init?(frame f: VideoFrame) {
        guard f.width > 1, f.pixels.count >= f.width * f.height else { return nil }
        let step = f.width > 640 ? 2 : 1
        width = f.width / step
        height = f.height
        var small = [UInt32](repeating: 0, count: width * height)
        let width = width, height = height
        f.pixels.withUnsafeBufferPointer { source in
            small.withUnsafeMutableBufferPointer { out in
                for y in 0..<height {
                    let row = y * f.width
                    for x in 0..<width { out[y * width + x] = source[row + x * step] | 0xFF00_0000 }
                }
            }
        }
        pixels = small
    }

    init(width: Int, height: Int, pixels: [UInt32]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// As a texture (a reference the caller owns).
    func texture() -> OpaquePointer? {
        let bytes = pixels.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }
        defer { g_bytes_unref(bytes) }
        return gdk_memory_texture_new(Int32(width), Int32(height), GDK_MEMORY_B8G8R8A8, bytes, gsize(width * 4))
    }

    /// As a JPEG, for a room's screens.
    func jpeg(quality: Int = 60) -> Data? {
        // gdk-pixbuf wants RGB bytes.
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for (i, p) in pixels.enumerated() {
            rgb[i * 3] = UInt8(truncatingIfNeeded: p >> 16)
            rgb[i * 3 + 1] = UInt8(truncatingIfNeeded: p >> 8)
            rgb[i * 3 + 2] = UInt8(truncatingIfNeeded: p)
        }
        return rgb.withUnsafeMutableBytes { raw -> Data? in
            guard let pixbuf = gdk_pixbuf_new_from_data(raw.baseAddress?.assumingMemoryBound(to: guchar.self), GDK_COLORSPACE_RGB, 0, 8,
                                                        Int32(width), Int32(height), Int32(width * 3), nil, nil) else { return nil }
            defer { g_object_unref(pixbuf.raw) }
            var buffer: UnsafeMutablePointer<gchar>?
            var size: gsize = 0
            var keys: [UnsafeMutablePointer<CChar>?] = [strdup("quality"), nil]
            var values: [UnsafeMutablePointer<CChar>?] = [strdup("\(quality)"), nil]
            defer { keys.forEach { free($0) }; values.forEach { free($0) } }
            let saved = gdk_pixbuf_save_to_bufferv(pixbuf, &buffer, &size, "jpeg", &keys, &values, nil)
            guard saved != 0, let buffer else { return nil }
            defer { g_free(buffer) }
            return Data(bytes: buffer, count: Int(size))
        }
    }

    /// A JPEG (a room member's screen) as a texture, or nil.
    static func texture(jpeg: Data) -> OpaquePointer? {
        let bytes = jpeg.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }
        defer { g_bytes_unref(bytes) }
        return gdk_texture_new_from_bytes(bytes, nil)
    }
}

/// Small live pictures of a network's machines, for the canvas. Only the
/// machines shown are sampled, a few times a second, and each picture is
/// made off the main thread. The machines run whether or not they're
/// shown. (The Mac app's, with GDK textures.)
@MainActor
@Observable
final class ThumbnailCache {
    /// The latest picture of each machine shown, as a texture.
    private(set) var images: [UUID: OpaquePointer] = [:]
    @ObservationIgnored private var shown: [UUID: (host: EmulatorHost, count: Int)] = [:]
    @ObservationIgnored private var lastFrame: [UUID: UInt64] = [:]
    @ObservationIgnored private var timer: GLibTimer?
    @ObservationIgnored private var working: Set<UUID> = []
    /// Pictures a second.
    static let rate = 10.0

    /// A view showing `host`'s picture has appeared.
    func show(_ id: UUID, host: EmulatorHost) {
        let count = (shown[id]?.host === host ? shown[id]?.count ?? 0 : 0) + 1
        shown[id] = (host, count)
        if timer == nil {
            timer = GLibTimer(interval: 1 / Self.rate) { [weak self] in
                guard let self else { return false }
                self.sample()
                return true
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
        if let old = images.removeValue(forKey: id) { g_object_unref(old.raw) }
        lastFrame[id] = nil
    }

    private func sample() {
        for (id, entry) in shown where !working.contains(id) {
            let frame = entry.host.frame
            guard frame.frameNumber != lastFrame[id], frame.width > 1 else { continue }
            lastFrame[id] = frame.frameNumber
            working.insert(id)
            DispatchQueue.global(qos: .utility).async {
                let pixels = Pixels(frame: frame)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.working.remove(id)
                        guard self.shown[id] != nil, let texture = pixels?.texture() else { return }
                        if let old = self.images[id] { g_object_unref(old.raw) }
                        self.images[id] = texture
                    }
                }
            }
        }
    }
}
