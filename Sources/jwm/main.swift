import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            begin()
        } else {
            print("jwm: waiting for Accessibility permission (System Settings → Privacy & Security → Accessibility)")
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self.begin()
            }
        }
        // Put parked windows back if we're killed from the terminal.
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    private func begin() {
        guard Hotkeys.shared.start() else {
            print("jwm: couldn't create the keyboard event tap")
            exit(1)
        }
        WM.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        WM.shared.restoreAll()
    }
}

let args = CommandLine.arguments
if args.contains("--list") || args.contains("--restore") {
    WM.shared.refresh()
    if args.contains("--restore") { WM.shared.restoreAll() }
    for window in WM.shared.windows.values.sorted(by: { $0.id < $1.id }) {
        print(window.id, window.label, window.element.frame.map { "\($0)" } ?? "?")
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
