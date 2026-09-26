import AppKit
import MetalKit
import SiriCore
import SwiftUI

// MARK: - Aurora degli spazi

/// Colori dell'aurora: Lavoro blu, Personale verde, Programmazione viola; pastello con l'aspetto chiaro, profonda con quello scuro.
struct AtmospherePalette: Equatable {
    var base: SIMD3<Float>
    var colors: [SIMD4<Float>]

    static func of(_ space: Space, dark: Bool) -> AtmospherePalette {
        func c(_ hex: UInt32, _ intensity: Float) -> SIMD4<Float> {
            SIMD4(Float((hex >> 16) & 0xFF) / 255, Float((hex >> 8) & 0xFF) / 255, Float(hex & 0xFF) / 255, intensity)
        }
        func b(_ hex: UInt32) -> SIMD3<Float> { SIMD3(Float((hex >> 16) & 0xFF), Float((hex >> 8) & 0xFF), Float(hex & 0xFF)) / 255 }
        switch (space, dark) {
        case (.lavoro, true): return AtmospherePalette(base: b(0x060A16), colors: [c(0x2F6BFF, 0.42), c(0x7B4DFF, 0.34), c(0x16B8F0, 0.28), c(0x3D2BB8, 0.36)])
        case (.lavoro, false): return AtmospherePalette(base: b(0xF3F6FD), colors: [c(0x9DBDFF, 0.85), c(0xC9B5FF, 0.7), c(0x9EDDF8, 0.7), c(0xBACDFF, 0.6)])
        case (.personale, true): return AtmospherePalette(base: b(0x040E0B), colors: [c(0x1FAF74, 0.38), c(0x11A3B5, 0.3), c(0x8BCB3F, 0.22), c(0x1C6F8F, 0.34)])
        case (.personale, false): return AtmospherePalette(base: b(0xF2FAF5), colors: [c(0x9FE3C2, 0.8), c(0x9CDCE8, 0.65), c(0xD0EE9C, 0.6), c(0xAFD8F0, 0.55)])
        case (.codice, true): return AtmospherePalette(base: b(0x0A0714), colors: [c(0x8B4DFF, 0.4), c(0xD94BD6, 0.26), c(0x4B5BFF, 0.34), c(0x5C2A9E, 0.38)])
        case (.codice, false): return AtmospherePalette(base: b(0xF7F3FD), colors: [c(0xCDB5FF, 0.8), c(0xF1B9E8, 0.65), c(0xB7BFFF, 0.65), c(0xDCC8FF, 0.55)])
        }
    }
}

struct AtmosphereUniforms {
    var frame: SIMD4<Float>     // larghezza, altezza, tempo, messa a fuoco
    var base: SIMD4<Float>      // colore di fondo, w: 1 aspetto scuro
    var c0: SIMD4<Float>
    var c1: SIMD4<Float>
    var c2: SIMD4<Float>
    var c3: SIMD4<Float>
    var extra: SIMD4<Float>     // x: scorrimento, y: energia (Siri AI+ sta pensando)
}

/// Aurora animata dietro tutta l'app (la Home con il meteo ha il suo cielo): 15 fotogrammi al secondo, ferma quando l'app non è in primo piano.
@MainActor
final class AtmosphereRenderer: NSObject, MTKViewDelegate {
    struct Pipeline {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let state: MTLRenderPipelineState
    }

