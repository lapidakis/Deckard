import Foundation
import Logging
import Hummingbird
import HTTPTypes
import MCP
import BridgeAuth
import BridgeConfig

/// Runs an MCP server over HTTP, bound to 127.0.0.1 by default.
///
/// The HTTP server is a thin Hummingbird app whose only route is `POST/GET/DELETE
/// /mcp`. Each request is authenticated, then forwarded to the SDK's
/// `StatefulHTTPServerTransport.handleRequest`.
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
    private let builder: MCPHostBuilder
    private let tokenStore: TokenStore
    private let requireToken: Bool
    private let logger: Logger

    public init(
        bind: Bind,
        builder: MCPHostBuilder,
        tokenStore: TokenStore,
        requireToken: Bool,
        logger: Logger = Logger(label: "bridge.http")
    ) {
        self.bind = bind
        self.builder = builder
        self.tokenStore = tokenStore
        self.requireToken = requireToken
        self.logger = logger
    }

    public func run() async throws {
        let auth = AuthContext(
            transport: bind.transportLabel,
            identity: .bearer(tokenLabel: "default"),
            remoteDescription: "\(bind.host):\(bind.port)"
        )
        // SessionHolder owns the transport+server pair and can recreate it
        // when the SDK refuses a fresh `initialize` because a stale session
        // is still in memory. Without this, every Claude Code restart on the
        // client side requires a daemon bounce.
        let holder = try await SessionHolder(builder: builder, auth: auth, logger: logger)

        let runnerLogger = logger
        let tokenStore = self.tokenStore
        let requireToken = self.requireToken

        let router = Router()
        router.on("/mcp", method: .post) { req, ctx -> Response in
            try await Self.handle(
                req: req, ctx: ctx, holder: holder,
                tokenStore: tokenStore, requireToken: requireToken,
                logger: runnerLogger
            )
        }
        router.on("/mcp", method: .get) { req, ctx -> Response in
            try await Self.handle(
                req: req, ctx: ctx, holder: holder,
                tokenStore: tokenStore, requireToken: requireToken,
                logger: runnerLogger
            )
        }
        router.on("/mcp", method: .delete) { req, ctx -> Response in
            try await Self.handle(
                req: req, ctx: ctx, holder: holder,
                tokenStore: tokenStore, requireToken: requireToken,
                logger: runnerLogger
            )
        }

        // Catch-all for unrouted paths (OAuth discovery probes, etc.).
        // Returns a JSON 404 so client SDKs that JSON-parse the body don't
        // explode with "Unexpected EOF". Path "/**" matches everything not
        // already routed above.
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
        logger.info("HTTP server binding \(bind.host):\(bind.port)")
        try await app.runService()
    }

    private static func handle(
        req: Request,
        ctx: BasicRequestContext,
        holder: SessionHolder,
        tokenStore: TokenStore,
        requireToken: Bool,
        logger: Logger
    ) async throws -> Response {
        if requireToken {
            guard let token = extractBearer(from: req.headers) else {
                return unauthorized(reason: "missing_token", message: "Missing bearer token")
            }
            let ok: Bool
            do { ok = try await tokenStore.verify(token) } catch { ok = false }
            guard ok else {
                return unauthorized(reason: "invalid_token", message: "Invalid bearer token")
            }
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
    /// (RFC 6750). Without this, Claude Code's MCP SDK probes
    /// `/.well-known/oauth-protected-resource`, parses the empty 404 body as a
    /// JSON OAuth error, and surfaces a confusing "JSON Parse error" auth failure.
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

    /// JSON 404 for any unrouted path (e.g. OAuth discovery probes). Empty
    /// bodies trip MCP clients that try to parse the response as JSON.
    static func notFoundJSON() -> Response {
        let json = #"{"error":"not_found","auth":"bearer","oauth":false}"#
        var fields = HTTPFields()
        fields.append(HTTPField(name: .contentType, value: "application/json"))
        return Response(status: .notFound, headers: fields, body: .init(byteBuffer: ByteBuffer(string: json)))
    }
}

/// Holds the MCP transport+server pair and recreates them when the SDK's
/// session state becomes stale. Actor-isolated so concurrent requests racing
/// to recreate end up with a single fresh pair.
private actor SessionHolder {
    private var transport: StatefulHTTPServerTransport
    private var server: Server
    private let builder: MCPHostBuilder
    private let auth: AuthContext
    private let logger: Logger

    init(builder: MCPHostBuilder, auth: AuthContext, logger: Logger) async throws {
        self.builder = builder
        self.auth = auth
        self.logger = logger
        self.transport = StatefulHTTPServerTransport(logger: logger)
        self.server = await builder.build(auth: auth)
        try await self.server.start(transport: self.transport)
    }

    func currentTransport() -> StatefulHTTPServerTransport { transport }

    func recreate() async throws {
        await server.stop()
        await transport.disconnect()
        self.transport = StatefulHTTPServerTransport(logger: logger)
        self.server = await builder.build(auth: auth)
        try await self.server.start(transport: transport)
    }
}
