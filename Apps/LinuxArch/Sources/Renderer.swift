import ArchimedesCore
import CArchGL
import Foundation

/// How the window draws the picture. Shared by all windows and saved.
enum DisplayStyle: String, CaseIterable, Identifiable {
    /// Nearest-neighbour pixels.
    case sharp
    /// Bilinear filtering.
    case smooth
    /// A CRT: scanlines that bloom with brightness, an aperture grille when
    /// the window is big enough, slight vignetting.
    case crt

    var id: Self { self }

    var name: String {
        switch self {
        case .sharp: "Sharp Pixels"
        case .smooth: "Smooth"
        case .crt: "CRT"
        }
    }

    static let defaultsKey = "displayStyle"

    @MainActor
    static var saved: DisplayStyle {
        Preferences.standard.string(forKey: defaultsKey).flatMap(DisplayStyle.init(rawValue:)) ?? .sharp
    }

    var glStyle: Int32 {
        switch self {
        case .sharp: Int32(ARCH_GL_SHARP)
        case .smooth: Int32(ARCH_GL_SMOOTH)
        case .crt: Int32(ARCH_GL_CRT)
        }
    }
}

/// How much of the border around the display area the window shows.
/// Shared by all windows and saved.
enum DisplayBorder: String, CaseIterable, Identifiable {
    /// All of it, as VIDC draws it.
    case full
    /// A little around the display area.
    case small
    /// None: just the display area.
    case none

    var id: Self { self }

    var name: String {
        switch self {
        case .full: "Full Border"
        case .small: "Small Border"
        case .none: "No Border"
        }
    }

    static let defaultsKey = "displayBorder"

    @MainActor
    static var saved: DisplayBorder {
        Preferences.standard.string(forKey: defaultsKey).flatMap(DisplayBorder.init(rawValue:)) ?? .full
    }

    /// The part of `f` shown, in frame pixels.
    func crop(_ f: VideoFrame) -> VideoFrame.Area {
        let whole = VideoFrame.Area(x: 0, y: 0, width: f.width, height: f.height)
        guard self != .full, let d = f.displayArea else { return whole }
        guard self == .small else { return d }
        // 32 x 16 actual pixels each side.
        let mx = 32 / max(1, f.scaleX), my = 16 / max(1, f.scaleY)
        let x0 = max(0, d.x - mx), y0 = max(0, d.y - my)
        let x1 = min(f.width, d.x + d.width + mx), y1 = min(f.height, d.y + d.height + my)
        return VideoFrame.Area(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// Draws the machine's frames with OpenGL, in the window's GL area,
/// letterboxed to the frame's display aspect (VIDC frames carry their pixel
/// scale). Its methods need the area's GL context current. (The Mac app's
/// Metal Renderer.)
@MainActor
final class Renderer {
    private let gl: OpaquePointer
    private let host: EmulatorHost
    private var shownFrame: UInt64 = .max
    var style = DisplayStyle.saved
    var border = DisplayBorder.saved {
        didSet { if border != oldValue { shownFrame = .max } }
    }
    /// The part of the last frame shown, in frame pixels.
    private(set) var crop = VideoFrame.Area(x: 0, y: 0, width: 832, height: 576)
    /// Display aspect of the last frame shown.
    private(set) var aspect = 4.0 / 3.0
    /// The last frame's display size in pixels (its "actual size").
    private(set) var actualSize = (width: 832.0, height: 576.0)

    /// Nil (with the reason in `error`) if OpenGL can't build the shaders.
    init?(host: EmulatorHost, error: inout String?) {
        var message: UnsafeMutablePointer<CChar>?
        guard let gl = arch_gl_create(&message) else {
            error = message.map { String(cString: $0) } ?? "OpenGL failed"
            free(message)
            return nil
        }
        self.gl = gl
        self.host = host
    }

    /// Frees the GL objects (before the context goes).
    func destroy() {
        arch_gl_destroy(gl)
    }

    /// Whether there's a frame the screen hasn't shown.
    var hasNewFrame: Bool { host.frame.frameNumber != shownFrame }

    private func upload() {
        let f = host.frame
        guard f.frameNumber != shownFrame, f.width > 0, f.height > 0 else { return }
        shownFrame = f.frameNumber
        if f.width > 1 {
            crop = border.crop(f)
            let size = (width: Double(crop.width * max(1, f.scaleX)), height: Double(crop.height * max(1, f.scaleY)))
            actualSize = size
            aspect = size.width / size.height
        }
        f.pixels.withUnsafeBufferPointer { arch_gl_upload(gl, $0.baseAddress, Int32(f.width), Int32(f.height)) }
    }

    private var glCrop: ArchGLCrop {
        ArchGLCrop(x: Int32(crop.x), y: Int32(crop.y), width: Int32(crop.width), height: Int32(crop.height))
    }

    /// Draws into the GL area's framebuffer, `width` x `height` pixels.
    func draw(width: Int32, height: Int32) {
        upload()
        arch_gl_draw(gl, width, height, style.glStyle, glCrop, aspect)
    }

    /// Renders the current frame offscreen, as the window would show it at
    /// `width` x `height` pixels, as 0xAARRGGBB pixels.
    func renderImage(width: Int, height: Int) -> [UInt32]? {
        upload()
        var pixels = [UInt32](repeating: 0, count: width * height)
        let ok = pixels.withUnsafeMutableBufferPointer {
            arch_gl_render_image(gl, Int32(width), Int32(height), style.glStyle, glCrop, aspect, $0.baseAddress)
        }
        return ok ? pixels : nil
    }
}
