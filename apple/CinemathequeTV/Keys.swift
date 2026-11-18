import Foundation
import Security

/// Keeps the home's seeds in the Keychain, since tvOS may purge the caches
/// that hold the home: `identity` (the device's), `user` (the user's, once
/// linked), and `library` (its founder's key). The replica is rebuilt by
/// syncing and crawling; these are not.
enum Keys {
    private static let files = ["identity", "user", "library"]
    private static let service = "com.rbrian.cinematheque.home"

    /// The home: in the caches, where the core puts it on tvOS.
    static var home: URL {
        URL.cachesDirectory.appending(path: "Cinematheque", directoryHint: .isDirectory)
    }

    /// Puts back any seed the home has lost, before the library opens it.
    static func restore() {
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        for name in files {
            let file = home.appending(path: name)
            guard !FileManager.default.fileExists(atPath: file.path), let data = read(name) else { continue }
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Keeps any seed the home has gained (e.g., on linking or joining).
    static func save() {
        for name in files {
            guard let data = try? Data(contentsOf: home.appending(path: name)), read(name) != data else { continue }
            write(name, data)
        }
    }

    private static func query(_ name: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: name,
        ]
    }

    private static func read(_ name: String) -> Data? {
        var q = query(name)
        q[kSecReturnData] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func write(_ name: String, _ data: Data) {
        SecItemDelete(query(name) as CFDictionary)
        var q = query(name)
        q[kSecValueData] = data
        q[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
}