    static let pipeline: Pipeline? = {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: AtmosphereShader.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "atmosphereVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "atmosphereFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return Pipeline(device: device, queue: queue, state: try device.makeRenderPipelineState(descriptor: descriptor))
        } catch {
            Agent.log("AURORA: shader non disponibile — \(error.localizedDescription)")
            return nil
        }
    }()

    var palette = AtmospherePalette.of(.lavoro, dark: false)
    var dark = false
    var energyTarget: Float = 0
    var scroll: Float = 0
    var introToken = 0
    private var energy: Float = 0
    private let start = CACurrentMediaTime()
    private var introStart = CACurrentMediaTime()

    func replayIntro() { introStart = CACurrentMediaTime() }

    func uniforms(size: CGSize, time: Double, focus: Float, energy: Float) -> AtmosphereUniforms {
        let colors = palette.colors + Array(repeating: SIMD4<Float>(0, 0, 0, 0), count: max(0, 4 - palette.colors.count))
        return AtmosphereUniforms(
            frame: SIMD4(Float(size.width), Float(size.height), Float(time.truncatingRemainder(dividingBy: 20_000)), focus),
            base: SIMD4(palette.base, dark ? 1 : 0),
            c0: colors[0], c1: colors[1], c2: colors[2], c3: colors[3],
            extra: SIMD4(scroll, energy, 0, 0))
    }

    private func encode(_ encoder: MTLRenderCommandEncoder, pipeline: Pipeline, uniforms: AtmosphereUniforms) {
        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline.state)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<AtmosphereUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            guard let pipeline = Self.pipeline, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let buffer = pipeline.queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            let now = CACurrentMediaTime()
            // L'energia sale e scende piano: l'aurora «respira» mentre Siri AI+ pensa.
            energy += (energyTarget - energy) * 0.08
            let intro = Float(min(1, max(0, (now - introStart) / 1.4)))
            let focus = 1 - pow(1 - intro, 3)
            encode(encoder, pipeline: pipeline, uniforms: uniforms(size: view.drawableSize, time: now - start, focus: focus, energy: energy))
            buffer.present(drawable)
            buffer.commit()
        }
    }

    /// Un fotogramma fisso (Riduci movimento, foto di prova).
    static func still(palette: AtmospherePalette, dark: Bool, size: CGSize, time: Double = 30) -> CGImage? {
        guard let pipeline else { return nil }
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        guard let texture = pipeline.device.makeTexture(descriptor: descriptor), let buffer = pipeline.queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        let renderer = AtmosphereRenderer()
        renderer.palette = palette
        renderer.dark = dark
        renderer.encode(encoder, pipeline: pipeline, uniforms: renderer.uniforms(size: CGSize(width: width, height: height), time: time, focus: 1, energy: 0))
        if let blit = buffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: texture)
            blit.endEncoding()
        }
        buffer.commit()
        buffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Lo sfondo vivo dell'app: aurora nei colori dello spazio, che si accende quando Siri AI+ lavora.
struct AtmosphereBackdrop: View {
    let space: Space
    var energetic = false
    var introToken = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = AtmospherePalette.of(space, dark: scheme == .dark)
        if AtmosphereRenderer.pipeline == nil {
            LinearGradient(colors: [Color(simd: palette.base), Color(simd: palette.colors.first.map { SIMD3($0.x, $0.y, $0.z) } ?? palette.base)],
                           startPoint: .top, endPoint: .bottom)
        } else if reduceMotion || WeatherBackdrop.stillFrames {
            GeometryReader { proxy in
                if let image = AtmosphereRenderer.still(palette: palette, dark: scheme == .dark, size: proxy.size) {
                    Image(decorative: image, scale: 1).resizable()
                }
            }
        } else {
            LiveAtmosphere(palette: palette, dark: scheme == .dark, energetic: energetic, introToken: introToken)
        }
    }
}

private struct LiveAtmosphere: NSViewRepresentable {
    let palette: AtmospherePalette
    let dark: Bool
    let energetic: Bool
    let introToken: Int

    func makeCoordinator() -> AtmosphereRenderer { AtmosphereRenderer() }

    func makeNSView(context: Context) -> SkyMetalView {
        let view = SkyMetalView(device: AtmosphereRenderer.pipeline!.device)
        view.preferredFramesPerSecond = 15
        view.delegate = context.coordinator
        context.coordinator.introToken = introToken
        return view
    }

    func updateNSView(_ view: SkyMetalView, context: Context) {
        let renderer = context.coordinator
        renderer.palette = palette
        renderer.dark = dark
        renderer.energyTarget = energetic ? 1 : 0
        // Mentre Siri AI+ pensa l'aurora si muove più fluida.
        view.preferredFramesPerSecond = energetic ? 30 : 15
        if renderer.introToken != introToken {
            renderer.introToken = introToken
            renderer.replayIntro()
        }
        if view.isPaused { view.draw() }
    }
}

