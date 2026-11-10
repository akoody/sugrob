import Foundation
import Combine

/// Bumped when defaults change so much that old values would misrepresent the app.
private let settingsVersion = 4

private let store: UserDefaults = {
    let d = UserDefaults.standard
    let stored = d.integer(forKey: "settingsVersion")
    d.removeObject(forKey: "fallingSnow")
    if stored < 3 {
        let old = ["enabled", "fallingSnow", "intensity", "wind", "flakeSize", "accumulation", "maxDrift", "frost",
                   "snowOnWindows", "flakesOverWindows", "driftsOverWindows", "cursorInteraction", "icicles", "aurora",
                   "visitors", "sounds", "ambience", "hideInFullscreen", "batterySaver", "performance", "welcomed"]
        old.forEach { d.removeObject(forKey: $0) }
    }
    if stored < settingsVersion { d.set(settingsVersion, forKey: "settingsVersion") }
    return d
}()

private func loadF(_ key: String, _ fallback: Float) -> Float {
    store.object(forKey: key) == nil ? fallback : store.float(forKey: key)
}
private func loadB(_ key: String, _ fallback: Bool) -> Bool {
    store.object(forKey: key) == nil ? fallback : store.bool(forKey: key)
}

final class Settings: ObservableObject {
    static let shared = Settings()

    @Published var enabled = loadB("enabled", true) { didSet { store.set(enabled, forKey: "enabled") } }
    @Published var amount = loadF("amount", 0.5) { didSet { store.set(amount, forKey: "amount") } }
    @Published var garland = loadB("garland", true) { didSet { store.set(garland, forKey: "garland") } }
    @Published var tree = loadB("tree", true) { didSet { store.set(tree, forKey: "tree") } }
    @Published var snowOnWindows = loadB("snowOnWindows", true) { didSet { store.set(snowOnWindows, forKey: "snowOnWindows") } }
}

enum Tool: Int, CaseIterable, Identifiable {
    case snowball, snowman
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .snowball: return L("Снежки", "Snowballs")
        case .snowman: return L("Снеговик", "Snowman")
        }
    }
    var hint: String {
        switch self {
        case .snowball: return L("Зажми и брось рывком", "Hold and fling")
        case .snowman: return L("Катай ком по снегу и клади на другой. Три кома — снеговик", "Roll balls through snow and stack three")
        }
    }
}

final class PlayState: ObservableObject {
    static let shared = PlayState()
    @Published var active = false
    @Published var tool: Tool = .snowman
}

enum NewYear {
    static func days(from now: Date = Date()) -> Int {
        let cal = Calendar.current
        let year = cal.component(.year, from: now) + 1
        let target = cal.date(from: DateComponents(year: year, month: 1, day: 1))!
        return cal.dateComponents([.day], from: cal.startOfDay(for: now), to: target).day ?? 0
    }

    static func isHoliday(_ now: Date = Date()) -> Bool {
        let cal = Calendar.current
        return cal.component(.month, from: now) == 1 && cal.component(.day, from: now) <= 8
    }

    static func russianDays(_ n: Int) -> String {
        let tens = n % 100, ones = n % 10
        if (11...14).contains(tens) { return "\(n) дней" }
        if ones == 1 { return "\(n) день" }
        if (2...4).contains(ones) { return "\(n) дня" }
        return "\(n) дней"
    }

    static func caption(_ now: Date = Date()) -> String {
        if isHoliday(now) { return L("С Новым годом!", "Happy New Year!") }
        let n = days(from: now)
        return L("До Нового года \(russianDays(n))", n == 1 ? "1 day to New Year" : "\(n) days to New Year")
    }
}
