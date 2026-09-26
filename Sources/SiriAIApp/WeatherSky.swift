import AppKit
import MetalKit
import SiriCore
import SwiftUI

// MARK: - Stato del cielo

/// Cosa disegnare: meteo, luce del giorno e posizione del sole (o della luna).
struct SkyState: Equatable {
    var scene = WeatherScene(clouds: 0.25)
    /// 1 di giorno, 0 di notte; sfuma nei 50 minuti attorno ad alba e tramonto.
    var daylight = 1.0
    /// Colori dell'alba e del tramonto, da 0 a 1.
    var twilight = 0.0
    /// Posizione del sole o della luna nella finestra (0…1, dall'alto a sinistra).
    var bodyX = 0.78
    var bodyY = 0.2
    /// Il sole è sopra l'orizzonte (altrimenti il corpo disegnato è la luna).
    var sunUp = true

    init() {}

    init(snapshot: WeatherSnapshot?, now: Date) {
        scene = snapshot?.scene ?? WeatherScene(clouds: 0.25)
        let calendar = Calendar.current
        /// Orari di alba e tramonto riportati sulla data di `now` (la previsione salvata può essere di ieri).
        func today(_ date: Date?, default hour: Int, _ minute: Int) -> Date {
            let components = date.map { calendar.dateComponents([.hour, .minute], from: $0) }
            return calendar.date(bySettingHour: components?.hour ?? hour, minute: components?.minute ?? minute, second: 0, of: now) ?? now
        }
        let sunrise = today(snapshot?.today?.sunrise, default: 7, 0)
        let sunset = today(snapshot?.today?.sunset, default: 19, 20)
        let window = 50.0 * 60
        let afterSunrise = now.timeIntervalSince(sunrise)
        let beforeSunset = sunset.timeIntervalSince(now)
        daylight = min(1, max(0, min(afterSunrise, beforeSunset) / window + 0.5))
        twilight = max(0, 1 - min(abs(afterSunrise), abs(beforeSunset)) / (window * 1.4))
        let dayLength = max(3600, sunset.timeIntervalSince(sunrise))
        sunUp = afterSunrise > 0 && beforeSunset > 0
        if sunUp {
            let progress = afterSunrise / dayLength
            // Sole e luna restano in alto a destra: lì la Home non ha pillole né titoli da coprire.
            bodyX = 0.62 + 0.3 * progress
            bodyY = 0.17 - 0.11 * sin(.pi * progress)
        } else {
            var sinceSunset = now.timeIntervalSince(sunset)
            if sinceSunset < 0 { sinceSunset += 24 * 3600 }
            let progress = min(1, max(0, sinceSunset / max(3600, 24 * 3600 - dayLength)))
            bodyX = 0.62 + 0.3 * progress
            bodyY = 0.17 - 0.11 * sin(.pi * progress)
        }
    }

    /// Colori del cielo: sereno, coperto, pioggia, temporale, neve, nebbia; di giorno, di notte e al crepuscolo.
    func palette(dark: Bool) -> (top: SIMD3<Float>, bottom: SIMD3<Float>, cloud: SIMD3<Float>) {
        let overcast = smooth(0.35, 1, scene.clouds)
        var dayTop = mix(rgb(0x2A6ED6), rgb(0x5D6D82), overcast)
        var dayBottom = mix(rgb(0x88C2F4), rgb(0x9FACBC), overcast)
        dayTop = mix(dayTop, rgb(0x3B4656), scene.rain); dayBottom = mix(dayBottom, rgb(0x6C7989), scene.rain)
        dayTop = mix(dayTop, rgb(0x1D222C), scene.thunder); dayBottom = mix(dayBottom, rgb(0x3C4350), scene.thunder)
        dayTop = mix(dayTop, rgb(0x8C9BB1), scene.snow); dayBottom = mix(dayBottom, rgb(0xD7DEE8), scene.snow)
        dayTop = mix(dayTop, rgb(0x8D97A4), scene.fog * 0.8); dayBottom = mix(dayBottom, rgb(0xC7CDD5), scene.fog * 0.8)

        var nightTop = mix(rgb(0x030920), rgb(0x0C1018), overcast)
        var nightBottom = mix(rgb(0x14254D), rgb(0x21283A), max(overcast, scene.rain))
        nightBottom = mix(nightBottom, rgb(0x2E3544), scene.snow)
        nightTop = mix(nightTop, rgb(0x191D26), scene.fog * 0.6)

        let dusk = scene.clouds > 0.9 ? twilight * 0.35 : twilight * (1 - scene.clouds * 0.55)
        var top = mix(nightTop, dayTop, daylight)
        var bottom = mix(nightBottom, dayBottom, daylight)
        top = mix(top, rgb(0x2F3B7C), dusk * 0.7)
        bottom = mix(bottom, rgb(0xF2946A), dusk * 0.85)

        var dayCloud = mix(rgb(0xF8FAFD), rgb(0xBFC7D2), overcast * 0.6 + scene.rain * 0.4)
        dayCloud = mix(dayCloud, rgb(0x4A515E), scene.thunder)
        let nightCloud = mix(rgb(0x2B3242), rgb(0x191D25), max(scene.rain, scene.thunder))
        var cloud = mix(nightCloud, dayCloud, daylight)
        cloud = mix(cloud, rgb(0xFFB894), dusk * 0.45)
        if dark {
            // Con l'aspetto scuro il cielo è un po' più spento, come il resto dell'app.
            top *= 0.86; bottom *= 0.86; cloud *= 0.9
        }
        return (top, bottom, cloud)
    }

