import AppKit
import Metal

// Renders the waiting screen's effect to PNGs on the Mac, composited over a stand-in dashboard, so
// the shader can be checked without installing on the phone.
//
// Usage: shadercheck <output folder> [--welcome] (iPhone 7 portrait at 2x)

let folder = CommandLine.arguments[1]
let welcome = CommandLine.arguments.contains("--welcome")
let width = welcome ? 750 : 1334, height = welcome ? 1334 : 750
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
    if impact < 0 {
        // Same title as WaitingView, at the phone's 2x scale.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let base = NSFont.systemFont(ofSize: 72, weight: .semibold)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(red: 0.45, green: 0.05, blue: 0.1, alpha: 0.35)
        shadow.shadowBlurRadius = 20
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let title = NSAttributedString(string: welcome ? "Welcome to septintas" : "Waiting for your Mac", attributes: [
            .font: base,
            .paragraphStyle: paragraph,
            .foregroundColor: NSColor.white,
            .shadow: shadow,
        ])
        if welcome {
            let textWidth = CGFloat(width) - 96
            let subtitle = NSAttributedString(string: "Rotate your iPhone to landscape.", attributes: [
                .font: NSFont.systemFont(ofSize: 36), .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph,
            ])
            let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
            let titleHeight = ceil(title.boundingRect(with: NSSize(width: textWidth, height: 1000), options: options).height)
            let subHeight = ceil(subtitle.boundingRect(with: NSSize(width: textWidth, height: 1000), options: options).height)
            let bottom = (CGFloat(height) - titleHeight - 32 - subHeight) / 2
            subtitle.draw(with: NSRect(x: 48, y: bottom, width: textWidth, height: subHeight), options: options)
            title.draw(with: NSRect(x: 48, y: bottom + subHeight + 32, width: textWidth, height: titleHeight), options: options)
        } else {
            let size = title.size()
            title.draw(at: NSPoint(x: (CGFloat(width) - size.width) / 2, y: (CGFloat(height) - size.height) / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(folder)/\(name).png"))
    print("wrote \(name)")
}

if welcome {
    render(name: "welcome-portrait", time: 5, impact: -1, warmth: 0)
    exit(0)
}

render(name: "idle-a", time: 5, impact: -1)
render(name: "idle-b", time: 25, impact: -1)
for ms in [20, 80, 200, 400, 650, 900, 1200, 1450] {
    render(name: "impact-\(ms)", time: 25 + Float(ms) / 1000, impact: Float(ms) / 1000 / 1.45)
}

for (name, effect): (String, Float) in [("forward", 1), ("backward", -1), ("disconnect", 2)] {
    for progress: Float in [0, 0.2, 0.45, 0.5, 0.55, 0.8, 1] {
        render(name: "\(name)-\(Int(progress * 100))", time: 25 + progress, impact: progress, effect: effect)
    }
}

render(name: "disconnected-black-stop", time: 5, impact: -1, warmth: 0)
render(name: "connecting-half-warm", time: 5, impact: -1, warmth: 0.5)
