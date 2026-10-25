import AppKit
import Foundation

/// A small plain-text log at ~/Library/Logs/QuietGlass/diagnostics.log that people can
/// read, and that "Report a Bug…" attaches. Only decisions and numbers — never images,
/// names or screen content.
enum Diagnostics {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/QuietGlass", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("diagnostics.log")
    }()
    private static let queue = DispatchQueue(label: "local.clinton.QuietGlass.diagnostics", qos: .utility)
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; f.timeZone = .current; return f
    }()

    /// Off under XCTest so test fixtures never reach the real log or bug reports.
    static var enabled = Bundle.main.bundleURL.pathExtension == "app"

    static func log(_ line: String) {
        guard enabled else { return }
        let text = "\(stamp.string(from: Date())) \(line)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile(); handle.write(Data(text.utf8)); try? handle.close()
            } else { try? Data(text.utf8).write(to: url) }
            trimIfNeeded()
        }
    }

    /// Keeps the file under ~256 KB by dropping the older half.
    private static func trimIfNeeded() {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 256_000,
              let data = try? Data(contentsOf: url) else { return }
        let tail = data.suffix(size / 2)
        let start = tail.firstIndex(of: UInt8(ascii: "\n")).map { tail.index(after: $0) } ?? tail.startIndex
        try? Data(tail[start...]).write(to: url)
    }

    static func recentLines(_ count: Int) -> [String] {
        queue.sync {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return Array(text.split(separator: "\n").suffix(count).map(String.init))
        }
    }

    static func reveal() {
        if !FileManager.default.fileExists(atPath: url.path) { log("diagnostics log created") }
        queue.sync {}
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Bug report

    static let issuesURL = URL(string: "https://github.com/Functionhx/quietglass-plus/issues")!

    /// Opens GitHub's bug form with the environment and recent diagnostics filled in.
    /// Nothing is sent until you review it and press Submit on GitHub.
    static func reportBug(settings: [String]) {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var model = [CChar](repeating: 0, count: 64); var size = model.count
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let environment = """
        QuietGlass Plus \(version)
        macOS \(os)
        Mac \(String(cString: model)), \(Locale.preferredLanguages.first ?? "?")
        \(settings.joined(separator: "\n"))
        """
        let recent = recentLines(25).joined(separator: "\n")
        var components = URLComponents(url: issuesURL.appendingPathComponent("new"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "template", value: "bug_report.yml"),
            URLQueryItem(name: "environment", value: environment),
            URLQueryItem(name: "diagnostics", value: recent.isEmpty ? "(empty)" : recent),
        ]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}
