import Foundation

enum ScreenLock {
    /// Same as  → Lock Screen. `SACLockScreenImmediate` lives in the private login
    /// framework; if it ever disappears, sleeping the display locks the Mac when
    /// "Require password after screen saver begins or display is turned off" is immediate.
    static func lockNow() {
        typealias LockScreen = @convention(c) () -> Int32
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let symbol = dlsym(handle, "SACLockScreenImmediate") {
            _ = unsafeBitCast(symbol, to: LockScreen.self)()
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try? process.run()
    }

    static var isAvailable: Bool {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY) else { return false }
        return dlsym(handle, "SACLockScreenImmediate") != nil
    }
}
