import Foundation
import Logging
import Hummingbird
import HTTPTypes
import MCP
import BridgeAuth
import BridgeConfig

/// Runs an MCP server over HTTP, bound to 127.0.0.1 by default.
///
/// HTTPRunner is multi-tenant: each authenticated bearer token resolves to its
/// own `SessionHolder` (with its own MCP Server, ACL profile, and AuthContext).
/// This keeps audit identities clean ("bearer:rocky" vs "bearer:eleanor") and
/// lets per-token profiles enforce different ACLs without per-call dispatch
/// gymnastics inside the SDK.
public struct HTTPRunner: Sendable {
    public struct Bind: Sendable {
        public let host: String
        public let port: Int
        public let transportLabel: AuthContext.Transport
        public init(host: String, port: Int, transportLabel: AuthContext.Transport) {
            self.host = host
            self.port = port
            self.transportLabel = transportLabel
        }
    }

    private let bind: Bind
    private let sessions: TokenSessions
    private let requireToken: Bool
    private let logger: Logger

    public init(
        bind: Bind,
        sessions: TokenSessions,
        requireToken: Bool,
        logger: Logger = Logger(label: "bridge.http")
    ) {
        self.bind = bind
        self.sessions = sessions
        self.requireToken = requireToken
        self.logger = logger
    }

