import AppKit

let args = CommandLine.arguments
if args.count == 3, args[1] == "--make-icon" {
    IconMaker.write(to: args[2])
    exit(0)
}

if args.count == 3, args[1] == "--snapshot" || args[1] == "--snapshot-real" {
    _ = NSApplication.shared
    Snapshot.run(output: args[2], realWindows: args[1] == "--snapshot-real")
    exit(0)
}

if args.count == 2, args[1] == "--selftest-live" {
    exit(SelfTest.live())
}

if args.count == 2, args[1] == "--selftest" {
    _ = NSApplication.shared
    exit(SelfTest.run())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
