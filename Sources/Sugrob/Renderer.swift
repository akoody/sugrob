import MetalKit
import simd

struct SpriteInstance {
    var pos: V2
    var size: V2
    var uv: SIMD4<Float>
    var color: SIMD4<Float>
    var rot: Float
    var z: Float
    var pad: V2 = .zero
}

struct SnowVertex {
    var p: SIMD4<Float>   // x, y, depth from crest, z
    var q: SIMD4<Float>   // stable x, snow height, shadow length, slope
    var r: SIMD4<Float>   // back-ridge tint, unused
}

struct Uniforms {
    var screen: V2
    var time: Float
    var pad: Float = 0
}

final class GPU {
    static let shared = GPU()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let atlas: Atlas
    let sprite: MTLRenderPipelineState
    let occluder: MTLRenderPipelineState
    let snow: MTLRenderPipelineState
    let depthWrite: MTLDepthStencilState
    let depthTest: MTLDepthStencilState

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal is required")
        }
        self.device = device
        self.queue = queue
        atlas = Atlas(device: device, queue: queue)
        let library = try! device.makeLibrary(source: shaderSource, options: nil)

        func pipeline(_ v: String, _ f: String?, write: Bool = true) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: v)
            d.fragmentFunction = f.flatMap { library.makeFunction(name: $0) }
            d.depthAttachmentPixelFormat = .depth32Float
            let c = d.colorAttachments[0]!
            c.pixelFormat = .bgra8Unorm
            if write {
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one
                c.sourceAlphaBlendFactor = .one
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            } else {
                c.writeMask = []
            }
            return try! device.makeRenderPipelineState(descriptor: d)
        }

        sprite = pipeline("spriteVertex", "spriteFragment")
        occluder = pipeline("occluderVertex", nil, write: false)
        snow = pipeline("snowVertex", "snowFragment")

        let dw = MTLDepthStencilDescriptor()
        dw.depthCompareFunction = .less
        dw.isDepthWriteEnabled = true
        depthWrite = device.makeDepthStencilState(descriptor: dw)!
        let dt = MTLDepthStencilDescriptor()
        dt.depthCompareFunction = .lessEqual
        dt.isDepthWriteEnabled = false
        depthTest = device.makeDepthStencilState(descriptor: dt)!
    }
}

final class Sink {
    let sprites: UnsafeMutablePointer<SpriteInstance>
    let spriteCap: Int
    var spriteCount = 0
    var behindCount = 0

    let verts: UnsafeMutablePointer<SnowVertex>
    let vertCap: Int
    var vertCount = 0
    var strips: [(start: Int, count: Int)] = []
    /// Strips drawn before the "behind" sprites, so the tree stands between the far and near ridges.
    var farStrips = 0

    let occ: UnsafeMutablePointer<SIMD4<Float>>
    let occCap: Int
    var occCount = 0

    let uv: [SIMD4<Float>]

    init(sprites: MTLBuffer, verts: MTLBuffer, occ: MTLBuffer, uv: [SIMD4<Float>]) {
        spriteCap = sprites.length / MemoryLayout<SpriteInstance>.stride
        self.sprites = sprites.contents().bindMemory(to: SpriteInstance.self, capacity: spriteCap)
        vertCap = verts.length / MemoryLayout<SnowVertex>.stride
        self.verts = verts.contents().bindMemory(to: SnowVertex.self, capacity: vertCap)
        occCap = occ.length / MemoryLayout<SIMD4<Float>>.stride
        self.occ = occ.contents().bindMemory(to: SIMD4<Float>.self, capacity: occCap)
        self.uv = uv
    }

    func reset() {
        spriteCount = 0; behindCount = 0; vertCount = 0; occCount = 0; farStrips = 0
        strips.removeAll(keepingCapacity: true)
    }

    @inline(__always)
    func put(_ s: Sprite, _ x: Float, _ y: Float, _ w: Float, _ h: Float, rot: Float = 0, z: Float,
             c: SIMD4<Float> = SIMD4(repeating: 1)) {
        guard spriteCount < spriteCap else { return }
        sprites[spriteCount] = SpriteInstance(pos: V2(x, y), size: V2(w, h), uv: uv[s.rawValue], color: c, rot: rot, z: z)
        spriteCount += 1
    }

