import AppKit

let app = NSApplication.shared
if CommandLine.arguments.contains("--snapshot") {
    Snapshot.run(args: Array(CommandLine.arguments.dropFirst()))
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
