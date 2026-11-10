import AppKit
import Carbon.HIToolbox
import Combine
import IOKit.ps
import simd

private var hotKeyHandler: ((UInt32) -> Void)?

/// Owns the frame clock and decides how little work each moment needs.
/// The rule: a calm scene is a still picture and costs nothing. Frames are drawn only while something moves.
final class Coordinator {
    static let shared = Coordinator()

    private(set) var overlays: [Overlay] = []
    private let tracker = WindowTracker()
    private let settings = Settings.shared
    private let play = PlayState.shared
    private var housekeeping: Timer?
    private var dragWatch: Timer?
    private var monitors: [Any] = []
    private var lastGlobal = CACurrentMediaTime()
    private var mouse = V2.zero
    private var lastPoll = CACurrentMediaTime()
    private var lastBars = CACurrentMediaTime()
    private var lastPower = CACurrentMediaTime() - 100
    private var lastMove: CFTimeInterval = 0
    private var lastInput = CACurrentMediaTime()
    private var lastFlush = CACurrentMediaTime()
    private var onBattery = false
    private var screenAsleep = false
    private var locked = false
    private var asleep: Bool { screenAsleep || locked }
    private var previousMouse = V2.zero
    private(set) var velocity = V2.zero
    private var previousApp: NSRunningApplication?
    private var bag = Set<AnyCancellable>()
    private let hud = PlayHUD()
    private let signature = OSType(0x53475242)   // 'SGRB'
    private var playKeys: [EventHotKeyRef] = []
    private var menuEscape: EventHotKeyRef?
    private(set) var hotKeysRegistered = false
    private var currentYear = Calendar.current.component(.year, from: Date())
    private var lastWindowMove: CFTimeInterval = 0
    private var pollRequested = true
    private var barsRequested = false
    private var nextGustAt = CACurrentMediaTime() + 6
    /// Seconds without any input before the lights freeze and the wind stops.
    var deepIdleAfter: Double = ProcessInfo.processInfo.environment["SUGROB_REST_AFTER"].flatMap(Double.init) ?? 300
    /// True while nobody is at the Mac or it is running hot.
    private(set) var resting = false
    /// True while the rest of the Mac is working hard. The wind waits for it to finish.
    private(set) var systemBusy = false
    private var lastTicks: (busy: UInt32, total: UInt32)?