    var sunVisibility: Float { sunUp ? Float(min(1, daylight * 1.6) * (1 - scene.clouds * 0.9) * (1 - scene.fog * 0.6)) : 0 }
    var moonVisibility: Float { sunUp ? 0 : Float((1 - daylight * 0.7) * (1 - scene.clouds * 0.95) * (1 - scene.fog * 0.7)) }
}

private func rgb(_ hex: UInt32) -> SIMD3<Float> {
    SIMD3(Float((hex >> 16) & 0xFF), Float((hex >> 8) & 0xFF), Float(hex & 0xFF)) / 255
}

private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Double) -> SIMD3<Float> { a + (b - a) * Float(min(1, max(0, t))) }

private func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = min(1, max(0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}

// MARK: - Renderer Metal

/// Parametri dello shader (stesso ordine della struttura `SkyUniforms` in Metal).
struct SkyUniforms {
    var frame: SIMD4<Float>
    var weather: SIMD4<Float>
    var light: SIMD4<Float>
    var skyTop: SIMD4<Float>
    var skyBottom: SIMD4<Float>
    var body: SIMD4<Float>
    var cloud: SIMD4<Float>
}

/// Disegna il cielo con uno shader Metal compilato all'avvio dal Metal del sistema (non serve un file .metallib).
@MainActor
final class SkyRenderer: NSObject, MTKViewDelegate {
    struct Pipeline {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let state: MTLRenderPipelineState
    }

    /// Nil se Metal non è disponibile o lo shader non compila: si usa un gradiente.
    static let pipeline: Pipeline? = {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: SkyShader.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "skyVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "skyFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return Pipeline(device: device, queue: queue, state: try device.makeRenderPipelineState(descriptor: descriptor))
        } catch {
            Agent.log("CIELO: shader non disponibile — \(error.localizedDescription)")
            return nil
        }
    }()

    var sky = SkyState()
    var dark = false
    var scroll: Float = 0
    var introToken = 0
    private let start = CACurrentMediaTime()
    private var introStart = CACurrentMediaTime()
    private var introDuration = 1.8

    /// L'apertura: il cielo parte sfocato e più vicino e si mette a fuoco.
    func replayIntro(duration: Double = 1.8) {
        introStart = CACurrentMediaTime()
        introDuration = duration
    }

    private func focus(at time: CFTimeInterval) -> Float {
        let x = min(1, max(0, (time - introStart) / introDuration))
        return Float(1 - pow(1 - x, 3))
    }

    func uniforms(size: CGSize, time: Double, focus: Float) -> SkyUniforms {
        let colors = sky.palette(dark: dark)
        let scene = sky.scene
        return SkyUniforms(
            frame: SIMD4(Float(size.width), Float(size.height), Float(time.truncatingRemainder(dividingBy: 20_000)), focus),
            weather: SIMD4(Float(scene.clouds), Float(scene.rain), Float(scene.snow), Float(scene.fog)),
            light: SIMD4(Float(scene.thunder), Float(sky.daylight), Float(sky.twilight), scroll),
            skyTop: SIMD4(colors.top, 1),
            skyBottom: SIMD4(colors.bottom, 1),
            body: SIMD4(Float(sky.bodyX), Float(sky.bodyY), sky.sunVisibility, sky.moonVisibility),
            cloud: SIMD4(colors.cloud, 1))
    }

    private func encode(_ encoder: MTLRenderCommandEncoder, pipeline: Pipeline, uniforms: SkyUniforms) {
        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline.state)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SkyUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            guard let pipeline = Self.pipeline, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let buffer = pipeline.queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            let now = CACurrentMediaTime()
            encode(encoder, pipeline: pipeline, uniforms: uniforms(size: view.drawableSize, time: now - start, focus: focus(at: now)))
            buffer.present(drawable)
            buffer.commit()
        }
    }

    /// Un fotogramma fisso: con «Riduci movimento» e nelle foto di prova.
    static func still(sky: SkyState, dark: Bool, size: CGSize, scale: CGFloat = 1, time: Double = 42) -> CGImage? {
        guard let pipeline else { return nil }
        let width = Int(size.width * scale), height = Int(size.height * scale)
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
        let renderer = SkyRenderer()
        renderer.sky = sky
        renderer.dark = dark
        renderer.encode(encoder, pipeline: pipeline, uniforms: renderer.uniforms(size: CGSize(width: width, height: height), time: time, focus: 1))
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

/// Vista Metal del cielo: 30 fotogrammi al secondo, risoluzione ridotta (le nuvole sono morbide),
/// ferma quando l'app non è in primo piano o la finestra è coperta.
final class SkyMetalView: MTKView {
    private var observers: [NSObjectProtocol] = []

    init(device: MTLDevice) {
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        preferredFramesPerSecond = 30
        autoResizeDrawable = false
        enableSetNeedsDisplay = false
        isPaused = true
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer?.isOpaque = true
    }

    required init(coder: NSCoder) { fatalError("init(coder:) non usato") }

    isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let scale = min(window?.backingScaleFactor ?? 1, 1.0)
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        if drawableSize != size {
            drawableSize = size
            if isPaused { draw() }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { isPaused = true; return }
        let center = NotificationCenter.default
        let update: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.updatePause() } }
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main, using: update))
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: update))
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: update))
        updatePause()
    }

    private func updatePause() {
        let visible = window?.occlusionState.contains(.visible) == true
        // Diagnostica: SIRIAI_SKY_ALWAYS=1 anima anche fuori schermo (per misurare il consumo).
        let paused = !(visible && NSApp.isActive) && ProcessInfo.processInfo.environment["SIRIAI_SKY_ALWAYS"] == nil
        if paused != isPaused {
            isPaused = paused
            if paused { draw() }
        }
    }
}

