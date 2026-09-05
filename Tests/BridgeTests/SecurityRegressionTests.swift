import Testing
import Foundation
import Logging
import MCP
import HTTPTypes
@testable import BridgeCore
@testable import BridgeConfig
@testable import BridgeAuth
@testable import BridgePolicy
@testable import ServiceDrive
import ServiceCalendar
import ServiceContacts
import ServiceReminders

@Test func sessionRecoveryCannotInterruptCallsOrOverlap() {
    let gate = SessionLifecycleGate()
    #expect(gate.beginCall())
    #expect(gate.beginCall())
    #expect(!gate.beginRecovery())
    gate.endCall()
    #expect(!gate.beginRecovery())
    gate.endCall()
    #expect(gate.beginRecovery())
    #expect(!gate.beginRecovery())
    #expect(!gate.beginCall())
    gate.endRecovery()
    #expect(gate.beginCall())
    gate.endCall()
}

@Test func tailnetTransportAcceptsConfiguredHostAndRejectsOtherOrigins() async {
    let transport = SessionHolder.makeTransport(allowedHosts: ["100.90.1.1:8787"], logger: Logger(label: "test"))
    let context = HTTPValidationContext(httpMethod: "POST")
    let validator = OriginValidator(allowedHosts: ["100.90.1.1:8787"], allowedOrigins: [])
    let request = MCP.HTTPRequest(method: "POST", headers: ["Host": "100.90.1.1:8787"], body: nil)
    #expect(validator.validate(request, context: context)?.statusCode == nil)
    let hostile = MCP.HTTPRequest(method: "POST", headers: ["Host": "100.90.1.1:8787", "Origin": "https://evil.example"], body: nil)
    #expect(validator.validate(hostile, context: context)?.statusCode == 403)
    let wrongHost = MCP.HTTPRequest(method: "POST", headers: ["Host": "evil.example:8787"], body: nil)
    #expect(validator.validate(wrongHost, context: context)?.statusCode == 421)
    // The actual transport must get beyond Host validation to reject the missing Accept header.
    #expect(await transport.handleRequest(request).statusCode != 421)
}

@Test func malformedContactArraysAreRejectedBeforeMutation() throws {
    let tool = try #require(ContactsTools().handlers.first { $0.name == "contacts.update" })
    #expect(!ToolArguments.isValid(.object(["id": .string("fixture"), "phones": .array([.int(4)])]), schema: tool.spec.inputSchema))
    #expect(!ToolArguments.isValid(.object(["id": .string("fixture"), "phones": .array([.object(["label": .string("work")])])]), schema: tool.spec.inputSchema))
    #expect(ToolArguments.isValid(.object(["id": .string("fixture"), "phones": .array([]), "job_title": .null]), schema: tool.spec.inputSchema))
}

@Test func calendarSchemaRejectsMistypedOptionalFields() throws {
    let tool = try #require(CalendarTools().handlers.first { $0.name == "calendar.update_event" })
    #expect(!ToolArguments.isValid(.object(["event_id": .string("fixture"), "all_day": .string("false")]), schema: tool.spec.inputSchema))
    #expect(!ToolArguments.isValid(.object(["event_id": .string("fixture"), "calendar_id": .string("wrong")]), schema: tool.spec.inputSchema))
    #expect(ToolArguments.isValid(.object(["event_id": .string("fixture"), "notes": .null]), schema: tool.spec.inputSchema))
}

@Test func existingExternalContentInWriteResponsesIsUntrusted() {
    let names: Set<String> = ["calendar.create_event", "calendar.update_event", "contacts.update", "contacts.list_groups",
                             "reminders.list_lists", "reminders.update_reminder", "reminders.complete_reminder"]
    let handlers = CalendarTools().handlers + ContactsTools().handlers + RemindersTools().handlers
    for tool in handlers where names.contains(tool.name) { #expect(tool.returnsUntrustedContent, "\(tool.name)") }
}

@Test func driveRejectsSymlinkParentsBeforeCreatingFiles() async throws {
    let fm = FileManager.default
    let fixture = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let root = fixture.appendingPathComponent("root")
    let outside = fixture.appendingPathComponent("outside")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: fixture) }
    try fm.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
    let adapter = DriveAdapter(root: root)
    do {
        _ = try await adapter.write(path: "escape/new/file.txt", content: "test", createDirs: true)
        Issue.record("symlink escape accepted")
    } catch is DrivePath.DrivePathError {}
    #expect(!fm.fileExists(atPath: outside.appendingPathComponent("new").path))
    try fm.createSymbolicLink(at: root.appendingPathComponent("dangling"), withDestinationURL: outside.appendingPathComponent("missing"))
    #expect(throws: (any Error).self) { try DrivePath.resolve("dangling/file", root: root) }
    #expect(throws: (any Error).self) { try DrivePath.resolve("bad\0name", root: root) }
}