    public func run() async throws {
        let runnerLogger = logger
        let sessions = self.sessions
        let requireToken = self.requireToken

        let router = Router()
        router.on("/mcp", method: .post) { req, ctx -> Response in
            try await Self.handle(req: req, ctx: ctx, sessions: sessions, requireToken: requireToken, logger: runnerLogger)
        }
        router.on("/mcp", method: .get) { req, ctx -> Response in
            try await Self.handle(req: req, ctx: ctx, sessions: sessions, requireToken: requireToken, logger: runnerLogger)
        }
        router.on("/mcp", method: .delete) { req, ctx -> Response in
            try await Self.handle(req: req, ctx: ctx, sessions: sessions, requireToken: requireToken, logger: runnerLogger)
        }

        // Catch-all for unrouted paths (OAuth discovery probes, etc.).
        // Returns a JSON 404 so client SDKs that JSON-parse the body don't
        // explode with "Unexpected EOF".
        router.on("/**", method: .get) { _, _ -> Response in
            Self.notFoundJSON()
        }

        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname(bind.host, port: bind.port),
                serverName: "icloud-bridge"
            ),
            logger: logger
        )
        logger.info("HTTP server binding \(bind.host):\(bind.port) (tokens=\(sessions.count))")
        try await app.runService()
    }

    private static func handle(
        req: Request,
        ctx: BasicRequestContext,
        sessions: TokenSessions,
        requireToken: Bool,
        logger: Logger
    ) async throws -> Response {
        var resolvedHolder: SessionHolder?
        if requireToken {
            guard let token = extractBearer(from: req.headers) else {
                return unauthorized(reason: "missing_token", message: "Missing bearer token")
            }
            guard let entry = sessions.entry(for: token) else {
                return unauthorized(reason: "invalid_token", message: "Invalid bearer token")
            }
            resolvedHolder = entry.holder
        } else {
            // require_token = false (rare/dev). Pick the first available
            // session holder. With no token, identity is unknowable.
            resolvedHolder = sessions.entry(for: "")?.holder
            if resolvedHolder == nil {
                return jsonError(status: .internalServerError, message: "No session holder configured")
            }
        }

        guard let holder = resolvedHolder else {
            return unauthorized(reason: "invalid_token", message: "Invalid bearer token")
        }

        let bodyData: Data
        do {
            let buffer = try await req.body.collect(upTo: 4 * 1024 * 1024) // 4 MiB cap
            bodyData = Data(buffer: buffer)
        } catch {
            return jsonError(status: .contentTooLarge, message: "Body read failed: \(error)")
        }

        var headers: [String: String] = [:]
        for field in req.headers {
            headers[field.name.canonicalName] = field.value
        }

        let mcpRequest = MCP.HTTPRequest(
            method: req.method.rawValue,
            headers: headers,
            body: bodyData.isEmpty ? nil : bodyData,
            path: req.uri.path
        )

        let transport = await holder.currentTransport()
        var mcpResponse = await transport.handleRequest(mcpRequest)

        // Self-heal: the SDK's StatefulHTTPServerTransport keeps a session in
        // memory across MCP-client reconnects and rejects fresh initialize
        // calls with 400 "Session already initialized." When we see that, tear
        // down and recreate the transport+server pair, then retry once.
        if isStaleSessionError(mcpResponse, request: mcpRequest) {
            logger.info("Stale MCP session detected; recreating transport in place")
            do {
                try await holder.recreate()
                let fresh = await holder.currentTransport()
                mcpResponse = await fresh.handleRequest(mcpRequest)
            } catch {
                logger.error("Failed to recreate transport: \(error)")
            }
        }

        return convert(mcpResponse, logger: logger)
    }

    private static func isStaleSessionError(_ response: MCP.HTTPResponse, request: MCP.HTTPRequest) -> Bool {
        guard response.statusCode == 400 else { return false }
        guard request.method.uppercased() == "POST" else { return false }
        guard let body = response.bodyData,
              let s = String(data: body, encoding: .utf8) else { return false }
        return s.contains("Session already initialized")
    }

    private static func extractBearer(from headers: HTTPFields) -> String? {
        guard let raw = headers[.authorization] else { return nil }
        let prefix = "Bearer "
        guard raw.hasPrefix(prefix) else { return nil }
        return String(raw.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func convert(_ response: MCP.HTTPResponse, logger: Logger) -> Response {
        var fields = HTTPFields()
        for (k, v) in response.headers {
            if let name = HTTPField.Name(k) {
                fields.append(HTTPField(name: name, value: v))
            }
        }
        let status = HTTPResponse.Status(code: response.statusCode)

        switch response {
        case .accepted, .ok:
            return Response(status: status, headers: fields, body: .init())
        case .data(let data, _):
            let buffer = ByteBuffer(data: data)
            return Response(status: status, headers: fields, body: .init(byteBuffer: buffer))
        case .error(_, _, _, _):
            if let body = response.bodyData {
                let buffer = ByteBuffer(data: body)
                return Response(status: status, headers: fields, body: .init(byteBuffer: buffer))
            }
            return Response(status: status, headers: fields, body: .init())
        case .stream(let stream, _):
            let body = ResponseBody { writer in
                for try await chunk in stream {
                    try await writer.write(ByteBuffer(data: chunk))
                }
                try await writer.finish(nil)
            }
            return Response(status: status, headers: fields, body: body)
        }
    }

    private static func jsonError(status: HTTPResponse.Status, message: String) -> Response {
        let json = "{\"error\":\"\(message)\"}"
        var fields = HTTPFields()
        fields.append(HTTPField(name: .contentType, value: "application/json"))
        return Response(status: status, headers: fields, body: .init(byteBuffer: ByteBuffer(string: json)))
    }

    /// 401 with a `WWW-Authenticate: Bearer` header so MCP clients fall back to
    /// the bearer token in their config instead of attempting OAuth discovery
    /// (RFC 6750).
    private static func unauthorized(reason: String, message: String) -> Response {
        let json = #"{"error":"\#(message)"}"#
        var fields = HTTPFields()
        fields.append(HTTPField(name: .contentType, value: "application/json"))
        fields.append(HTTPField(
            name: .wwwAuthenticate,
            value: #"Bearer realm="icloud-bridge", error="\#(reason)""#
        ))
        return Response(status: .unauthorized, headers: fields, body: .init(byteBuffer: ByteBuffer(string: json)))
    }

    /// JSON 404 for any unrouted path (e.g. OAuth discovery probes).
    static func notFoundJSON() -> Response {
        let json = #"{"error":"not_found","auth":"bearer","oauth":false}"#
        var fields = HTTPFields()
        fields.append(HTTPField(name: .contentType, value: "application/json"))
        return Response(status: .notFound, headers: fields, body: .init(byteBuffer: ByteBuffer(string: json)))
    }
}
