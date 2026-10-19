import AppKit

// Build-time hook: `CalSyncApp --export-icon <dir>` renders the .iconset and exits
// without ever starting the UI. build.sh uses this so the icon is generated from the
// same drawing code the menu bar uses, instead of being committed as image files.
if let flag = CommandLine.arguments.firstIndex(of: "--export-icon"),
   flag + 1 < CommandLine.arguments.count {
    let directory = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    do {
        try CalSyncMark.exportIconSet(to: directory)
        print("wrote iconset to \(directory.path)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("icon export failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// `.accessory` keeps CalSync out of the Dock and the app switcher: it lives in the
// menu bar only. The Info.plist sets LSUIElement to match, so this holds from launch.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
