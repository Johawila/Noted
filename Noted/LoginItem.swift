import Foundation

/// Launch-at-login backed by a plain LaunchAgent rather than `SMAppService`.
///
/// `SMAppService` keys its login item to the app's code signature. This app is ad-hoc signed
/// (deliberately — a development signature expires after ~14 days), and an ad-hoc signature is
/// not a stable identity, so replacing the bundle on reinstall invalidates the registration and
/// the login item silently disappears. A LaunchAgent points at a path instead, which survives
/// every reinstall.
enum LoginItem {
    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func enable() throws {
        let agent: [String: Any] = [
            "Label": label,
            // Launch through `open` so LaunchServices starts the app properly rather than
            // exec'ing the binary with launchd's bare environment.
            "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
            "RunAtLoad": true,
            // GUI sessions only — never in a login window or ssh session.
            "LimitLoadToSessionType": "Aqua",
        ]
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
        try data.write(to: plistURL)
        launchctl("bootstrap")
    }

    static func disable() throws {
        launchctl("bootout")
        if isEnabled { try FileManager.default.removeItem(at: plistURL) }
    }

    // MARK: - Private

    private static let label = "com.johanwilander.noted.login"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Tells the running launchd session about the change so it also shows up in System Settings
    /// straight away. Best-effort: the plist on its own is enough to take effect at next login.
    private static func launchctl(_ command: String) {
        let target = "gui/\(getuid())"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = command == "bootout"
            ? [command, "\(target)/\(label)"]
            : [command, target, plistURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