    /// Draws only a horizontal band of a sprite, given as fractions of its height.
    func putBand(_ s: Sprite, from v0: Float, to v1: Float, _ x: Float, _ y: Float, _ w: Float, _ h: Float, rot: Float, z: Float, c: SIMD4<Float>) {
        guard spriteCount < spriteCap else { return }
        let u = uv[s.rawValue]
        let band = SIMD4<Float>(u.x, lerpf(u.y, u.w, v0), u.z, lerpf(u.y, u.w, v1))
        sprites[spriteCount] = SpriteInstance(pos: V2(x, y), size: V2(w, h), uv: band, color: c, rot: rot, z: z)
        spriteCount += 1
    }

    func occlude(_ r: Rect2, z: Float) {
        guard occCount + 6 <= occCap else { return }
        let a = SIMD4<Float>(r.x, r.y, z, 1), b = SIMD4<Float>(r.x + r.w, r.y, z, 1)
        let c = SIMD4<Float>(r.x, r.y + r.h, z, 1), d = SIMD4<Float>(r.x + r.w, r.y + r.h, z, 1)
        occ[occCount] = a; occ[occCount + 1] = b; occ[occCount + 2] = c
        occ[occCount + 3] = b; occ[occCount + 4] = d; occ[occCount + 5] = c
        occCount += 6
    }
}

final class Renderer: NSObject, MTKViewDelegate {
    private struct FrameSet { let sprites, verts, occ: MTLBuffer; let sink: Sink }

    let world: World
    private let gpu = GPU.shared
    private var frames: [FrameSet] = []
    private var index = 0
    private let inFlight = DispatchSemaphore(value: 2)
    private(set) var clearedWhileHidden = false

    init(world: World) {
        self.world = world
        super.init()
        let device = gpu.device
        for _ in 0..<2 {
            let sprites = device.makeBuffer(length: 6000 * MemoryLayout<SpriteInstance>.stride, options: .storageModeShared)!
            let verts = device.makeBuffer(length: 40000 * MemoryLayout<SnowVertex>.stride, options: .storageModeShared)!
            let occ = device.makeBuffer(length: 600 * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared)!
            frames.append(FrameSet(sprites: sprites, verts: verts, occ: occ, sink: Sink(sprites: sprites, verts: verts, occ: occ, uv: gpu.atlas.uv)))
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard inFlight.wait(timeout: .now()) == .success else { return }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = gpu.queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: pass) else {
            inFlight.signal()
            return
        }
        cb.addCompletedHandler { [inFlight] _ in inFlight.signal() }
        clearedWhileHidden = world.hidden
        if !world.hidden { encodeScene(enc) }
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    /// Renders one frame into an offscreen texture (used by --snapshot and the self-test).
    func renderOffscreen(width: Int, height: Int) -> MTLTexture {
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .managed
        let color = gpu.device.makeTexture(descriptor: colorDesc)!
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .private
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.depthAttachment.texture = gpu.device.makeTexture(descriptor: depthDesc)!
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        let cb = gpu.queue.makeCommandBuffer()!
        let enc = cb.makeRenderCommandEncoder(descriptor: pass)!
        encodeScene(enc)
        enc.endEncoding()
        let blit = cb.makeBlitCommandEncoder()!
        blit.synchronize(resource: color)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return color
    }

    private func encodeScene(_ enc: MTLRenderCommandEncoder) {
        let frame = frames[index]
        index = (index + 1) % frames.count
        let k = frame.sink
        k.reset()
        world.fill(k)

        var u = Uniforms(screen: world.size, time: world.windTime)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)

        if k.occCount > 0 {
            enc.setRenderPipelineState(gpu.occluder)
            enc.setDepthStencilState(gpu.depthWrite)
            enc.setVertexBuffer(frame.occ, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: k.occCount)
        }
        enc.setDepthStencilState(gpu.depthTest)

        func drawSprites(_ range: Range<Int>) {
            guard !range.isEmpty else { return }
            enc.setRenderPipelineState(gpu.sprite)
            enc.setVertexBuffer(frame.sprites, offset: range.lowerBound * MemoryLayout<SpriteInstance>.stride, index: 0)
            enc.setFragmentTexture(gpu.atlas.texture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: range.count)
        }

        func drawStrips(_ range: Range<Int>) {
            guard !range.isEmpty else { return }
            enc.setRenderPipelineState(gpu.snow)
            enc.setVertexBuffer(frame.verts, offset: 0, index: 0)
            for s in k.strips[range] { enc.drawPrimitives(type: .triangleStrip, vertexStart: s.start, vertexCount: s.count) }
        }
        drawStrips(0..<k.farStrips)
        drawSprites(0..<k.behindCount)
        drawStrips(k.farStrips..<k.strips.count)
        drawSprites(k.behindCount..<k.spriteCount)
    }
}
