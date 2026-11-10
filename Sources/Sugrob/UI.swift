import AppKit
import Combine
import ServiceManagement
import SwiftUI

// MARK: Menu bar panel

struct PanelRow: View {
    let title: String
    var shortcut: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let shortcut { Text(shortcut).font(.system(size: 11)).foregroundStyle(.tertiary) }
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.mini)
        }
        .frame(height: 24)
    }
}

/// What Sugrob has cost the processor today. Kept across restarts so the number stays honest.
final class DailyLoad {
    static let shared = DailyLoad()
    private let d = UserDefaults.standard
    private var lastCPU = DailyLoad.cpuSeconds()
    private var lastTime = CACurrentMediaTime()

    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1_000_000
    }

    private var dayKey: String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    /// Adds what was used since the last call to today's totals.
    func flush() {
        let cpu = DailyLoad.cpuSeconds(), now = CACurrentMediaTime()
        let sameDay = d.string(forKey: "loadDay") == dayKey
        d.set(dayKey, forKey: "loadDay")
        d.set((sameDay ? d.double(forKey: "loadCPU") : 0) + cpu - lastCPU, forKey: "loadCPU")
        d.set((sameDay ? d.double(forKey: "loadWall") : 0) + now - lastTime, forKey: "loadWall")
        lastCPU = cpu
        lastTime = now
    }

    func summary() -> String {
        flush()
        let cpu = Int(d.double(forKey: "loadCPU").rounded()), minutes = Int(d.double(forKey: "loadWall") / 60)
        let h = minutes / 60, m = minutes % 60
        if isRussian {
            let c = cpu < 60 ? "\(cpu) с" : "\(cpu / 60) мин \(cpu % 60) с"
            let w = h > 0 ? "\(h) ч \(m) мин" : "\(m) мин"
            return "Сегодня: \(c) процессора за \(w)"
        }
        let c = cpu < 60 ? "\(cpu) s" : "\(cpu / 60) min \(cpu % 60) s"
        let w = h > 0 ? "\(h) h \(m) min" : "\(m) min"
        return "Today: \(c) of CPU in \(w)"
    }
}

/// Sugrob's own CPU use, measured only while the panel is open.
final class LoadMeter: ObservableObject {
    @Published var percent: Double?
    @Published var today = ""
    private var timer: Timer?
    private var lastCPU = 0.0
    private var lastTime = 0.0

    private func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1_000_000
    }

    func start() {
        today = DailyLoad.shared.summary()
        lastCPU = cpuSeconds()
        lastTime = CACurrentMediaTime()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let cpu = self.cpuSeconds(), now = CACurrentMediaTime()
            self.percent = (cpu - self.lastCPU) / max(now - self.lastTime, 0.01) * 100
            self.lastCPU = cpu
            self.lastTime = now
            self.today = DailyLoad.shared.summary()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        percent = nil
    }
}

struct SettingsView: View {
    @ObservedObject var s = Settings.shared
    @StateObject private var load = LoadMeter()
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sugrob").font(.system(size: 14, weight: .semibold))
                Spacer()
                Toggle("", isOn: $s.enabled).toggleStyle(.switch).labelsHidden().controlSize(.small)
                Button { (NSApp.delegate as? AppDelegate)?.closeMenu() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Закрыть (Esc)", "Close (Esc)"))
            }

