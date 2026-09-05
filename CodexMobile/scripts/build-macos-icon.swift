import AppKit
import Foundation

// 复用仓库已有品牌 PNG，统一生成本地开发包与 Xcode 构建的 macOS 图标。
guard CommandLine.arguments.count == 3,
      let artwork = NSImage(contentsOfFile: CommandLine.arguments[1]) else { fatalError("icon_source_missing") }
let output = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("icon_bitmap_failed") }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let size = CGFloat(pixels)
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: size * 0.06, y: size * 0.06, width: size * 0.88, height: size * 0.88), xRadius: size * 0.20, yRadius: size * 0.20).fill()
        let width = size * 0.76, height = width * artwork.size.height / artwork.size.width
        artwork.draw(in: NSRect(x: (size-width)/2, y: (size-height)/2, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("icon_encode_failed") }
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try data.write(to: output.appendingPathComponent(name), options: .atomic)
    }
}
