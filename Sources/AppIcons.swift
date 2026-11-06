import AppKit

enum AppIcons {
    static func load(path: String, style: String) -> NSImage {
        if style == "Original", let bundle = Bundle(url: URL(fileURLWithPath: path)) {
            let legacyName = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String
            if let name = legacyName, !name.isEmpty {
                let file = name.hasSuffix(".icns") ? name : name + ".icns"
                if let resources = bundle.resourceURL, let icon = NSImage(contentsOf: resources.appendingPathComponent(file)) { return icon }
            }
            // App icons compiled into Assets.car use the bundle's declared asset name.
            let iconDict = bundle.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
            let primary = iconDict?["CFBundlePrimaryIcon"] as? [String: Any]
            let catalogName = (bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String) ?? (primary?["CFBundleIconName"] as? String) ?? legacyName
            if let name = catalogName, !name.isEmpty {
                let resourceName = name.hasSuffix(".icns") ? String(name.dropLast(5)) : name
                if let image = bundle.image(forResource: NSImage.Name(resourceName)) { return image }
            }
        }
        return NSWorkspace.shared.icon(forFile: path)
    }
}