@Test func driveTestsRealSandboxAndRecursivePaths() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let adapter = DriveAdapter(settings: .init(writeAllowedPrefixes: ["allowed"]), root: root)
    _ = try await adapter.write(path: "allowed/sub/file.txt", content: "test", createDirs: true)
    do {
        _ = try await adapter.write(path: "allowed-other/file.txt", content: "test", createDirs: true)
        Issue.record("prefix escape accepted")
    } catch is DriveAdapter.DriveError {}
    let items = try await adapter.list(path: "", recursive: true)
    #expect(items.contains { $0.path == "allowed/sub/file.txt" }, "paths: \(items.map(\.path))")
    do {
        _ = try await adapter.write(path: "allowed/sub/file.txt", content: "replacement")
        Issue.record("create overwrote an existing file")
    } catch is DriveAdapter.DriveError {}
    let content = try await adapter.read(path: "allowed/sub/file.txt")
    #expect(content.content == "test")
}

@Test func subprocessDrainsLargeOutputAndTimesOut() async throws {
    let result = try await Subprocess.run("/usr/bin/head", arguments: ["-c", "200000", "/dev/zero"], timeoutSeconds: 5)
    #expect(result.exitCode == 0)
    #expect(result.stdout.utf8.count == 200000)
    do {
        _ = try await Subprocess.run("/bin/sleep", arguments: ["10"], timeoutSeconds: 0.05)
        Issue.record("subprocess ignored timeout")
    } catch Subprocess.Failure.timeout {}
    do {
        _ = try await Subprocess.run("/usr/bin/head", arguments: ["-c", "200000", "/dev/zero"], maxOutputBytes: 1024)
        Issue.record("subprocess ignored output cap")
    } catch Subprocess.Failure.outputLimit {}
}

@Test func privateFileReplacementKeeps0600AndDoesNotFollowDestinationSymlink() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let target = dir.appendingPathComponent("private")
    let other = dir.appendingPathComponent("other")
    try Data("unchanged".utf8).write(to: other)
    try fm.createSymbolicLink(at: target, withDestinationURL: other)
    try PrivateFile.write(Data("secret-fixture".utf8), to: target)
    #expect(try String(contentsOf: other, encoding: .utf8) == "unchanged")
    #expect(try String(contentsOf: target, encoding: .utf8) == "secret-fixture")
    #expect(try fm.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int == 0o600)
    #expect(try fm.contentsOfDirectory(atPath: dir.path).sorted() == ["other", "private"])
}

private struct ContextEchoTool: ToolHandler {
    let name = "test.context"
    let spec = Tool(name: "test.context", description: "Fixture", inputSchema: .object(["type": .string("object")]))
    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        .init(content: [.text(text: BridgeCallContext.override?.auditCaller ?? "missing", annotations: nil, _meta: nil)])
    }
}
private struct ContextProvider: ToolProvider {
    let handlers: [any ToolHandler] = [ContextEchoTool()]
}

private func collectSSE(_ response: MCP.HTTPResponse) async throws -> String {
    if case .stream(let stream, _) = response {
        var result = ""
        for try await data in stream { result += String(decoding: data, as: UTF8.self) }
        return result
    }
    return response.bodyData.map { String(decoding: $0, as: UTF8.self) } ?? ""
}

