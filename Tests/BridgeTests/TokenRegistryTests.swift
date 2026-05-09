import Testing
import Foundation
import Logging
@testable import BridgeAuth

// Token CRUD against a temp-dir URL. The registry's `init(url:logger:)`
// override lets us isolate tests from the user's real tokens.toml.

private func tempPaths() -> (tokens: URL, legacy: URL, cleanup: () -> Void) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("registry-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let tokens = dir.appendingPathComponent("tokens.toml")
    let legacy = dir.appendingPathComponent("token")
    return (tokens, legacy, { try? FileManager.default.removeItem(at: dir) })
}

private func makeRegistry(tokens: URL, legacy: URL) -> TokenRegistry {
    TokenRegistry(url: tokens, legacyTokenURL: legacy, logger: Logger(label: "test"))
}

@Test func bootstrapWritesDefaultTokenWhenNoFilesExist() async throws {
    let p = tempPaths(); defer { p.cleanup() }
    let r = makeRegistry(tokens: p.tokens, legacy: p.legacy)
    try await r.ensureLoaded()
    let entries = await r.allEntries()
    // The bootstrap path creates a single "default" entry so first-run
    // clients have something to authenticate with — same behavior the
    // CLI relies on for `auth show default` to work without prior `add`.
    #expect(entries.count == 1)
    #expect(entries.first?.0 == "default")
    #expect(entries.first?.1.secret.isEmpty == false)
}

@Test func tokensFileIsMode0600() async throws {
    let p = tempPaths(); defer { p.cleanup() }
    let r = makeRegistry(tokens: p.tokens, legacy: p.legacy)
    try await r.ensureLoaded()
    // The plaintext-secret file MUST not be world-readable. Any persist
    // step should re-set 0600 — drift here breaks the security model.
    let attrs = try FileManager.default.attributesOfItem(atPath: p.tokens.path)
    let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
    #expect(perms == 0o600, "tokens.toml must be 0600, got \(String(perms, radix: 8))")
}

@Test func addCreatesNewEntryAndPersists() async throws {
    let p = tempPaths(); defer { p.cleanup() }
    let r = makeRegistry(tokens: p.tokens, legacy: p.legacy)
    try await r.ensureLoaded()

    let entry = try await r.add(label: "host", profile: "trusted", description: "Mac local")
    #expect(entry.profile == "trusted")
    #expect(entry.description == "Mac local")
    #expect(entry.secret.hasPrefix("icb_"))

    // Reload from disk into a fresh actor — proves the write persisted.
    let r2 = makeRegistry(tokens: p.tokens, legacy: p.legacy)
    try await r2.ensureLoaded()
    let labels = await r2.allEntries().map { $0.0 }
    #expect(labels.contains("host"))
    #expect(labels.contains("default"))   // bootstrap entry survives
}

@Test func addRejectsDuplicateLabel() async throws {
    let p = tempPaths(); defer { p.cleanup() }
    let r = makeRegistry(tokens: p.tokens, legacy: p.legacy)
    try await r.ensureLoaded()
    _ = try await r.add(label: "host", profile: nil, description: "")

    do {
        _ = try await r.add(label: "host", profile: nil, description: "")
        Issue.record("expected RegistryError.alreadyExists for duplicate label")
    } catch let e as TokenRegistry.RegistryError {
        if case .alreadyExists(let l) = e { #expect(l == "host") }
        else { Issue.record("expected .alreadyExists, got \(e)") }
    }
}

@Test func revokeRemovesEntry() async throws {
    let p = tempPaths(); defer { p.cleanup() }
    let r = makeRegistry(tokens: p.tokens, legacy: p.legacy)
    try await r.ensureLoaded()
    _ = try await r.add(label: "host", profile: nil, description: "")
    try await r.revoke(label: "host")

    let labels = await r.allEntries().map { $0.0 }
    #expect(!labels.contains("host"))
}

@Test func revokeMissingLabelThrowsNotFound() async throws {
    let p = tempPaths(); defer { p.cleanup() }
    let r = makeRegistry(tokens: p.tokens, legacy: p.legacy)
    try await r.ensureLoaded()
    do {
        try await r.revoke(label: "ghost")
        Issue.record("expected .notFound")
    } catch let e as TokenRegistry.RegistryError {
        if case .notFound(let l) = e { #expect(l == "ghost") }
        else { Issue.record("expected .notFound, got \(e)") }
    }
}

@Test func rotateChangesSecretAndCreatedTimestamp() async throws {
    let p = tempPaths(); defer { p.cleanup() }
    let r = makeRegistry(tokens: p.tokens, legacy: p.legacy)
    try await r.ensureLoaded()
    let original = try await r.add(label: "host", profile: nil, description: "")
    // Sleep enough for the ISO8601 fractional-second formatter to roll
    // forward — without this the rotated `created` timestamp can equal
    // the original on fast machines and the assertion below false-passes.
    try await Task.sleep(nanoseconds: 50_000_000)
    let rotated = try await r.rotate(label: "host")

    #expect(rotated.secret != original.secret, "rotation must change the secret")
    #expect(rotated.profile == original.profile)
    #expect(rotated.description == original.description)
    #expect(rotated.created != original.created)
}

@Test func setProfileMutatesProfileField() async throws {
    let p = tempPaths(); defer { p.cleanup() }
    let r = makeRegistry(tokens: p.tokens, legacy: p.legacy)
    try await r.ensureLoaded()
    _ = try await r.add(label: "host", profile: nil, description: "")

    try await r.setProfile(label: "host", profile: "trusted")
    let after = await r.entry(for: "host")
    #expect(after?.profile == "trusted")

    // Setting nil strips the profile entirely (back to <global>).
    try await r.setProfile(label: "host", profile: nil)
    let cleared = await r.entry(for: "host")
    #expect(cleared?.profile == nil)
}

@Test func generatedSecretsAreUniqueAndPrefixed() async throws {
    let p = tempPaths(); defer { p.cleanup() }
    let r = makeRegistry(tokens: p.tokens, legacy: p.legacy)
    try await r.ensureLoaded()
    var secrets: Set<String> = []
    for i in 0..<8 {
        let entry = try await r.add(label: "tok\(i)", profile: nil, description: "")
        #expect(entry.secret.hasPrefix("icb_"), "generated secrets must carry the icb_ prefix")
        secrets.insert(entry.secret)
    }
    #expect(secrets.count == 8, "generated secrets must be unique")
}

@Test func legacyTokenFileMigratesToTokensToml() async throws {
    let p = tempPaths(); defer { p.cleanup() }
    // Pre-populate the legacy single-token file.
    try "icb_LEGACY_secret_value".write(to: p.legacy, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p.legacy.path)

    let r = makeRegistry(tokens: p.tokens, legacy: p.legacy)
    try await r.ensureLoaded()

    // Migration: legacy secret should now appear in tokens.toml under
    // some label (default is the canonical name) and the legacy file
    // either removed or left alone — either way the new file exists and
    // contains the migrated secret.
    let entry = await r.entry(for: "default")
    #expect(entry?.secret == "icb_LEGACY_secret_value", "migration must preserve the legacy secret verbatim")
    #expect(FileManager.default.fileExists(atPath: p.tokens.path))
}
