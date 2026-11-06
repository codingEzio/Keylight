import AppKit

@main struct AssetIconSmoke {
    static func main() {
        precondition(CommandLine.arguments.count == 2)
        let path = CommandLine.arguments[1]
        precondition(!FileManager.default.fileExists(atPath: path + "/Contents/Resources/AppIcon.icns"))
        let image = AppIcons.load(path: path, style: "Original")
        func pixel(_ appearance: NSAppearance.Name) -> NSColor {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance { image.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64)) }
            NSGraphicsContext.restoreGraphicsState()
            return bitmap.colorAt(x: 32, y: 32)!.usingColorSpace(.deviceRGB)!
        }
        let light = pixel(.aqua), dark = pixel(.darkAqua)
        precondition(light.redComponent > 0.7 && light.greenComponent < 0.4, "light asset not selected")
        precondition(dark.greenComponent > 0.5 && dark.redComponent < 0.4, "dark asset not selected")
        print("PASS: asset-catalog icon without icns follows light and dark appearance")
    }
}