// MARK: - Viste SwiftUI

/// Scorrimento della Home, letto solo dal cielo (la dashboard non si ridisegna a ogni pixel di scorrimento).
@MainActor @Observable
final class SkyScroll {
    var offset: CGFloat = 0
}

/// Il cielo animato della Home: vivo con Metal, fisso con «Riduci movimento» e nelle foto di prova.
struct WeatherBackdrop: View {
    let sky: SkyState
    var scroll: SkyScroll?
    var introToken = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    /// Nelle foto di prova la vista Metal non viene catturata: si usa un fotogramma fisso.
    static let stillFrames = CommandLine.arguments.contains("--snapshot") && !CommandLine.arguments.contains("--live-sky")

    var body: some View {
        let dark = scheme == .dark
        if SkyRenderer.pipeline == nil {
            let colors = sky.palette(dark: dark)
            LinearGradient(colors: [Color(simd: colors.top), Color(simd: colors.bottom)], startPoint: .top, endPoint: .bottom)
        } else if reduceMotion || Self.stillFrames {
            StillSky(sky: sky, dark: dark)
        } else {
            LiveSky(sky: sky, dark: dark, scroll: scroll?.offset ?? 0, introToken: introToken)
        }
    }
}

private struct StillSky: View {
    let sky: SkyState
    let dark: Bool

    var body: some View {
        GeometryReader { proxy in
            if let image = SkyRenderer.still(sky: sky, dark: dark, size: proxy.size, scale: 1) {
                Image(decorative: image, scale: 1).resizable()
            }
        }
    }
}

private struct LiveSky: NSViewRepresentable {
    let sky: SkyState
    let dark: Bool
    let scroll: CGFloat
    let introToken: Int

    func makeCoordinator() -> SkyRenderer { SkyRenderer() }

    func makeNSView(context: Context) -> SkyMetalView {
        let view = SkyMetalView(device: SkyRenderer.pipeline!.device)
        view.delegate = context.coordinator
        context.coordinator.introToken = introToken
        context.coordinator.replayIntro()
        return view
    }

    func updateNSView(_ view: SkyMetalView, context: Context) {
        let renderer = context.coordinator
        renderer.sky = sky
        renderer.dark = dark
        renderer.scroll = Float(scroll / max(1, view.bounds.height))
        // Pioggia e neve a 30 fotogrammi al secondo; nuvole e stelle si muovono piano: ne bastano 20.
        let scene = sky.scene
        view.preferredFramesPerSecond = scene.rain > 0 || scene.snow > 0 || scene.thunder > 0 ? 30 : 20
        if renderer.introToken != introToken {
            renderer.introToken = introToken
            renderer.replayIntro(duration: 1.2)
        }
        if view.isPaused { view.draw() }
    }
}

extension Color {
    init(simd: SIMD3<Float>) { self.init(red: Double(simd.x), green: Double(simd.y), blue: Double(simd.z)) }
}
