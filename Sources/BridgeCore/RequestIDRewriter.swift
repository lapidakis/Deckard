import Foundation
import MCP

/// Gives each JSON-RPC request a unique id for its trip through the SDK's
/// stateless transport, then puts the caller's own id back on the response.
///
/// Why: `StatelessHTTPServerTransport` keeps one waiter per request id. One
/// transport serves every client of an identity, and unrelated clients all
/// count from 1, so two in-flight requests with the same id would overwrite
/// each other's waiter — one caller hangs, and the other's response can reach
/// the wrong connection. Unique ids make that impossible.
///
/// Consequence: a client's `notifications/cancelled` names an id the server
/// never saw, so cancellation is not honoured. Deckard's tools are short
/// request/response calls and did not act on cancellation before either.
enum RequestIDRewriter {
    /// What `restore` needs: the unique id's JSON token as it appears in the
    /// response, and the caller's original id as a JSON token (number or
    /// string, exactly as sent).
    struct OriginalID: Sendable {
        let uniqueToken: Data
        let originalToken: Data
    }

    /// Returns the body with a unique id, plus what is needed to restore the
    /// original. Notifications, responses and non-JSON bodies pass through.
    static func rewrite(_ body: Data) -> (body: Data, originalID: OriginalID?) {
        guard !body.isEmpty,
              var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              json["method"] is String,
              let id = json["id"], !(id is NSNull),
              let originalToken = try? JSONSerialization.data(withJSONObject: id, options: [.fragmentsAllowed])
        else { return (body, nil) }
        // Hex only, so the token is byte-identical however it is re-encoded.
        let unique = "dk-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        json["id"] = unique
        guard let encoded = try? JSONSerialization.data(withJSONObject: json) else { return (body, nil) }
        return (encoded, OriginalID(uniqueToken: Data("\"\(unique)\"".utf8), originalToken: originalToken))
    }

    /// Puts the caller's id back by swapping the unique token in the response
    /// bytes. A targeted replace rather than a parse-and-reserialize: results
    /// can be tens of megabytes (base64 audio), and the unique id cannot occur
    /// anywhere else because tools never see request ids.
    static func restore(_ response: MCP.HTTPResponse, originalID: OriginalID?) -> MCP.HTTPResponse {
        guard let originalID, case .data(var data, let headers) = response,
              let range = data.range(of: originalID.uniqueToken) else { return response }
        data.replaceSubrange(range, with: originalID.originalToken)
        return .data(data, headers: headers)
    }
}
