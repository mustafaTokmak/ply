import Foundation
import Security
import PlyShared

public enum Paths {
    public static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ply", isDirectory: true)
    }

    public static var settingsFile: URL { appSupport.appendingPathComponent("settings.json") }
    public static var tokenFile: URL { appSupport.appendingPathComponent("api-token") }

    static func ensureDir() {
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Bearer token for the local HTTP API. Created by the engine, readable only by this user.
    public static func readToken() -> String? {
        guard let data = try? Data(contentsOf: tokenFile) else { return nil }
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    public static func ensureToken() -> String {
        if let t = readToken() { return t }
        ensureDir()
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        FileManager.default.createFile(atPath: tokenFile.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        return token
    }
}

public enum Log {
    private static let lock = NSLock()
    public static var echoToStderr = false

    public static func info(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        if echoToStderr {
            let ts = ISO8601DateFormatter().string(from: Date())
            FileHandle.standardError.write(Data("\(ts) \(message)\n".utf8))
        }
    }
}
