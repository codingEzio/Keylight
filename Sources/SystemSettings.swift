import Foundation
import AppKit
import ApplicationServices

// One catalog is shared by the launcher and CLI. IDs are macOS Settings extension IDs.
struct SystemSetting {
    let id: String
    let title: String
    let symbol: String
    let aliases: [String]
    var name: String { NSLocalizedString(title, comment: "System Settings destination") }
    var url: URL { URL(string: "x-apple.systempreferences:" + id)! }
}

enum SystemSettings {
    // OS-provided labels extend search to other installed system languages. The
    // stable URL never depends on translated UI text; missing tables are optional.
    static func localizedAliases(table: URL, key: String, preferredLanguages: [String] = Locale.preferredLanguages) -> [String] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: table.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= 2_000_000,
              let data = try? Data(contentsOf: table),
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return [] }
        let locales = Bundle.preferredLocalizations(from: Array(root.keys), forPreferences: preferredLanguages)
        return Array(Set(locales.compactMap { (root[$0] as? [String: Any])?[key] as? String }.filter { !$0.isEmpty })).sorted()
    }
    static let destinations: [SystemSetting] = [
        .init(id: "com.apple.Wallpaper-Settings.extension", title: "Wallpaper", symbol: "photo", aliases: ["wallpaper", "desktop background", "桌布", "壁纸"]),
        .init(id: "com.apple.LoginItems-Settings.extension", title: "Login Items & Extensions", symbol: "list.bullet", aliases: ["login items", "startup", "启动项", "登入項目", "登录项"]),
        .init(id: "com.apple.Desktop-Settings.extension?default-web-browser", title: "Default Web Browser", symbol: "globe", aliases: ["default browser", "browser", "default web browser", "默认浏览器", "默认网页浏览器", "預設瀏覽器", "預設網頁瀏覽器"] + localizedAliases(table: URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions/DesktopSettings.appex/Contents/Resources/Localizable.loctable"), key: "Default web browser")),
        .init(id: "com.apple.ControlCenter-Settings.extension", title: "Menu Bar App Visibility", symbol: "menubar.rectangle", aliases: ["menu bar", "menu bar controls", "menu bar apps", "hide menu bar apps", "菜单栏", "菜单栏应用", "菜单栏控制", "選單列", "選單列控制項目"] + localizedAliases(table: URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions/ControlCenterSettings.appex/Contents/Resources/Localizable.loctable"), key: "Menu Bar Controls…"))
    ]
    static func find(_ id: String) -> SystemSetting? { destinations.first { $0.id == id } }
}

// System Settings exposes the menu-bar list as a sheet, not a URL. Match only
// the exact system-provided label, regardless of the user's system language.
enum SettingsNavigator {
    static let browserID = "com.apple.Desktop-Settings.extension?default-web-browser"
    static let menuID = "com.apple.ControlCenter-Settings.extension"
    static var needsAccessibility: (SystemSetting) -> Bool = { $0.id == browserID || $0.id == menuID }

    static func requestAccessIfNeeded() -> Bool {
        if AXIsProcessTrusted() { return true }
        let key = "settingsAccessibilityRequested"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        return false
    }

    static func navigate(_ setting: SystemSetting) -> Bool {
        let table = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions/ControlCenterSettings.appex/Contents/Resources/Localizable.loctable")
        let labels: Set<String> = {
            guard let data = try? Data(contentsOf: table),
                  let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return [] }
            return Set(root.values.compactMap { ($0 as? [String: Any])?["Menu Bar Controls…"] as? String })
        }()
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first {
                let root = AXUIElementCreateApplication(app.processIdentifier)
                var queue = [root]
                var matches: [AXUIElement] = []
                var index = 0
                while index < queue.count && index < 2000 {
                    let element = queue[index]; index += 1
                    func string(_ attribute: CFString) -> String? {
                        var value: CFTypeRef?
                        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
                        return value as? String
                    }
                    let role = string(kAXRoleAttribute as CFString)
                    if setting.id == browserID {
                        if role == kAXPopUpButtonRole as String && string(kAXIdentifierAttribute as CFString) == "default-web-browser" { matches.append(element) }
                    } else if role == kAXButtonRole as String && [string(kAXTitleAttribute as CFString), string(kAXDescriptionAttribute as CFString)].compactMap({ $0 }).contains(where: { labels.contains($0) }) {
                        matches.append(element)
                    }
                    var children: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success, let values = children as? [AXUIElement] { queue.append(contentsOf: values) }
                }
                if matches.count == 1 && AXUIElementPerformAction(matches[0], kAXPressAction as CFString) == .success { return true }
                if matches.count > 1 { return false }
            }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline
        return false
    }
}