    func start() {
        rebuild()
        installHotKeys()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.screenAsleep = true; self?.applyEnabled() }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.screenAsleep = false; self?.applyEnabled() }
        let dn = DistributedNotificationCenter.default()
        dn.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.locked = true; self?.applyEnabled() }
        dn.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.locked = false; self?.applyEnabled() }
        // Windows are re-read when something can have changed instead of constantly.
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.pollSoon() }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.barsRequested = true
                self?.pollSoon()
            }
        }
        // Mouse monitors need no permission. They are what lets a calm scene draw nothing at all.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in self?.pointerMoved() }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in self?.buttonDown() }) { monitors.append(m) }

        settings.$enabled.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.applyEnabled() }.store(in: &bag)
        settings.$garland.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.redrawAll() }.store(in: &bag)
        settings.$tree.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.redrawAll() }.store(in: &bag)
        settings.$snowOnWindows.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.redrawAll() }.store(in: &bag)
        settings.$amount.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.redrawAll() }.store(in: &bag)
        applyEnabled()
    }

    private func rebuild() {
        if play.active { setPlay(false) }
        overlays.forEach { $0.close() }
        overlays = NSScreen.screens.enumerated().map { Overlay(screen: $1, primary: $0 == 0, coordinator: self) }
        for o in overlays {
            o.startClock { [weak self, weak o] dt in
                guard let self, let o else { return }
                self.frame(o, dt: dt)
            }
        }
        pollWindows(CACurrentMediaTime())
    }

    private var running: Bool { settings.enabled && !asleep }

    private func wake(_ o: Overlay) {
        if running { o.clockPaused = false }
    }

    /// The picture changed without anything moving, so every display draws at least one new frame.
    private func redrawAll() {
        pollRequested = true
        for o in overlays {
            o.world.needsRedraw = true
            o.syncLights()
            wake(o)
        }
    }

    private func pollSoon() {
        pollRequested = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.pollRequested, self.running else { return }
            self.globalUpdate(CACurrentMediaTime())
        }
    }

    private func applyEnabled() {
        let on = running
        overlays.forEach {
            on ? $0.window.orderFrontRegardless() : $0.window.orderOut(nil)
            if on {
                $0.world.needsRedraw = true
                $0.clockPaused = false
            } else {
                $0.clockPaused = true
            }
        }
        housekeeping?.invalidate()
        housekeeping = nil
        if on {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.slowTick() }
            t.tolerance = 0.3
            RunLoop.main.add(t, forMode: .common)
            housekeeping = t
            pollRequested = true
        } else if play.active {
            setPlay(false)
        }
    }

    static func globalMouse() -> V2 {
        let loc = NSEvent.mouseLocation
        return V2(Float(loc.x), Float(NSScreen.screens.first?.frame.height ?? 0) - Float(loc.y))
    }

    /// Runs on every mouse move, so it only does a bounds check.
    private func pointerMoved() {
        guard running, !play.active else { return }
        let g = Coordinator.globalMouse()
        for o in overlays where !o.world.hidden && o.world.isNearSnow(global: g) {
            lastMove = CACurrentMediaTime()
            wake(o)
        }
    }

    /// A window can only be dragged while a button is down, so that is the only time windows are watched closely.
    private func buttonDown() {
        guard running, dragWatch == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.dragTick() }
        RunLoop.main.add(t, forMode: .common)
        dragWatch = t
    }

    private func dragTick() {
        let now = CACurrentMediaTime()
        if NSEvent.pressedMouseButtons == 0 {
            dragWatch?.invalidate()
            dragWatch = nil
            pollRequested = true
        }
        if running { globalUpdate(now) }
    }

    private func slowTick() {
        let now = CACurrentMediaTime()
        updateResting(now)
        if now - lastFlush > 300 {
            lastFlush = now
            DailyLoad.shared.flush()
        }
        if resting {
            checkNewYear()
            return
        }
        updateBusy()
        if now - lastGlobal > 0.4 { globalUpdate(now) }
        if now >= nextGustAt {
            nextGustAt = now + Double(saving ? rnd(40, 70) : rnd(25, 50))
            if !systemBusy && !play.active { gustNow() }
        }
        for o in overlays where !o.world.hidden && !o.world.settled { wake(o) }
    }

    func gustNow() {
        for o in overlays where !o.world.hidden {
            o.world.startGust()
            wake(o)
        }
    }

    private var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private var overheated: Bool {
        let t = ProcessInfo.processInfo.thermalState
        return t == .serious || t == .critical
    }

    private func updateResting(_ now: CFTimeInterval) {
        let should = !play.active && !overlays.contains { $0.world.fireworks > 0 } && (idleSeconds > deepIdleAfter || overheated)
        guard should != resting else { return }
        resting = should
        overlays.forEach { $0.setLightsAnimating(!should) }
        if !should { pollRequested = true }
    }

    /// Whole-machine CPU use since the last call, from the kernel's tick counters.
    private func updateBusy() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return }
        let busy = info.cpu_ticks.0 &+ info.cpu_ticks.1 &+ info.cpu_ticks.3
        let total = busy &+ info.cpu_ticks.2
        if let last = lastTicks {
            let dTotal = total &- last.total
            if dTotal > 0 { systemBusy = Double(busy &- last.busy) / Double(dTotal) > 0.7 }
        }
        lastTicks = (busy, total)
    }

    private func checkNewYear() {
        let year = Calendar.current.component(.year, from: Date())
        guard year != currentYear else { return }
        currentYear = year
        celebrate(seconds: 75)
    }

    private var saving: Bool {
        onBattery || ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState != .nominal
    }

    private func pollWindows(_ now: CFTimeInterval) {
        let infos = tracker.visibleWindows()
        let dt = Float(now - lastPoll)
        lastPoll = now
        var cached: Set<CGWindowID>?
        let existing: () -> Set<CGWindowID> = { [tracker] in
            if let c = cached { return c }
            let s = tracker.allWindowIDs()
            cached = s
            return s
        }
        for o in overlays {
            let fullscreen = o.world.syncWindows(infos, pollDt: dt, existing: existing)
            let hidden = fullscreen && !play.active
            let changed = hidden != o.world.hidden
            o.world.hidden = hidden
            if o.world.windowMoved {
                o.world.windowMoved = false
                lastWindowMove = now
            }
            if changed {
                o.world.needsRedraw = true
                o.syncLights()
            }
            if changed || !o.world.settled { wake(o) }
        }
    }

    private func updatePower() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else {
            onBattery = false
            return
        }
        onBattery = (source as String) == "Battery Power"
    }

    private func globalUpdate(_ now: CFTimeInterval) {
        let dt = max(Float(now - lastGlobal), 0.001)
        lastGlobal = now

        mouse = Coordinator.globalMouse()
        let raw = (mouse - previousMouse) / dt
        if mouse != previousMouse { lastMove = now }
        previousMouse = mouse
        velocity += (raw - velocity) * min(1, dt * 16)

        // Close watching only while a window is really moving. A held button alone gets a light check.
        let pressed = NSEvent.pressedMouseButtons != 0
        let interval: CFTimeInterval = !pressed ? 2 : (now - lastWindowMove < 0.5 ? 0.03 : 0.09)
        if pollRequested || now - lastPoll >= interval {
            pollRequested = false
            pollWindows(now)
        }
        if barsRequested || now - lastBars > 20 {
            barsRequested = false
            lastBars = now
            overlays.forEach { $0.world.refreshBars() }
            checkNewYear()
        }
        if now - lastPower > 20 {
            lastPower = now
            updatePower()
        }
        if play.active && now - lastInput > 120 { setPlay(false) }

        let lively = play.active || now - lastWindowMove < 0.4 || now - lastMove < 0.6 || overlays.contains { $0.world.fireworks > 0 }
        let slow = overlays.allSatisfy { $0.world.hidden || $0.world.onlySlowMotion }
        let fps: Float = lively ? (saving ? 30 : 60) : (slow ? 10 : (saving ? 20 : 24))
        overlays.forEach { $0.setFrameRate(fps) }
    }

    private func frame(_ o: Overlay, dt: Float) {
        let now = CACurrentMediaTime()
        if now - lastGlobal > 0.007 { globalUpdate(now) }
        if o.world.hidden {
            // One clearing frame, then this display costs nothing until it is visible again.
            if o.renderer.clearedWhileHidden { o.clockPaused = true } else { o.view.draw() }
            return
        }
        let info = FrameInfo(dt: dt, mouse: mouse, mouseVelocity: velocity, play: play.active, tool: play.tool)
        o.world.update(info)
        o.view.draw()
        o.syncLights()
        // Nothing left in motion: stop drawing. The last frame stays on screen as a still picture.
        let engaged = play.active || now - lastWindowMove < 0.4 || (now - lastMove < 0.6 && o.world.pointerNearSnow)
        if !engaged && o.world.settled { o.clockPaused = true }
    }

    private func overlayUnderCursor() -> Overlay? {
        overlays.first { $0.world.pointerInside } ?? overlays.first
    }

    // MARK: Actions

    func noteInput() { lastInput = CACurrentMediaTime() }

    func select(_ tool: Tool) {
        play.tool = tool
        overlays.forEach { $0.window.invalidateCursorRects(for: $0.view) }
    }

    func setPlay(_ on: Bool) {
        guard on != play.active else { return }
        if on {
            guard settings.enabled else { return }
            (NSApp.delegate as? AppDelegate)?.closeMenu()
            previousApp = NSWorkspace.shared.frontmostApplication
            play.active = true
            lastInput = CACurrentMediaTime()
            registerPlayKeys()
            NSApp.activate(ignoringOtherApps: true)
            overlays.forEach {
                $0.setInteractive(true)
                wake($0)
            }
            let target = overlayUnderCursor() ?? overlays.first
            target?.window.makeKeyAndOrderFront(nil)
            target?.window.makeFirstResponder(target?.view)
            hud.show(on: target?.world.screen ?? NSScreen.main)
        } else {
            play.active = false
            unregisterPlayKeys()
            overlays.forEach {
                $0.setInteractive(false)
                $0.world.held = nil
                $0.world.dropCarried()
                $0.world.grabbed = nil
                $0.world.needsRedraw = true
                wake($0)
            }
            hud.hide()
            previousApp?.activate(options: [])
        }
    }

    func toggleSnow() {
        settings.enabled.toggle()
        Toast.show(settings.enabled ? L("Снег включён", "Snow on") : L("Снег выключен", "Snow off"))
    }

    func celebrate(seconds: Float) {
        guard let o = overlays.first else { return }
        o.world.startFireworks(seconds: seconds)
        wake(o)
    }

    func clearSnowmen() {
        overlays.forEach {
            $0.world.clearSnowmen()
            wake($0)
        }
    }

    // MARK: Hotkeys (Carbon needs no Accessibility permission)

    private func installHotKeys() {
        hotKeyHandler = { [weak self] id in
            guard let self else { return }
            switch id {
            case 1: self.setPlay(!self.play.active)
            case 2: self.settings.enabled.toggle()
            case 10: self.setPlay(false)
            case 11, 12: self.select(Tool(rawValue: Int(id) - 11) ?? .snowman)
            case 20: (NSApp.delegate as? AppDelegate)?.closeMenu()
            default: break
            }
        }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            hotKeyHandler?(hk.id)
            return noErr
        }, 1, &spec, nil, nil)

        let mods = UInt32(controlKey | optionKey)
        var a: EventHotKeyRef?, b: EventHotKeyRef?
        let s1 = RegisterEventHotKey(UInt32(kVK_ANSI_S), mods, EventHotKeyID(signature: signature, id: 1), GetApplicationEventTarget(), 0, &a)
        let s2 = RegisterEventHotKey(UInt32(kVK_ANSI_D), mods, EventHotKeyID(signature: signature, id: 2), GetApplicationEventTarget(), 0, &b)
        hotKeysRegistered = s1 == noErr && s2 == noErr
    }

    /// Esc and 1-2 are global only while playing, so leaving the game never depends on window focus.
    private func registerPlayKeys() {
        for (code, id) in [(kVK_Escape, UInt32(10)), (kVK_ANSI_1, 11), (kVK_ANSI_2, 12)] {
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(UInt32(code), 0, EventHotKeyID(signature: signature, id: id), GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                playKeys.append(ref)
            }
        }
    }

    private func unregisterPlayKeys() {
        playKeys.forEach { UnregisterEventHotKey($0) }
        playKeys.removeAll()
    }

    var playKeyCount: Int { playKeys.count }

    func setMenuEscape(_ on: Bool) {
        if let ref = menuEscape {
            UnregisterEventHotKey(ref)
            menuEscape = nil
        }
        guard on else { return }
        var ref: EventHotKeyRef?
        if RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: signature, id: 20), GetApplicationEventTarget(), 0, &ref) == noErr {
            menuEscape = ref
        }
    }

    var menuEscapeArmed: Bool { menuEscape != nil }
}
