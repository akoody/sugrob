import AppKit
import CoreGraphics

struct WindowInfo {
    let id: CGWindowID
    let frame: CGRect   // global, top-left origin
}

/// Reads window geometry only. No titles, no contents, so macOS asks for no permissions.
final class WindowTracker {
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Reads the CF structures directly. Bridging every dictionary to Swift was the single
    /// largest cost on the main thread.
    func visibleWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) else { return [] }
        var result: [WindowInfo] = []
        var owners: [Int] = []
        for i in 0..<CFArrayGetCount(list) {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(list, i), to: CFDictionary.self)
            let pid = int(d, kCGWindowOwnerPID) ?? -1
            guard int(d, kCGWindowLayer) == 0, pid != Int(ownPID) else { continue }
            guard let bounds = value(d, kCGWindowBounds) else { continue }
            let rect = CGRect(dictionaryRepresentation: unsafeBitCast(bounds, to: CFDictionary.self)) ?? .zero
            guard rect.width >= 100, rect.height >= 50, let id = int(d, kCGWindowNumber) else { continue }
            if let alpha = value(d, kCGWindowAlpha) {
                var a = 1.0
                CFNumberGetValue(unsafeBitCast(alpha, to: CFNumber.self), .doubleType, &a)
                if a <= 0.05 { continue }
            }
            result.append(WindowInfo(id: CGWindowID(id), frame: rect))
            owners.append(pid)
        }
        // Two windows of one app with the very same frame are invisible helper layers, not something
        // a person sees as a window. Snow on them would hang in mid-air.
        var twins = Set<Int>()
        for i in result.indices {
            for j in result.indices where j > i && owners[i] == owners[j] && result[i].frame == result[j].frame {
                twins.insert(i)
                twins.insert(j)
            }
        }
        if !twins.isEmpty { result = result.indices.filter { !twins.contains($0) }.map { result[$0] } }
        return result
    }

    private func value(_ d: CFDictionary, _ key: CFString) -> UnsafeRawPointer? {
        CFDictionaryGetValue(d, unsafeBitCast(key, to: UnsafeRawPointer.self))
    }

    private func int(_ d: CFDictionary, _ key: CFString) -> Int? {
        guard let v = value(d, key) else { return nil }
        var n: Int64 = 0
        CFNumberGetValue(unsafeBitCast(v, to: CFNumber.self), .sInt64Type, &n)
        return Int(n)
    }

    /// Windows on another Space or minimized still exist, and their snow is kept for later.
    func allWindowIDs() -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return Set(list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
    }
}

/// macOS exposes the Dock's height but not its width, so the width is estimated from Dock preferences.
enum DockEstimator {
    static func width() -> Float? {
        guard let d = UserDefaults.standard.persistentDomain(forName: "com.apple.dock") else { return nil }
        if (d["orientation"] as? String ?? "bottom") != "bottom" { return nil }
        let tile = (d["tilesize"] as? Double) ?? 48
        let apps = (d["persistent-apps"] as? [[String: Any]]) ?? []
        let others = (d["persistent-others"] as? [Any])?.count ?? 0
        let recents = (d["show-recents"] as? Bool ?? true) ? ((d["recent-apps"] as? [Any])?.count ?? 0) : 0
        var pinned = Set<String>()
        for a in apps {
            if let t = a["tile-data"] as? [String: Any], let b = t["bundle-identifier"] as? String { pinned.insert(b) }
        }
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !pinned.contains($0.bundleIdentifier ?? "") && $0.bundleIdentifier != "com.apple.finder"
        }.count
        let extra = max(0, running - recents)
        let tiles = apps.count + others + recents + extra + 2   // Finder and Trash
        let separators = 2
        return Float(Double(tiles) * tile + Double(separators) * tile * 0.3 + 28)
    }
}