            HStack {
                Text(NewYear.caption()).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button(L("Салют", "Fireworks")) { Coordinator.shared.celebrate(seconds: 8) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(load.today)
                if let p = load.percent {
                    Text(L("Сейчас: \(String(format: "%.1f", p))% одного ядра", "Now: \(String(format: "%.1f", p))% of one core"))
                }
            }
            .font(.system(size: 11)).foregroundStyle(.tertiary)

            Divider()

            VStack(spacing: 2) {
                PanelRow(title: L("Гирлянда", "Garland"), isOn: $s.garland)
                PanelRow(title: L("Ёлка", "Tree"), isOn: $s.tree)
                PanelRow(title: L("Снег на окнах", "Snow on windows"), isOn: $s.snowOnWindows)
            }

            HStack(spacing: 10) {
                Text(L("Высота сугробов", "Drift height"))
                Slider(value: $s.amount, in: 0...1).controlSize(.mini)
            }
            .frame(height: 24)

            Divider()

            Button { Coordinator.shared.setPlay(true) } label: {
                HStack {
                    Text(L("Лепить снеговика", "Build a snowman"))
                    Spacer()
                    Text("⌃⌥S").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .frame(height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { Coordinator.shared.clearSnowmen() } label: {
                Text(L("Убрать снеговиков", "Remove snowmen")).frame(maxWidth: .infinity, minHeight: 24, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()

            PanelRow(title: L("Запускать при входе", "Launch at login"), isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { on in
                    if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                }

            HStack {
                Button(L("Выйти", "Quit")) { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Text("v\(appVersion)").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 13))
        .padding(14)
        .frame(width: 264)
        .onAppear { load.start() }
        .onDisappear { load.stop() }
    }
}

// MARK: Play bar

struct PlayBar: View {
    @ObservedObject var play = PlayState.shared

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(Tool.allCases) { tool in
                    let selected = play.tool == tool
                    Button { Coordinator.shared.select(tool) } label: {
                        Text(tool.title)
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(selected ? 1 : 0.6))
                            .padding(.horizontal, 14).frame(height: 30)
                            .background(Capsule().fill(Color.white.opacity(selected ? 0.18 : 0)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1, height: 16).padding(.horizontal, 6)
                Button { Coordinator.shared.setPlay(false) } label: {
                    Text(L("Готово", "Done")).font(.system(size: 13)).foregroundStyle(.white)
                        .padding(.horizontal, 12).frame(height: 30).contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(4)
            .background(Capsule().fill(Color.black.opacity(0.72)))

            Text(play.tool.hint).font(.system(size: 11)).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.5)))
        }
        .fixedSize()
    }
}

final class PlayHUD {
    private var panel: NSPanel?

    func show(on screen: NSScreen?) {
        guard let screen else { return }
        panel = makePanel(PlayBar(), on: screen, ignoresMouse: false)
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}

func makePanel<V: View>(_ view: V, on screen: NSScreen, ignoresMouse: Bool) -> NSPanel {
    let host = NSHostingView(rootView: view)
    let size = host.fittingSize
    let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.minY + 18)
    let p = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = false
    p.ignoresMouseEvents = ignoresMouse
    p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    p.isReleasedWhenClosed = false
    p.contentView = host
    p.orderFrontRegardless()
    return p
}

/// Brief confirmation for actions taken without the panel open.
enum Toast {
    private static var panel: NSPanel?
    private static var hide: DispatchWorkItem?

    private static func dismiss() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    static func show(_ text: String, seconds: Double = 1.4) {
        hide?.cancel()
        dismiss()
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.screens.first else { return }
        let card = Text(text).font(.system(size: 13)).foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(Capsule().fill(Color.black.opacity(0.72)))
            .fixedSize()
        panel = makePanel(card, on: screen, ignoresMouse: true)
        let work = DispatchWorkItem { dismiss() }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

enum Welcome {
    static func showIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "welcomed") else { return }
        UserDefaults.standard.set(true, forKey: "welcomed")
        Toast.show(L("С наступающим! Настройки — под снежинкой в строке меню", "Happy holidays! Settings live under the snowflake in the menu bar"), seconds: 6)
    }
}

// MARK: App

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let popover = NSPopover()
    private var item: NSStatusItem!
    private var bag = Set<AnyCancellable>()
    private var outsideClicks: Any?
    private var escapeKey: Any?
    private var lastClosed: CFTimeInterval = 0

    func setupMenu() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = item.button {
            b.image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Sugrob")
            b.target = self
            b.action = #selector(toggle)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.toolTip = L("Щелчок: настройки. Правый щелчок: включить или выключить снег", "Click for settings. Right-click toggles the snow")
        }
        let s = Settings.shared
        s.$enabled.sink { [weak self] enabled in
            self?.item.button?.appearsDisabled = !enabled
        }.store(in: &bag)
        popover.behavior = .transient
        // Closing must take effect at once, or the next click lands while it still counts as shown.
        popover.animates = false
        popover.delegate = self
        // Without this the panel opens at a guessed height and grows past the top of the screen.
        let hosting = NSHostingController(rootView: SettingsView())
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
    }

    func applicationWillTerminate(_ n: Notification) {
        DailyLoad.shared.flush()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        setupMenu()
        Coordinator.shared.start()
        Welcome.showIfNeeded()
    }

    @objc func toggle() {
        if let e = NSApp.currentEvent, e.type == .rightMouseUp || e.modifierFlags.contains(.control) {
            closeMenu()
            Coordinator.shared.toggleSnow()
            return
        }
        if popover.isShown {
            closeMenu()
        } else if CACurrentMediaTime() - lastClosed > 0.3 {
            showMenu()
        }
    }

    func showMenu() {
        guard let b = item.button, !popover.isShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        if let v = popover.contentViewController?.view {
            v.layoutSubtreeIfNeeded()
            popover.contentSize = v.fittingSize
        }
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        // macOS may not give a menu bar app focus, and then a transient popover misses outside clicks.
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.closeMenu()
        }
        escapeKey = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 53 else { return e }
            self?.closeMenu()
            return nil
        }
        Coordinator.shared.setMenuEscape(true)
    }

    func closeMenu() {
        if popover.isShown { popover.close() }
        menuClosed()
    }

    func popoverDidClose(_ notification: Notification) { menuClosed() }

    private func menuClosed() {
        guard outsideClicks != nil || escapeKey != nil else { return }
        lastClosed = CACurrentMediaTime()
        if let m = outsideClicks { NSEvent.removeMonitor(m) }
        if let m = escapeKey { NSEvent.removeMonitor(m) }
        outsideClicks = nil
        escapeKey = nil
        Coordinator.shared.setMenuEscape(false)
    }
}
