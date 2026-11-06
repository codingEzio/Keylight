import Foundation

enum AppClassification {
    static func backgroundOnly(path: String) -> Bool {
        (Bundle(url: URL(fileURLWithPath: path))?.infoDictionary?["LSBackgroundOnly"] as? NSNumber)?.boolValue ?? false
    }
    static func installerName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("install") || lower.hasPrefix("setup") || lower.range(of: "(^|[^a-z])(install|installer)([^a-z]|$)|^setup([^a-z]|$)", options: .regularExpression) != nil || lower.contains("安装") || lower.contains("安裝")
    }
}