enum AtmosphereShader {
    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct AtmosphereUniforms {
        float4 frame;
        float4 base;
        float4 c0;
        float4 c1;
        float4 c2;
        float4 c3;
        float4 extra;
    };

    struct AtmosphereVertex {
        float4 position [[position]];
        float2 uv;
    };

    vertex AtmosphereVertex atmosphereVertex(uint vid [[vertex_id]]) {
        const float2 corners[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        AtmosphereVertex out;
        out.position = float4(corners[vid], 0.0, 1.0);
        out.uv = float2(corners[vid].x * 0.5 + 0.5, 0.5 - corners[vid].y * 0.5);
        return out;
    }

    inline float hash21(float2 p) {
        p = fract(p * float2(233.34, 851.73));
        p += dot(p, p + 23.45);
        return fract(p.x * p.y);
    }

    inline float noise(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        return mix(mix(hash21(i), hash21(i + float2(1.0, 0.0)), u.x), mix(hash21(i + float2(0.0, 1.0)), hash21(i + float2(1.0, 1.0)), u.x), u.y);
    }

    inline float fbm(float2 p, int octaves) {
        float value = 0.0;
        float amplitude = 0.5;
        const float2x2 turn = float2x2(1.6, 1.2, -1.2, 1.6);
        for (int i = 0; i < octaves; i++) {
            value += amplitude * noise(p);
            p = turn * p + float2(3.1, 1.7);
            amplitude *= 0.5;
        }
        return value;
    }

    fragment float4 atmosphereFragment(AtmosphereVertex in [[stage_in]], constant AtmosphereUniforms &u [[buffer(0)]]) {
        float2 res = max(u.frame.xy, float2(1.0));
        float focus = clamp(u.frame.w, 0.0, 1.0);
        float energy = u.extra.y;
        // Con l'energia il tempo scorre un po' più veloce e i colori si accendono.
        float t = u.frame.z * (1.0 + energy * 0.6);
        float aspect = res.x / res.y;
        float2 uv = in.uv;
        float2 p = float2(uv.x * aspect, uv.y + u.extra.x * 0.08);
        bool dark = u.base.w > 0.5;

        float2 q = p * 1.1 + float2(t * 0.011, -t * 0.007);
        float flow = fbm(q + float2(fbm(q * 0.6 + t * 0.008, 3)), 4);

        float2 centers[4] = {
            float2(aspect * (0.22 + 0.14 * sin(t * 0.043)), 0.22 + 0.12 * cos(t * 0.037)),
            float2(aspect * (0.8 + 0.12 * cos(t * 0.039)), 0.18 + 0.14 * sin(t * 0.031 + 1.3)),
            float2(aspect * (0.62 + 0.18 * sin(t * 0.027 + 2.1)), 0.8 + 0.1 * cos(t * 0.036)),
            float2(aspect * (0.16 + 0.1 * cos(t * 0.033 + 0.7)), 0.86 + 0.08 * sin(t * 0.029))
        };
        float4 colors[4] = { u.c0, u.c1, u.c2, u.c3 };

        float3 col = u.base.rgb;
        float boost = 1.0 + energy * 0.45;
        for (int i = 0; i < 4; i++) {
            float2 d = p - centers[i] - (flow - 0.5) * 0.45;
            float g = exp(-dot(d, d) * (dark ? 4.6 : 3.2));
            float amount = colors[i].w * boost;
            if (dark) {
                col += colors[i].rgb * g * amount;
            } else {
                col = mix(col, colors[i].rgb, clamp(g * amount, 0.0, 1.0));
            }
        }
        // Venature di seta lungo il flusso.
        col *= dark ? (0.9 + 0.2 * flow) : (0.97 + 0.06 * flow);
        // Apertura: dal colore di fondo all'aurora piena.
        col = mix(u.base.rgb, col, 0.3 + 0.7 * focus);
        float2 v = in.uv - 0.5;
        col *= dark ? (1.0 - dot(v, v) * 0.35) : (1.0 - dot(v, v) * 0.05);
        col += (hash21(in.position.xy + fract(u.frame.z)) - 0.5) / 255.0;
        return float4(clamp(col, 0.0, 1.0), 1.0);
    }
    """#
}