@Test(.timeLimit(.minutes(1))) func actualSDKTransportPreservesPerCallContextAcrossReceiveQueue() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let auth = AuthContext(transport: .loopback, identity: .bearer(tokenLabel: "fixture"), remoteDescription: "loopback")
    let policy = PolicyPipeline(config: .init(acl: .init(tools: ["test.context": .allow])), audit: AuditSink(url: url))
    let contexts = RequestContextStore()
    let server = await MCPHostBuilder(providers: [ContextProvider()]).build(auth: auth, policy: policy, contexts: contexts)
    let transport = SessionHolder.makeTransport(allowedHosts: ["100.90.1.1:8787"], logger: Logger(label: "test"))
    try await server.start(transport: transport)
    defer { Task { await server.stop() } }
    var headers = ["Host": "100.90.1.1:8787", "Accept": "application/json, text/event-stream", "Content-Type": "application/json"]
    let initial = await transport.handleRequest(.init(method: "POST", headers: headers, body: Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"review-tests","version":"1"}}}"#.utf8)))
    _ = try await collectSSE(initial)
    let session = try #require(initial.headers.first { $0.key.lowercased() == "mcp-session-id" }?.value)
    headers["Mcp-Session-Id"] = session
    _ = await transport.handleRequest(.init(method: "POST", headers: headers,
        body: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)))
    let peer = AuthContext(transport: .tailnet, identity: .tailscale(peer: "test-peer", user: "fixture"), remoteDescription: "tailnet")
    let call = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"test.context","arguments":{},"_meta":{"deckard/internal-context":"forged"}}}"#.utf8)
    let prepared = try contexts.prepare(call, auth: peer)
    let response = await transport.handleRequest(.init(method: "POST", headers: headers, body: prepared))
    let text = try await collectSSE(response)
    #expect(text.contains("ts:test-peer:fixture"), "actual SDK dispatch must see the trusted HTTP context")
    let audit = try String(contentsOf: url, encoding: .utf8)
    #expect(audit.contains("\"transport\":\"tailnet\""))
    #expect(audit.contains("ts:test-peer:fixture"))
    await server.stop()
}

@Test func requestContextReferencesAreSingleUseAndCannotBeForged() throws {
    let store = RequestContextStore()
    let auth = AuthContext(transport: .loopback, identity: .bearer(tokenLabel: "fixture"), remoteDescription: "fixture")
    let body = Data(#"{"method":"tools/call","params":{"name":"health.ping","_meta":{"deckard/internal-context":"forged"}}}"#.utf8)
    let data = try store.prepare(body, auth: auth)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let params = json["params"] as! [String: Any]
    let meta = params["_meta"] as! [String: Any]
    let id = try #require(meta[RequestContextStore.metadataKey] as? String)
    #expect(id != "forged")
    #expect(store.consume("forged") == nil)
    #expect(store.consume(id) == auth)
    #expect(store.consume(id) == nil)
}

@Test func disabledAuditCreatesNoFiles() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let sink = AuditSink(url: dir.appendingPathComponent("audit.jsonl"), enabled: false)
    let event = AuditEvent(ts: "2026-01-01T00:00:00.000Z", caller: "fixture", transport: "stdio", tool: "health.ping",
                          argKeys: [], decision: "allow", latencyMs: 0, resultBytes: 0, error: nil)
    await sink.record(event)
    #expect(!FileManager.default.fileExists(atPath: dir.path))
}

@Test func auditPrunePreservesMalformedEvidenceAndHandlesWhitespace() async throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let url = dir.appendingPathComponent("audit.jsonl")
    let text = "{\"ts\" : \"2001-01-01T00:00:00.000Z\"}\nmalformed evidence\n"
    try text.write(to: url, atomically: true, encoding: .utf8)
    let result = await AuditSink(url: url).prune(retentionDays: 30)
    #expect(result.removed == 1)
    #expect(result.kept == 1)
    #expect(try String(contentsOf: url, encoding: .utf8) == "malformed evidence\n")
}

@Test func documentedOpenClawProfileGrantsOnlySupervisedCalendarAccess() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let config = try ConfigStore(url: repository.appendingPathComponent("docs/examples/openclaw-calendar.toml")).load()
    let profile = try #require(config.acl.profiles["openclaw-calendar"])
    #expect(profile.default == .deny)
    #expect(profile.interactiveApproval == .always)
    #expect(profile.tools.count == 9)
    #expect(profile.decision(for: "health.ping") == .allow)
    for tool in CalendarTools().handlers {
        #expect(profile.decision(for: tool.name) == (["calendar.create_event", "calendar.update_event", "calendar.delete_event"].contains(tool.name) ? .approve : .allow))
    }
    for name in ["mail.send", "drive.read", "contacts.search", "reminders.list_lists", "future.tool"] {
        #expect(profile.decision(for: name) == .deny)
    }
}
