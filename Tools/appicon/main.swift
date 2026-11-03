import AppKit
import Metal

// Renders the app icon using the exact waiting-screen shader, without its title.
// Compile with Phone/WaitingShader.swift; pass the output folder.

let folder = CommandLine.arguments[1]
let width = 1024, height = 1024
let device = MTLCreateSystemDefaultDevice()!
let library = try! device.makeLibrary(source: waitingShaderSource, options: nil)
let description = MTLRenderPipelineDescriptor()
description.vertexFunction = library.makeFunction(name: "waitingVertex")
description.fragmentFunction = library.makeFunction(name: "waitingFragment")
description.colorAttachments[0].pixelFormat = .bgra8Unorm
let pipeline = try! device.makeRenderPipelineState(descriptor: description)
let queue = device.makeCommandQueue()!

struct Uniforms { var time: Float; var aspect: Float; var impact: Float; var warmth: Float; var effect: Float }

func render(name: String, time: Float, impact: Float, effect: Float = 0, warmth: Float = 1) {
    let textureInfo = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    textureInfo.usage = [.renderTarget, .shaderRead]
    textureInfo.storageMode = .managed
    let texture = device.makeTexture(descriptor: textureInfo)!
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
    pass.colorAttachments[0].storeAction = .store
    let buffer = queue.makeCommandBuffer()!
    let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)!
    var uniforms = Uniforms(time: time, aspect: Float(width) / Float(height), impact: impact, warmth: warmth, effect: effect)
    encoder.setRenderPipelineState(pipeline)
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
    let blit = buffer.makeBlitCommandEncoder()!
    blit.synchronize(resource: texture)
    blit.endEncoding()
    buffer.commit()
    buffer.waitUntilCompleted()

    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    if effect != 0 {
        let expectedAlpha: UInt8? = impact == 0 ? 0 : (impact == 1 ? (effect == 2 ? 255 : 0) : (impact == 0.5 && abs(effect) == 1 ? 255 : nil))
        if let expectedAlpha {
            precondition(stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == expectedAlpha },
                         "Transition endpoint or covered midpoint failed: \(name)")
        }
    }
    // Premultiplied BGRA over a dark stand-in with light stripes, so anything see-through shows up.
    var flat = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            let back: UInt8 = (x / 80 + y / 80) % 2 == 0 ? 28 : 44
            let a = Int(pixels[i + 3])
            flat[i] = UInt8(min(255, Int(pixels[i + 2]) + Int(back) * (255 - a) / 255))
            flat[i + 1] = UInt8(min(255, Int(pixels[i + 1]) + Int(back) * (255 - a) / 255))
            flat[i + 2] = UInt8(min(255, Int(pixels[i]) + Int(back) * (255 - a) / 255))
        }
    }
    let provider = CGDataProvider(data: Data(flat) as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(folder)/\(name).png"))
    print("wrote \(name)")
}

render(name: "AppIcon", time: 5, impact: -1, warmth: 1)
