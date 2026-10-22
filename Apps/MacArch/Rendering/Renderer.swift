import ArchimedesCore
import MetalKit

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

    static let defaultsKey = "MacArchDisplayStyle"

    static var saved: DisplayStyle {
        AppSettings.store.string(forKey: defaultsKey).flatMap(DisplayStyle.init(rawValue:)) ?? .sharp
    }
}

/// Draws the machine's frames with Metal, letterboxed to the frame's
/// display aspect (VIDC frames carry their pixel scale).
@MainActor
final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var texture: MTLTexture?
    private let host: EmulatorHost
    private var shownFrame: UInt64 = .max
    var style = DisplayStyle.saved

    /// Display aspect of the last frame shown.
    private(set) var aspect: CGFloat = 4.0 / 3.0
    /// The last frame's display size in pixels (its "actual size").
    private(set) var actualSize = CGSize(width: 832, height: 576)

    struct Uniforms {
        var style: UInt32
        var viewportHeight: Float
        var lines: Float
    }

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat, host: EmulatorHost) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.host = host
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "vertexMain")
            d.fragmentFunction = library.makeFunction(name: "fragmentMain")
            d.colorAttachments[0].pixelFormat = pixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: d)
        } catch {
            NSLog("MacArch: Metal pipeline: \(error)")
            return nil
        }
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer() else { return }
        encode(into: commands, pass: pass, size: view.drawableSize)
        commands.present(drawable)
        commands.commit()
    }

    private func upload() {
        let f = host.frame
        guard f.frameNumber != shownFrame || texture == nil, f.width > 0, f.height > 0 else { return }
        shownFrame = f.frameNumber
        if texture == nil || texture!.width != f.width || texture!.height != f.height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: f.width, height: f.height, mipmapped: false)
            d.usage = .shaderRead
            texture = device.makeTexture(descriptor: d)
        }
        let size = CGSize(width: f.width * max(1, f.scaleX), height: f.height * max(1, f.scaleY))
        if f.width > 1 {
            actualSize = size
            aspect = size.width / size.height
        }
        f.pixels.withUnsafeBytes { p in
            texture?.replace(region: MTLRegionMake2D(0, 0, f.width, f.height), mipmapLevel: 0,
                             withBytes: p.baseAddress!, bytesPerRow: f.width * 4)
        }
    }

    private func encode(into commands: MTLCommandBuffer, pass: MTLRenderPassDescriptor, size: CGSize) {
        upload()
        guard let texture, let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        var width = size.width, height = size.width / aspect
        if height > size.height { height = size.height; width = height * aspect }
        encoder.setViewport(MTLViewport(originX: (size.width - width) / 2, originY: (size.height - height) / 2,
                                        width: width, height: height, znear: 0, zfar: 1))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        let index: UInt32 = switch style { case .sharp: 0; case .smooth: 1; case .crt: 2 }
        var u = Uniforms(style: index, viewportHeight: Float(height), lines: Float(texture.height))
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    /// The current frame as the window would show it at `width` x `height`.
    func renderImage(width: Int, height: Int) -> CGImage? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = device.makeTexture(descriptor: d), let commands = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        encode(into: commands, pass: pass, size: CGSize(width: width, height: height))
        commands.commit()
        commands.waitUntilCompleted()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 position [[position]]; float2 uv; };
    struct Uniforms { uint style; float viewportHeight; float lines; };

    vertex VOut vertexMain(uint id [[vertex_id]]) {
        float2 c[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        VOut o;
        o.position = float4(c[id], 0, 1);
        o.uv = float2((c[id].x + 1) * 0.5, (1 - c[id].y) * 0.5);
        return o;
    }

    // A raster line's colour at x in linear light, with a little horizontal
    // spread like a real spot.
    float3 rasterLine(texture2d<float> t, float x, float line, float lines) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float y = (clamp(line, 0.0, lines - 1) + 0.5) / lines;
        float dx = 0.6 / t.get_width();
        float3 c = t.sample(s, float2(x, y)).rgb * 0.5 + t.sample(s, float2(x - dx, y)).rgb * 0.25
                 + t.sample(s, float2(x + dx, y)).rgb * 0.25;
        return pow(c, 2.2);
    }

    // Gaussian beam profile across the line; bright lines are wider.
    float3 spot(float3 c, float d) {
        float3 w = mix(float3(0.22), float3(0.34), sqrt(c));
        return c * exp(-0.5 * d * d / (w * w));
    }

    fragment float4 fragmentMain(VOut in [[stage_in]], texture2d<float> t [[texture(0)]],
                                 constant Uniforms &u [[buffer(0)]]) {
        constexpr sampler nearest(filter::nearest);
        constexpr sampler linear(filter::linear);
        if (u.style == 0) { return float4(t.sample(nearest, in.uv).rgb, 1); }
        if (u.style == 1) { return float4(t.sample(linear, in.uv).rgb, 1); }

        // Scanlines fade out where there are too few pixels per line to show them.
        float perLine = u.viewportHeight / u.lines;
        float strength = saturate((perLine - 1.5) / 1.5);
        float y = in.uv.y * u.lines;
        float line = floor(y);
        float off = y - line - 0.5;
        float other = off < 0 ? line - 1 : line + 1;
        float3 a = rasterLine(t, in.uv.x, line, u.lines);
        float3 b = rasterLine(t, in.uv.x, other, u.lines);
        float3 scanned = (spot(a, off) + spot(b, 1 - abs(off))) * 1.2;
        float3 c = mix(mix(a, b, abs(off) * 0.5), scanned, strength);
        if (perLine >= 3) {
            uint stripe = uint(in.position.x) % 3;
            c *= float3(stripe == 0 ? 1.0 : 0.9, stripe == 1 ? 1.0 : 0.9, stripe == 2 ? 1.0 : 0.9) * 1.06;
        }
        float2 d = in.uv - 0.5;
        c *= 1 - dot(d, d) * 0.25;
        return float4(pow(saturate(c), 1 / 2.2), 1);
    }
    """
}
