import Foundation
import Security

/// Where the local API's bearer token is kept.
///
/// Production uses `KeychainTokenStore` (the login keychain); tests and `SWITCHBOARD_TOKEN_FILE`
/// use `FileTokenStore`. Stores hold one string and know nothing about how it is made: that is
/// `TokenStore.loadOrCreate(using:)`.
public protocol TokenStoring: Sendable {
    /// The stored token; nil when there is none yet. Throws when the store cannot be read.
    func load() throws -> String?
    /// Replaces the stored token.
    func save(_ token: String) throws
}

/// Why a token could not be read or written.
public enum TokenStoreError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    /// A Security framework call failed. `status` is the `OSStatus`, `detail` its message.
    case keychain(status: Int32, detail: String)
    /// The stored value is not text.
    case corrupt(String)
    /// A token file could not be read or written.
    case file(path: String, detail: String)
    /// The system random number generator failed.
    case randomFailure(Int32)

    public var description: String {
        switch self {
        case .keychain(let status, let detail):
            var text = "keychain error \(status): \(detail)"
            // The three ways a keychain says "someone has to click a button".
            if [errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed].contains(status) {
                text += ". Allow access when the keychain asks (Always Allow), and unlock the login keychain if it is locked"
            }
            return text
        case .corrupt(let detail):
            return "the stored token is unreadable: \(detail)"
        case .file(let path, let detail):
            return "token file \(path): \(detail)"
        case .randomFailure(let status):
            return "could not generate a random token (SecRandomCopyBytes returned \(status))"
        }
    }

    public var errorDescription: String? { description }
}

/// The token in the login keychain: a generic password with service
/// `io.github.fgiannazzo.switchboard` and account `local-api-token` (`docs/DESIGN.md`, "Names").
///
/// This is the file-based login keychain on purpose: no `kSecUseDataProtectionKeychain`, which
/// needs a provisioning profile that an ad-hoc signed SwiftPM app and a command line tool do not
/// have. The consequence is the usual keychain behaviour: the process that created the item can
/// read it silently, and another program (the CLI after the app, or the other way round) gets one
/// "wants to use your confidential information" prompt, which "Always Allow" answers for good.
public struct KeychainTokenStore: TokenStoring {
    public let service: String
    public let account: String

    public init(service: String = TokenStore.service, account: String = TokenStore.account) {
        self.service = service
        self.account = account
    }

    private var identity: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    public func load() throws -> String? {
        var query = identity
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
                throw TokenStoreError.corrupt("the keychain item \(service) / \(account) is not UTF-8 text")
            }
            return text
        case errSecItemNotFound:
            return nil
        default:
            throw Self.error(status)
        }
    }

    public func save(_ token: String) throws {
        let data = Data(token.utf8)
        let update = SecItemUpdate(identity as CFDictionary, [kSecValueData: data] as CFDictionary)
        switch update {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = identity
            attributes[kSecValueData] = data
            attributes[kSecAttrLabel] = "Switchboard local API token"
            attributes[kSecAttrDescription] = "Bearer token for the Switchboard local API on 127.0.0.1"
            let add = SecItemAdd(attributes as CFDictionary, nil)
            guard add == errSecSuccess else { throw Self.error(add) }
        default:
            throw Self.error(update)
        }
    }

    /// Removes the item. Not part of `TokenStoring`: nothing in the product deletes the token; it
    /// exists for tests that create an item under a name of their own.
    public func delete() throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status) }
    }

    private static func error(_ status: OSStatus) -> TokenStoreError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return .keychain(status: status, detail: message)
    }
}

/// A token in a file readable by its owner only (mode 0600). For tests, and for development with
/// `SWITCHBOARD_TOKEN_FILE`, where touching the real keychain would be a side effect.
public struct FileTokenStore: TokenStoring {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> String? {
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : token
        } catch {
            throw TokenStoreError.file(path: path, detail: error.localizedDescription)
        }
    }

    public func save(_ token: String) throws {
        let path = url.path(percentEncoded: false)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // Created with the final mode, so the token is never readable by others, not even briefly.
            guard FileManager.default.createFile(
                atPath: path,
                contents: Data((token + "\n").utf8),
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            // An existing file keeps its old mode through createFile.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            throw TokenStoreError.file(path: path, detail: error.localizedDescription)
        }
    }
}

/// Making and finding the token.
public enum TokenStore {
    /// Keychain service of the token (`docs/DESIGN.md`, "Names").
    public static let service = "io.github.fgiannazzo.switchboard"
    /// Keychain account of the token.
    public static let account = "local-api-token"
    /// Random bytes in a new token. 32 bytes are 43 base64url characters.
    public static let byteCount = 32

    /// 32 random bytes from the system generator, base64url without padding.
    public static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw TokenStoreError.randomFailure(status) }
        return base64URL(Data(bytes))
    }

    /// RFC 4648 section 5: `-` and `_` for `+` and `/`, no `=` padding.
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The stored token, or a new one that is stored first. A token that is already there is
    /// returned as it is, whatever its shape, so a user can set their own. The second call (and
    /// the second process) gets the same value.
    public static func loadOrCreate(using store: some TokenStoring) throws -> String {
        try resolve(using: store).token
    }

    /// Like `loadOrCreate`, and says whether this call made the token.
    public static func resolve(using store: some TokenStoring) throws -> (token: String, created: Bool) {
        if let existing = try store.load(), !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (existing, false)
        }
        let token = try generate()
        try store.save(token)
        return (token, true)
    }

    /// The comparison the server uses for the bearer token: it looks at every byte of the longer
    /// of the two, so how long it takes does not say how many leading bytes were right.
    public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = left.count ^ right.count
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            difference |= Int(l ^ r)
        }
        return difference == 0
    }
}
