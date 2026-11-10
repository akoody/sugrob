import AppKit
import simd

/// Exercises physics and play logic. Run with `Sugrob --selftest` or `--selftest-live`.
enum SelfTest {
    /// Tests run against known settings and always put the person's own settings back.
    private static func isolateSettings() -> () -> Void {
        let d = UserDefaults.standard
        let id = Bundle.main.bundleIdentifier ?? "io.github.sugrob.app"
        let saved = d.persistentDomain(forName: id)
        let known: [String: Any] = ["enabled": true, "amount": 0.5, "garland": true, "tree": true,
                                    "snowOnWindows": true, "settingsVersion": 4, "welcomed": true]
        d.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        d.setVolatileDomain(known, forName: UserDefaults.argumentDomain)
        return { if let saved { d.setPersistentDomain(saved, forName: id) } else { d.removePersistentDomain(forName: id) } }
    }

    private static var failures = 0
    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
        if !ok { failures += 1 }
    }
    private static func finish() -> Int32 {
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }

    static func run() -> Int32 {
        let restore = isolateSettings()
        defer { restore() }
        guard let screen = NSScreen.main else { print("no screen"); return 2 }
        Sound.shared.muted = true

        let world = World(screen: screen, primary: true)
        let renderer = Renderer(world: world)
        world.firstSync = false
        let ox = world.cgFrame.minX, oy = world.cgFrame.minY
        let W = world.size.x, H = world.size.y

        var front = CGRect(x: CGFloat(W * 0.5), y: CGFloat(H * 0.25), width: CGFloat(W * 0.3), height: CGFloat(H * 0.4))
        let back = CGRect(x: CGFloat(W * 0.2), y: CGFloat(H * 0.35), width: CGFloat(W * 0.45), height: CGFloat(H * 0.4))
        var open = true
        func infos() -> [WindowInfo] {
            var list: [WindowInfo] = []
            if open { list.append(WindowInfo(id: 101, frame: front.offsetBy(dx: ox, dy: oy))) }
            list.append(WindowInfo(id: 102, frame: back.offsetBy(dx: ox, dy: oy)))
            return list
        }
        func sync(_ dt: Float = 0.5) { _ = world.syncWindows(infos(), pollDt: dt, existing: { Set(infos().map { $0.id }) }) }
        var info = FrameInfo(dt: 1.0 / 30, mouse: V2(Float(ox) - 500, Float(oy) - 500), mouseVelocity: .zero, play: true, tool: .snowball)
        func step(_ seconds: Float) { for _ in 0..<Int(seconds * 30) { world.update(info) } }
        func aim(_ p: V2) { info.mouse = p + V2(Float(ox), Float(oy)); step(0.04) }

        // A freshly started scene has to become a still picture quickly, or the app would draw forever.
        let fresh = World(screen: screen, primary: true)
        _ = fresh.syncWindows(infos(), pollDt: 0.5, existing: { [] })
        var settleFrames = 0
        while !fresh.settled && settleFrames < 3000 { fresh.update(info); settleFrames += 1 }
        check("a fresh scene settles within two seconds", settleFrames < 60, "\(settleFrames) frames, \(fresh.unsettledReason ?? "still")")

        sync()
        step(30)
        guard let fs = world.windowSurfaces[101], world.windowSurfaces[102] != nil else { print("FAIL  surfaces"); return 1 }
        check("a new window grows snow by itself", fs.maxH > 2, "max \(fs.maxH)")
        check("snow never exceeds its cap", !zip(fs.h, fs.cap).contains { $0 > $1 + 0.01 } && !zip(world.ground.h, world.ground.cap).contains { $0 > $1 + 0.01 })

        let before = fs.h.reduce(0, +)
        front.origin.x += 80
        sync(1.0 / 60)
        check("fast window drag sheds snow", fs.h.reduce(0, +) < before * 0.95)
        check("snow rides along with the window", fs.x == Float(front.minX))
        step(25)
        check("shaken-off snow grows back", fs.h.reduce(0, +) > before * 0.9, "\(before) -> \(fs.h.reduce(0, +))")

        let top = world.addSnowman(on: fs, x: fs.x + 120, R: 28)!
        step(2)
        check("snowman finishes building", top.finished)
        open = false
        sync()
        check("closed window drops its snow", !fs.alive && world.windowSurfaces[101] == nil)
        step(0.2)
        check("snowman falls when its window closes", top.state == .falling)
        step(4)
        check("snowman lands on another surface", top.state == .idle && top.surface != nil)
        world.men.removeAll()

        // Snowballs
        let man = world.addSnowman(on: world.ground, x: 90, R: 40)!
        step(2)
        let target = V2(man.x, man.y + man.y1)
        aim(target - V2(30, 0))
        world.pointerDown(target - V2(30, 0), tool: .snowball)
        step(0.2)
        check("holding the button grows a snowball", (world.held?.r ?? 0) > 8)
        world.pointerUp(target, velocity: V2(1200, 0), tool: .snowball)
        check("release throws the ball", world.balls.count == 1 && world.held == nil)
        step(0.3)
        check("snowball hits a snowman", man.hp == 2, "hp \(man.hp)")
        var throwsLeft = 8
        while world.men.contains(where: { $0 === man }) && throwsLeft > 0 {
            let p = V2(man.x - 30, man.y + man.y1)
            aim(p)
            world.pointerDown(p, tool: .snowball)
            world.pointerUp(p, velocity: V2(1200, 0), tool: .snowball)
            step(0.25)
            throwsLeft -= 1
        }
        check("enough hits destroy a snowman", !world.men.contains { $0 === man })
        world.balls.removeAll()
        aim(V2(W / 2, H / 2))
        let splats = world.splats.count
        world.pointerDown(V2(W / 2, H / 2), tool: .snowball)
        world.pointerUp(V2(W / 2, H / 2), velocity: .zero, tool: .snowball)
        step(0.3)
        check("a click splats on the glass", world.splats.count == splats + 1)

        // Building a snowman by hand
        world.ground.prewarm(0.95, 0.95)
        world.men.removeAll()
        info.tool = .snowman
        func rollBall(from startX: Float, distance: Float) -> Lump? {
            var x = startX
            let y = world.ground.top(at: x)
            world.pointerDown(V2(x, y), tool: .snowman)
            let l = world.carried
            while x < startX + distance {
                world.pointerDragged(from: V2(x, y), to: V2(x + 8, y), velocity: V2(240, 0), tool: .snowman)
                x += 8
            }
            world.pointerUp(V2(x, y), velocity: .zero, tool: .snowman)
            step(0.3)
            return l
        }
        func carry(_ l: Lump, onto t: Lump) {
            guard let from = l.centers().first?.0, let top = t.centers().last else { return }
            world.pointerDown(from, tool: .snowman)
            let above = V2(t.x, top.0.y - top.1 - l.parts[0] * 1.5)
            world.pointerDragged(from: from, to: above, velocity: .zero, tool: .snowman)
            world.pointerUp(above, velocity: .zero, tool: .snowman)
            step(0.1)
        }
        let snowBefore = world.ground.h.reduce(0, +)
        guard let big = rollBall(from: 30, distance: 260) else { print("FAIL  no ball"); return 1 }
        check("rolling grows the ball", big.parts[0] > 28, "r \(big.parts[0])")
        check("rolling consumes snow", world.ground.h.reduce(0, +) < snowBefore)
        check("a released ball stays on the snow", big.state == .idle && world.men.isEmpty)
        guard let middle = rollBall(from: W - 460, distance: 150), let small = rollBall(from: W - 130, distance: 60) else { print("FAIL  no balls"); return 1 }
        check("three separate balls exist", world.lumps.count == 3, "\(world.lumps.count)")
        let c0 = small.centers()[0].0
        world.pointerDown(c0, tool: .snowman)
        world.pointerDragged(from: c0, to: V2(W * 0.2, H * 0.2), velocity: .zero, tool: .snowman)
        check("a lifted ball stops rolling", !small.rolling)
        world.pointerUp(V2(W * 0.2, H * 0.2), velocity: .zero, tool: .snowman)
        check("dropped in the air it falls", small.state == .falling)
        step(4)
        check("then it lands", small.state == .idle)
        carry(middle, onto: big)
        check("two balls stack", world.lumps.count == 2 && big.parts.count == 2 && world.men.isEmpty)
        carry(small, onto: big)
        check("the third ball makes a snowman", world.lumps.isEmpty && world.men.count == 1)
        guard let handmade = world.men.first else { return 1 }
        step(1)
        check("the snowman gets its details", handmade.finished)

        let body = V2(handmade.x, handmade.y + handmade.y1)
        world.pointerDown(body, tool: .snowman)
        check("a snowman can be grabbed", handmade.state == .held)
        world.pointerDragged(from: body, to: V2(W * 0.5, H * 0.3), velocity: .zero, tool: .snowman)
        world.pointerUp(V2(W * 0.5, H * 0.3), velocity: V2(300, -100), tool: .snowman)
        step(4)
        check("a tossed snowman lands", handmade.state == .idle)

        // New Year touches
        check("the garland has bulbs", world.bulbs.count > 10 && world.wire.count > 20, "\(world.bulbs.count)")
        check("the tree stands inside the screen", world.treeX > 40 && world.treeX < W - 40, "x \(world.treeX)")
        if let w = world.dockWidth { check("the tree stands clear of the Dock", world.treeX > (W + w) / 2 + 30) }
        check("a secondary display has no tree of its own", !World(screen: screen, primary: false).primary)
        world.startFireworks(seconds: 1)
        step(1.2)
        check("fireworks send up golden sparks", world.powder.contains { $0.tint.w == 1 && $0.tint.z < 0.9 })
        step(3)
        check("fireworks end and clean up", world.fireworks == 0 && !world.powder.contains { $0.tint.w == 1 && $0.tint.z < 0.9 })
        let cal = Calendar.current
        func date(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d))! }
        check("countdown counts days", NewYear.days(from: date(2026, 12, 31)) == 1 && NewYear.days(from: date(2026, 11, 10)) == 52)
        check("Russian plurals", NewYear.russianDays(1) == "1 день" && NewYear.russianDays(3) == "3 дня" && NewYear.russianDays(11) == "11 дней" && NewYear.russianDays(21) == "21 день")
        check("holiday greeting in January", NewYear.isHoliday(date(2027, 1, 3)) && !NewYear.isHoliday(date(2027, 1, 20)))

        check("all sounds decode", Sound.shared.allSoundsDecode())

        // The tree carries snow until it is touched, then gets it back.
        info.play = false
        check("the tree starts covered in snow", world.treeSnow == [1, 1, 1])
        step(0.1)
        world.powder.removeAll()
        info.mouse = V2(world.treeX + Float(ox), world.ground.top(at: world.treeX) - 50 + Float(oy))
        info.mouseVelocity = V2(300, 0)
        world.update(info)
        check("touching the tree knocks the snow off", world.treeSnow.allSatisfy { $0 == 0 }, "\(world.treeSnow)")
        check("the snow falls as powder", world.powder.count > 40, "\(world.powder.count)")
        step(0.15)
        check("the tree sways", abs(world.treeTilt) > 0.01, "tilt \(world.treeTilt)")
        step(1.5)
        check("the tree stays bare for a moment", world.treeSnow.allSatisfy { $0 == 0 })
        step(9)
        check("snow grows back while the cursor stays", world.treeSnow == [1, 1, 1], "\(world.treeSnow)")
        info.mouse = V2(Float(ox) - 500, Float(oy) - 500)
        info.mouseVelocity = .zero
        step(0.1)
        info.mouse = V2(world.treeX + Float(ox), world.ground.top(at: world.treeX) - 50 + Float(oy))
        world.update(info)
        check("a new touch shakes it again", world.treeSnow.allSatisfy { $0 == 0 })
        info.mouse = V2(Float(ox) - 500, Float(oy) - 500)
        step(12)
        check("the tree comes to rest", abs(world.treeTilt) < 0.01)

        // Calm snow is a still picture. Only a gust of wind sets it in motion.
        world.ground.prewarm(0.9, 0.9)
        world.clearSnowmen()
        world.balls.removeAll()
        step(45)
        check("calm snow settles and needs no frames", world.settled, world.unsettledReason ?? "")
        let probe = world.size.x * 0.05
        let calmCrest = world.ground.top(at: probe), calmWind = world.windTime
        step(5)
        check("nothing moves between gusts", world.ground.top(at: probe) == calmCrest && world.windTime == calmWind && world.settled)
        world.startGust()
        check("a gust asks for frames", !world.settled)
        step(2)
        check("wind lifts powder off the crests", world.powder.contains { $0.gravity == 12 }, "\(world.powder.count)")
        step(2.5)
        check("a gust shifts the crests", abs(world.ground.top(at: probe) - calmCrest) > 0.2, "\(calmCrest) -> \(world.ground.top(at: probe))")
        step(5)
        check("after the gust everything is still again", world.settled, world.unsettledReason ?? "")
        check("offscreen renders keep their lights", world.lightsInMetal)
        let plowX = world.size.x * 0.06
        let beforePlow = world.ground.height(at: plowX)
        info.mouse = V2(plowX + Float(ox), world.ground.top(at: plowX) + 10 + Float(oy))
        info.mouseVelocity = V2(400, 0)
        info.play = false
        world.update(info)
        check("the cursor leaves a trough", world.ground.height(at: plowX) < beforePlow, "\(beforePlow) -> \(world.ground.height(at: plowX))")
        info.mouse = V2(Float(ox) - 500, Float(oy) - 500)
        info.mouseVelocity = .zero
        let dentDepth = world.ground.height(at: plowX)
        step(1)
        check("the dent stays visible at first", world.ground.height(at: plowX) < beforePlow - 2, "\(world.ground.height(at: plowX))")
        step(7)
        let halfway = world.ground.height(at: plowX)
        check("the dent starts closing by itself", halfway > dentDepth + 2, "\(dentDepth) -> \(halfway)")
        step(10)
        check("after 18 s the drift is whole again", abs(world.ground.height(at: plowX) - beforePlow) < 1.5, "\(world.ground.height(at: plowX)) vs \(beforePlow)")
        check("healing stops when done", !world.ground.healing)
        step(0.5)

        // The amount slider has to change everything called snow, immediately.
        let settings = Settings.shared
        settings.amount = 0
        step(0.1)
        let lowDrift = world.ground.maxH, lowCap = world.ground.capHeight
        settings.amount = 1
        step(0.1)
        check("maximum snow means taller drifts at once", world.ground.maxH > lowDrift * 2.5, "\(lowDrift) -> \(world.ground.maxH)")
        check("drift height follows the amount", world.ground.capHeight == 80 && lowCap == 20)
        settings.amount = 0.5
        step(0.1)

        _ = renderer.renderOffscreen(width: 640, height: 400)
        check("a frame renders", true)

        let full = world.syncWindows([WindowInfo(id: 200, frame: world.cgFrame)], pollDt: 0.5, existing: { [200] })
        check("full-screen apps are detected", full)
        let notFull = world.syncWindows([WindowInfo(id: 200, frame: world.cgFrame.insetBy(dx: 80, dy: 80))], pollDt: 0.5, existing: { [200] })
        check("ordinary windows are not full-screen", !notFull)
        return finish()
    }

    /// Opens the real overlays for a few seconds and drives them through real window event routing.
    static func live() -> Int32 {
        let restore = isolateSettings()
        defer { restore() }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        Sound.shared.muted = true
        func spin(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

        let c = Coordinator.shared
        let play = PlayState.shared
        let settings = Settings.shared
        c.start()
        spin(0.6)
        if let hold = ProcessInfo.processInfo.environment["SUGROB_AMOUNT_HOLD"].flatMap(Double.init) {
            settings.amount = 0
            spin(hold)
            print("LOW  drift \(c.overlays[0].world.ground.maxH)")
            settings.amount = 1
            spin(hold)
            print("HIGH drift \(c.overlays[0].world.ground.maxH)")
            settings.amount = 0.5
        }
        check("one overlay per display", c.overlays.count == NSScreen.screens.count)

        // The heart of the low-load design: a calm scene draws nothing.
        func calm() -> [Overlay] {
            let g = Coordinator.globalMouse()
            return c.overlays.filter { !$0.world.hidden && !$0.world.isNearSnow(global: g) }
        }
        spin(3)
        check("a calm scene stops drawing", calm().allSatisfy { $0.clockPaused }, c.overlays.map { $0.world.unsettledReason ?? "still" }.joined(separator: ", "))
        check("lights are animated by the system", c.overlays[0].lightCount > 20 && c.overlays[0].lightsAnimating, "\(c.overlays[0].lightCount)")
        check("the live scene leaves lights out of Metal", c.overlays.allSatisfy { !$0.world.lightsInMetal })
        c.gustNow()
        spin(0.4)
        check("a gust starts frames", c.overlays.filter { !$0.world.hidden }.allSatisfy { !$0.clockPaused })
        spin(9)
        check("and they stop again after it", calm().allSatisfy { $0.clockPaused }, c.overlays.map { $0.world.unsettledReason ?? "still" }.joined(separator: ", "))
        settings.garland = false
        spin(0.5)
        check("a settings change redraws and stops", calm().allSatisfy { $0.clockPaused })
        settings.garland = true
        spin(0.3)
        check("only the main display is primary", c.overlays.filter { $0.world.primary }.count == 1)
        check("global hotkeys registered", c.hotKeysRegistered)
        check("overlay is click-through outside play", c.overlays.allSatisfy { $0.window.ignoresMouseEvents })

        let menu = AppDelegate()
        app.delegate = menu
        menu.setupMenu()
        spin(0.2)
        menu.showMenu()
        spin(ProcessInfo.processInfo.environment["SUGROB_MENU_HOLD"].flatMap(Double.init) ?? 0.4)
        check("the menu opens", menu.popover.isShown)
        if let f = menu.popover.contentViewController?.view.window?.frame, let sc = NSScreen.screens.first(where: { $0.frame.intersects(f) }) {
            check("the whole menu fits on screen", f.maxY <= sc.visibleFrame.maxY + 16 && f.minY >= sc.frame.minY, "top \(Int(f.maxY)), height \(Int(f.height))")
        } else {
            check("the whole menu fits on screen", false)
        }
        menu.closeMenu()
        spin(0.1)
        check("the close action closes it", !menu.popover.isShown)
        menu.toggle()
        spin(0.1)
        check("the click that closed it does not reopen it", !menu.popover.isShown)
        spin(0.4)
        menu.toggle()
        spin(0.2)
        check("clicking the snowflake opens it", menu.popover.isShown)
        menu.toggle()
        spin(0.1)
        check("clicking the snowflake again closes it", !menu.popover.isShown)

        c.setPlay(true)
        spin(0.4)
        check("play mode turns on", play.active && c.overlays.allSatisfy { !$0.window.ignoresMouseEvents })
        check("global Esc and tool keys armed", c.playKeyCount == 3, "\(c.playKeyCount)")

        guard let o = c.overlays.first else { return 1 }
        let w = o.window
        func mouse(_ t: NSEvent.EventType, _ p: NSPoint) {
            if let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { w.sendEvent(e) }
        }
        func key(_ code: UInt16, _ chars: String) {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) { o.view.keyDown(with: e) }
        }
        key(18, "1")
        check("key 1 selects snowballs", play.tool == .snowball)
        let p = NSPoint(x: w.frame.width / 2, y: w.frame.height / 2)
        mouse(.leftMouseDown, p)
        check("window routes the press to the game", o.world.held != nil)
        spin(0.05)
        mouse(.leftMouseUp, p)
        check("releasing through the window throws", !o.world.balls.isEmpty)
        key(19, "2")
        check("key 2 selects the snowman tool", play.tool == .snowman)
        let groundPoint = NSPoint(x: 120, y: CGFloat(o.world.size.y - o.world.ground.top(at: 120)))
        mouse(.leftMouseDown, groundPoint)
        check("pressing on snow starts a ball", o.world.carried != nil)
        mouse(.leftMouseUp, groundPoint)

        key(53, "\u{1b}")
        spin(0.2)

        // With nobody at the Mac even the lights stop.
        c.deepIdleAfter = -1
        spin(2.4)
        check("lights freeze while nobody is there", c.resting && c.overlays.allSatisfy { !$0.lightsAnimating })
        c.deepIdleAfter = 1_000_000
        spin(2.4)
        check("input brings them back", !c.resting && c.overlays.allSatisfy { $0.lightsAnimating })

        check("Esc leaves play mode", !play.active && c.overlays.allSatisfy { $0.window.ignoresMouseEvents })
        check("play keys released", c.playKeyCount == 0)
        c.toggleSnow()
        spin(0.3)
        check("the toggle turns the snow off", !settings.enabled && c.overlays.allSatisfy { !$0.window.isVisible })
        c.toggleSnow()
        spin(0.3)
        check("and back on", settings.enabled && c.overlays.allSatisfy { $0.window.isVisible })
        return finish()
    }
}
