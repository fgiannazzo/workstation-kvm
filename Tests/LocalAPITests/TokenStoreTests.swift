import Foundation
import LocalAPI
import Security
import Testing

@Suite("TokenStore")
struct TokenStoreTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "switchboard-token-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "api-token", directoryHint: .notDirectory)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
    }

    @Test("a generated token is 32 random bytes as base64url without padding: 43 characters")
    func generated() throws {
        let token = try TokenStore.generate()
        #expect(token.count == 43)
        #expect(token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        #expect(!token.contains("="))
        #expect(!token.contains("+"))
        #expect(!token.contains("/"))

        // It decodes back to 32 bytes.
        var base64 = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += "="
        #expect(Data(base64Encoded: base64)?.count == 32)

        // Two tokens differ (a collision is a 2^-256 event).
        #expect(try TokenStore.generate() != token)
    }

    @Test("base64URL swaps the alphabet and drops the padding")
    func base64URL() {
        #expect(TokenStore.base64URL(Data([0xFB, 0xFF, 0xFE])) == "-__-")
        #expect(TokenStore.base64URL(Data([0xFB, 0xFF])) == "-_8")
        #expect(TokenStore.base64URL(Data([0x01])) == "AQ")
        #expect(TokenStore.base64URL(Data()) == "")
    }

    @Test("loadOrCreate makes a token once and returns the same one from then on")
    func createsOnce() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileTokenStore(url: url)

        #expect(try store.load() == nil)
        let first = try TokenStore.loadOrCreate(using: store)
        #expect(first.count == 43)
        #expect(try store.load() == first)

        let second = try TokenStore.loadOrCreate(using: store)
        #expect(second == first)
        // A different store object over the same file is the same token: another process.
        #expect(try TokenStore.loadOrCreate(using: FileTokenStore(url: url)) == first)
    }

    @Test("resolve says whether it created the token")
    func resolveReports() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileTokenStore(url: url)
        let created = try TokenStore.resolve(using: store)
        #expect(created.created)
        let found = try TokenStore.resolve(using: store)
        #expect(!found.created)
        #expect(found.token == created.token)
    }

    @Test("a token that is already there is kept as it is, whatever its shape")
    func keepsExisting() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileTokenStore(url: url)
        try store.save("my own token")
        #expect(try TokenStore.loadOrCreate(using: store) == "my own token")
    }

    @Test("an empty or blank token is replaced by a generated one")
    func replacesBlank() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileTokenStore(url: url)
        try store.save("   ")
        let token = try TokenStore.loadOrCreate(using: store)
        #expect(token.count == 43)
        #expect(try store.load() == token)
    }

    @Test("the token file is readable by its owner only, also when it already existed with looser rights")
    func filePermissions() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileTokenStore(url: url)

        try store.save("one")
        #expect(try permissions(of: url) == 0o600)
        #expect(try permissions(of: url.deletingLastPathComponent()) == 0o700)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path(percentEncoded: false))
        try store.save("two")
        #expect(try permissions(of: url) == 0o600)
        #expect(try store.load() == "two")
    }

    @Test("a token file with a trailing newline loads without it")
    func trims() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("abc\n\n".utf8).write(to: url)
        #expect(try FileTokenStore(url: url).load() == "abc")
    }

    @Test("a token file that cannot be written is a TokenStoreError naming the path")
    func unwritable() throws {
        // A regular file where the directory should be.
        let blocker = FileManager.default.temporaryDirectory.appending(path: "switchboard-token-blocker-\(UUID().uuidString)")
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let store = FileTokenStore(url: blocker.appending(path: "api-token"))
        do {
            try store.save("x")
            Issue.record("expected an error")
        } catch let error as TokenStoreError {
            guard case .file(let path, _) = error else { Issue.record("expected .file, got \(error)"); return }
            #expect(path.hasSuffix("api-token"))
        }
    }

    @Test("the comparison accepts equal strings only, whatever the lengths")
    func constantTime() {
        #expect(TokenStore.constantTimeEquals("abc", "abc"))
        #expect(TokenStore.constantTimeEquals("", ""))
        #expect(!TokenStore.constantTimeEquals("abc", "abd"))
        #expect(!TokenStore.constantTimeEquals("abc", "ab"))
        #expect(!TokenStore.constantTimeEquals("ab", "abc"))
        #expect(!TokenStore.constantTimeEquals("abc", ""))
        #expect(!TokenStore.constantTimeEquals("", "a"))
        #expect(!TokenStore.constantTimeEquals("abc", "ABC"))
        #expect(TokenStore.constantTimeEquals("héllo", "héllo"))
        #expect(!TokenStore.constantTimeEquals("héllo", "hello"))
    }

    @Test("the keychain item is named as DESIGN.md says")
    func names() {
        #expect(TokenStore.service == "io.github.fgiannazzo.switchboard")
        #expect(TokenStore.account == "local-api-token")
        let store = KeychainTokenStore()
        #expect(store.service == "io.github.fgiannazzo.switchboard")
        #expect(store.account == "local-api-token")
    }

    @Test("a keychain error explains the prompt")
    func keychainErrorText() {
        let cancelled = TokenStoreError.keychain(status: errSecUserCanceled, detail: "User canceled the operation.")
        #expect(cancelled.description.contains("Always Allow"))
        let other = TokenStoreError.keychain(status: errSecParam, detail: "bad parameter")
        #expect(!other.description.contains("Always Allow"))
    }

    /// Talks to the real login keychain, so it is off unless `SWITCHBOARD_KEYCHAIN_TESTS=1`. It uses
    /// a service name of its own and removes the item afterwards; the real item is never touched.
    @Test(
        "KeychainTokenStore round-trips through the login keychain (opt-in: SWITCHBOARD_KEYCHAIN_TESTS=1)",
        .enabled(if: ProcessInfo.processInfo.environment["SWITCHBOARD_KEYCHAIN_TESTS"] == "1")
    )
    func keychainRoundTrip() throws {
        let store = KeychainTokenStore(service: "io.github.fgiannazzo.switchboard.test.\(UUID().uuidString)", account: "local-api-token-test")
        defer { try? store.delete() }

        #expect(try store.load() == nil)
        let created = try TokenStore.loadOrCreate(using: store)
        #expect(created.count == 43)
        #expect(try store.load() == created)
        #expect(try TokenStore.loadOrCreate(using: store) == created)

        try store.save("replaced")
        #expect(try store.load() == "replaced")

        try store.delete()
        #expect(try store.load() == nil)
    }
}
