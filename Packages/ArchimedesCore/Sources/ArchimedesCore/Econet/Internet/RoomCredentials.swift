// Host networking (URLSession, Keychain, Dispatch): not part of WebAssembly builds.
#if !os(WASI)
import Foundation
#if canImport(Security)
import Security
#endif

// A room's secrets: the member token (to connect), and for the host the
// owner token. Kept in the Keychain, scoped to the service's origin and the
// room, never in a network's file. (A network keeps only which room, on
// which service.)

public struct RoomCredentials: Codable, Sendable, Equatable {
    public var participantId: String
    public var memberToken: String
    public var ownerToken: String?

    public init(participantId: String, memberToken: String, ownerToken: String? = nil) {
        self.participantId = participantId
        self.memberToken = memberToken
        self.ownerToken = ownerToken
    }
}

public protocol RoomCredentialStore: Sendable {
    func credentials(service: URL, roomId: String) -> RoomCredentials?
    func save(_ credentials: RoomCredentials, service: URL, roomId: String) throws
    func remove(service: URL, roomId: String)
}

#if canImport(Security)
/// The macOS Keychain: one generic password per service origin and room.
public struct KeychainCredentialStore: RoomCredentialStore {
    static let itemService = "MacArch Internet Econet"

    public init() {}

    private func account(_ service: URL, _ roomId: String) -> String {
        "\(InternetEconetService.origin(service)) \(roomId)"
    }

    private func query(_ service: URL, _ roomId: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.itemService,
         kSecAttrAccount as String: account(service, roomId)]
    }

    public func credentials(service: URL, roomId: String) -> RoomCredentials? {
        var q = query(service, roomId)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(RoomCredentials.self, from: data)
    }

    public struct KeychainError: Error, CustomStringConvertible {
        public var status: OSStatus
        public var description: String { "Couldn't keep the room's credentials in the Keychain (\(status))" }
    }

    public func save(_ credentials: RoomCredentials, service: URL, roomId: String) throws {
        let data = try JSONEncoder().encode(credentials)
        let q = query(service, roomId)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecAttrLabel as String] = "MacArch Econet room (\(InternetEconetService.origin(service)))"
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public func remove(service: URL, roomId: String) {
        SecItemDelete(query(service, roomId) as CFDictionary)
    }
}

#endif

/// A file only its owner can read (0600), for hosts without a Keychain
/// (Linux): every room's credentials in one JSON object, by service origin
/// and room.
public final class FileCredentialStore: RoomCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    public let path: String

    public init(path: String) { self.path = path }

    private func key(_ service: URL, _ roomId: String) -> String { "\(InternetEconetService.origin(service)) \(roomId)" }

    private func load() -> [String: RoomCredentials] {
        guard let d = FileManager.default.contents(atPath: path) else { return [:] }
        return (try? JSONDecoder().decode([String: RoomCredentials].self, from: d)) ?? [:]
    }

    private func store(_ items: [String: RoomCredentials]) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let d = try JSONEncoder().encode(items)
        // Made private before anything secret is in it.
        if !FileManager.default.fileExists(atPath: path) {
            _ = FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        try d.write(to: URL(fileURLWithPath: path))
    }

    public func credentials(service: URL, roomId: String) -> RoomCredentials? {
        lock.withLock { load()[key(service, roomId)] }
    }

    public func save(_ credentials: RoomCredentials, service: URL, roomId: String) throws {
        try lock.withLock {
            var items = load()
            items[key(service, roomId)] = credentials
            try store(items)
        }
    }

    public func remove(service: URL, roomId: String) {
        lock.withLock {
            var items = load()
            guard items.removeValue(forKey: key(service, roomId)) != nil else { return }
            try? store(items)
        }
    }
}

/// In memory: for tests and self-tests (which mustn't touch the user's
/// Keychain).
public final class MemoryCredentialStore: RoomCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: RoomCredentials] = [:]

    public init() {}

    private func key(_ service: URL, _ roomId: String) -> String { "\(InternetEconetService.origin(service)) \(roomId)" }

    public func credentials(service: URL, roomId: String) -> RoomCredentials? {
        lock.withLock { items[key(service, roomId)] }
    }

    public func save(_ credentials: RoomCredentials, service: URL, roomId: String) throws {
        lock.withLock { items[key(service, roomId)] = credentials }
    }

    public func remove(service: URL, roomId: String) {
        _ = lock.withLock { items.removeValue(forKey: key(service, roomId)) }
    }
}
#endif
