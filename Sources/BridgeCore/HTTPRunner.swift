import Foundation
import Logging
import Hummingbird
import HTTPTypes
import NIOCore
import MCP
import BridgeAuth
import BridgeConfig

/// Runs an MCP server over HTTP, bound to 127.0.0.1 by default.
///
/// HTTPRunner is multi-tenant: each authenticated bearer token resolves to its
/// own `SessionHolder` (with its own MCP Server, ACL profile, and AuthContext).
/// This keeps audit identities clean ("bearer:host" vs "bearer:triage") and
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

    /// Per-listener Tailscale state. Loopback runners pass `nil`; the
    /// tailnet runner gets a probe so `tailscale whois` can resolve the
    /// source IP to a peer name + user for audit attribution. The bridge
    /// does NOT enforce its own peer allowlist — if a request reaches the
    /// listener, tailscaled's ACLs have already permitted it. Bearer auth
    /// still applies.
    public struct TailscaleEnforcement: Sendable {
        public let probe: TailscaleProbe
        public init(probe: TailscaleProbe) {
            self.probe = probe
        }
    }

    private let bind: Bind
    private let sessions: TokenSessions
    private let requireToken: Bool
    private let tailscale: TailscaleEnforcement?
    private let logger: Logger

    public init(
        bind: Bind,
        sessions: TokenSessions,
        requireToken: Bool,
        tailscale: TailscaleEnforcement? = nil,
        logger: Logger = Logger(label: "bridge.http")
    ) {
        self.bind = bind
        self.sessions = sessions
        self.requireToken = requireToken
        self.tailscale = tailscale
        self.logger = logger
    }

    public func run() async throws {
        let runnerLogger = logger
        let sessions = self.sessions
        let requireToken = self.requireToken
        let bind = self.bind
        let tailscale = self.tailscale

        let router = Router(context: PeerAwareRequestContext.self)
        router.on("/mcp", method: .post) { req, ctx -> Response in
            try await Self.handle(
                req: req, ctx: ctx, bind: bind, sessions: sessions,
                requireToken: requireToken, tailscale: tailscale, logger: runnerLogger
            )
        }
        router.on("/mcp", method: .get) { req, ctx -> Response in
            try await Self.handle(
                req: req, ctx: ctx, bind: bind, sessions: sessions,
                requireToken: requireToken, tailscale: tailscale, logger: runnerLogger
            )
        }
        router.on("/mcp", method: .delete) { req, ctx -> Response in
            try await Self.handle(
                req: req, ctx: ctx, bind: bind, sessions: sessions,
                requireToken: requireToken, tailscale: tailscale, logger: runnerLogger
            )
        }

        // Catch-all for unrouted paths (OAuth discovery probes, etc.).
        // Returns a JSON 404 so client SDKs that JSON-parse the body don't
        // explode with "Unexpected EOF".
        router.on("/**", method: .get) { _, _ -> Response in
            Self.notFoundJSON()
        }

        // Idle timeout reaps abandoned TCP channels (peer FIN'd but never sent
        // a clean close, or a half-open NAT survivor) so they don't accumulate
        // in CLOSE_WAIT and exhaust the process FD table. HTTPUserEventHandler
        // only closes on this event when `requestsBeingRead > 0` or
        // `requestsInProgress == 0`, so a long-running tool call mid-response
        // is safe; only genuinely idle channels get dropped.
        let app = Application(
            router: router,
            server: .http1(configuration: .init(idleTimeout: .seconds(60))),
            configuration: .init(
                address: .hostname(bind.host, port: bind.port),
                serverName: "deckard"
            ),
            logger: logger
        )
        logger.info("HTTP server binding \(bind.host):\(bind.port) transport=\(bind.transportLabel.rawValue) tokens=\(sessions.count)\(tailscale.map { _ in " tailscale=whois-only" } ?? "")")
        try await app.runService()
    }

    private static func handle(
        req: Request,
        ctx: PeerAwareRequestContext,
        bind: Bind,
        sessions: TokenSessions,
        requireToken: Bool,
        tailscale: TailscaleEnforcement?,
        logger: Logger
    ) async throws -> Response {
        let remoteIP = ctx.remoteAddress?.ipAddress

        // Tailnet listener: best-effort whois so the audit row can attribute
        // "ts:laptop:user@github" instead of just an IP. Tailnet ACLs are
        // tailscaled's job; reaching the listener at all means the peer has
        // already been permitted by your tailnet policy. Failed whois is not
        // an error — the listener still serves the request and audit just
        // records the raw IP.
        var resolvedPeer: TailscaleProbe.PeerInfo? = nil
        if let ts = tailscale, let ip = remoteIP {
            resolvedPeer = await ts.probe.whois(remoteIP: ip)
        }

        var resolvedHolder: SessionHolder?
        var resolvedLabel: String?
        if requireToken {
            guard let token = extractBearer(from: req.headers) else {
                return unauthorized(reason: "missing_token", message: "Missing bearer token")
            }
            guard let entry = sessions.entry(for: token) else {
                return unauthorized(reason: "invalid_token", message: "Invalid bearer token")
            }
            resolvedHolder = entry.holder
            resolvedLabel = entry.label
        } else {
            // require_token = false (rare/dev). Pick the first available
            // session holder. With no token, identity is unknowable.
            resolvedHolder = sessions.entry(for: "")?.holder
            resolvedLabel = sessions.entry(for: "")?.label
            if resolvedHolder == nil {
                return jsonError(status: .internalServerError, message: "No session holder configured")
            }
        }

        guard let holder = resolvedHolder, let label = resolvedLabel else {
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

        // Build the per-call AuthContext: transport reflects the listener that
        // received this request, identity adopts a `.tailscale(...)` flavor
        // when whois succeeded so audit rows can attribute "ts:laptop:user"
        // instead of just "bearer:host", and remoteDescription captures the
        // raw IP for forensic use.
        let perCallAuth = makePerCallAuth(
            bind: bind, label: label, remoteIP: remoteIP, peer: resolvedPeer
        )

        let transport = await holder.currentTransport()
        var mcpResponse = await BridgeCallContext.$override.withValue(perCallAuth) {
            await transport.handleRequest(mcpRequest)
        }

        // Self-heal: the SDK's StatefulHTTPServerTransport keeps a session in
        // memory across MCP-client reconnects and rejects fresh initialize
        // calls with 400 "Session already initialized." When we see that, tear
        // down and recreate the transport+server pair, then retry once.
        if isStaleSessionError(mcpResponse, request: mcpRequest) {
            // Some clients re-`initialize` on every request instead of reusing
            // the session ID. The self-heal path handles it correctly; log at
            // .debug so stderr doesn't fill with thousands of these per day.
            logger.debug("Stale MCP session detected; recreating transport in place")
            do {
                try await holder.recreate()
                let fresh = await holder.currentTransport()
                mcpResponse = await BridgeCallContext.$override.withValue(perCallAuth) {
                    await fresh.handleRequest(mcpRequest)
                }
            } catch {
                logger.error("Failed to recreate transport: \(error)")
            }
        }

        return convert(mcpResponse, logger: logger)
    }

    static func makePerCallAuth(
        bind: Bind,
        label: String,
        remoteIP: String?,
        peer: TailscaleProbe.PeerInfo?
    ) -> AuthContext {
        let transport = bind.transportLabel
        let identity: AuthContext.Identity
        if transport == .tailnet, let peer = peer, peer.hostname != nil || peer.user != nil {
            identity = .tailscale(peer: peer.hostname ?? peer.ip, user: peer.user)
        } else {
            identity = .bearer(tokenLabel: label)
        }
        let remoteDescription: String
        switch transport {
        case .tailnet:
            if let p = peer {
                let host = p.hostname ?? p.ip
                let user = p.user.map { ":\($0)" } ?? ""
                remoteDescription = "tailnet:\(host)\(user)"
            } else {
                remoteDescription = "tailnet:\(remoteIP ?? "?")"
            }
        case .loopback:
            remoteDescription = remoteIP ?? "127.0.0.1"
        case .stdio:
            remoteDescription = remoteIP ?? "stdio"
        }
        return AuthContext(
            transport: transport,
            identity: identity,
            remoteDescription: remoteDescription
        )
    }

    private static func isStaleSessionError(_ response: MCP.HTTPResponse, request: MCP.HTTPRequest) -> Bool {
        guard response.statusCode == 400 else { return false }
        guard request.method.uppercased() == "POST" else { return false }
        guard let body = response.bodyData,
              let s = String(data: body, encoding: .utf8) else { return false }
        return s.contains("Session already initialized")
    }

    static func extractBearer(from headers: HTTPFields) -> String? {
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

    static func jsonError(status: HTTPResponse.Status, message: String) -> Response {
        let json = "{\"error\":\"\(message)\"}"
        var fields = HTTPFields()
        fields.append(HTTPField(name: .contentType, value: "application/json"))
        return Response(status: status, headers: fields, body: .init(byteBuffer: ByteBuffer(string: json)))
    }

    /// 401 with a `WWW-Authenticate: Bearer` header so MCP clients fall back to
    /// the bearer token in their config instead of attempting OAuth discovery
    /// (RFC 6750).
    static func unauthorized(reason: String, message: String) -> Response {
        let json = #"{"error":"\#(message)"}"#
        var fields = HTTPFields()
        fields.append(HTTPField(name: .contentType, value: "application/json"))
        fields.append(HTTPField(
            name: .wwwAuthenticate,
            value: #"Bearer realm="deckard", error="\#(reason)""#
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

/// Custom Hummingbird request context that exposes the connecting peer's
/// `SocketAddress`. The remote IP feeds `tailscale whois` so audit rows
/// resolve to peer hostnames, and gives loopback audit rows a precise
/// `remoteDescription`.
public struct PeerAwareRequestContext: Hummingbird.RequestContext, RemoteAddressRequestContext {
    public var coreContext: CoreRequestContextStorage
    public let remoteAddress: SocketAddress?

    public init(source: ApplicationRequestContextSource) {
        self.coreContext = .init(source: source)
        self.remoteAddress = source.channel.remoteAddress
    }
}
