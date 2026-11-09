import Foundation

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
    static let destinations: [SystemSetting] = [
        .init(id: "com.apple.Wallpaper-Settings.extension", title: "Wallpaper", symbol: "photo", aliases: ["wallpaper", "desktop background", "桌布", "壁纸"]),
        .init(id: "com.apple.LoginItems-Settings.extension", title: "Login Items & Extensions", symbol: "list.bullet", aliases: ["login items", "startup", "启动项", "登入項目", "登录项"])
    ]
    static func find(_ id: String) -> SystemSetting? { destinations.first { $0.id == id } }
}
