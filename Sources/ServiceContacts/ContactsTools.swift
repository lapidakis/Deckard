import Foundation
import MCP
import BridgeCore

/// MCP tool handlers for Contacts.app via the Contacts framework.
public struct ContactsTools: ToolProvider {
    public let handlers: [any ToolHandler]

    public init(adapter: ContactsAdapter = ContactsAdapter()) {
        self.handlers = [
            SearchContactsTool(adapter: adapter),
            GetContactTool(adapter: adapter),
            ListGroupsTool(adapter: adapter),
            ListInGroupTool(adapter: adapter),
            CreateContactTool(adapter: adapter),
            UpdateContactTool(adapter: adapter),
            DeleteContactTool(adapter: adapter),
            SetGroupsTool(adapter: adapter),
        ]
    }
}

// MARK: - Read

struct SearchContactsTool: ToolHandler {
    let name = "contacts.search"
    let returnsUntrustedContent = true
    let spec = Tool(
        name: "contacts.search",
        description: """
        Search the address book for contacts matching `query`. By default
        searches names, email addresses, and phone numbers; pass `kind` to
        scope to one. Returns lightweight summaries (id, display name,
        organization, primary email/phone). Call `contacts.get` for full
        details on a specific id.

        Capped at limit (default 50, max 200). Untrusted content — values
        come from address-book entries the user did not author themselves
        in this session.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string")]),
                "kind":  .object([
                    "type": .string("string"),
                    "enum": .array([.string("any"), .string("name"), .string("email"), .string("phone")]),
                ]),
                "limit": .object(["type": .string("integer")]),
            ]),
            "required": .array([.string("query")]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: ContactsAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let query = arguments?["query"]?.stringValue else {
            return contactsErrorResult("query is required")
        }
        let kindRaw = arguments?["kind"]?.stringValue ?? "any"
        let kind = ContactsAdapter.SearchFilter.Kind(rawValue: kindRaw) ?? .any
        let limit = max(1, min(200, arguments?["limit"]?.intValue ?? 50))
        let filter = ContactsAdapter.SearchFilter(query: query, kind: kind, limit: limit)
        let results = try await adapter.search(filter)
        return contactsJSON(results)
    }
}

struct GetContactTool: ToolHandler {
    let name = "contacts.get"
    let returnsUntrustedContent = true
    let spec = Tool(
        name: "contacts.get",
        description: """
        Fetch one contact by id. Returns the full record: name fields,
        organization, phones, emails, urls, postal addresses, social
        profiles, IM handles, birthday, dates, and group memberships.

        The `note` field is always null — fetching contact notes requires
        an Apple-granted entitlement Deckard does not currently hold.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: ContactsAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let id = arguments?["id"]?.stringValue else {
            return contactsErrorResult("id is required")
        }
        let detail = try await adapter.get(id: id)
        return contactsJSON(detail)
    }
}

struct ListGroupsTool: ToolHandler {
    let name = "contacts.list_groups"
    let spec = Tool(
        name: "contacts.list_groups",
        description: "List every contact group with its id, name, and current member count.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: ContactsAdapter

    func call(arguments _: [String: Value]?) async throws -> CallTool.Result {
        let groups = try await adapter.listGroups()
        return contactsJSON(groups)
    }
}

struct ListInGroupTool: ToolHandler {
    let name = "contacts.list_in_group"
    let returnsUntrustedContent = true
    let spec = Tool(
        name: "contacts.list_in_group",
        description: """
        List contacts in a single group. Returns summaries (same shape as
        `contacts.search`). Capped at limit (default 200, max 1000).
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "group_id": .object(["type": .string("string")]),
                "limit":    .object(["type": .string("integer")]),
            ]),
            "required": .array([.string("group_id")]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: ContactsAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let id = arguments?["group_id"]?.stringValue else {
            return contactsErrorResult("group_id is required")
        }
        let limit = max(1, min(1000, arguments?["limit"]?.intValue ?? 200))
        let results = try await adapter.listInGroup(groupId: id, limit: limit)
        return contactsJSON(results)
    }
}

// MARK: - Write

/// Schema fragment for a labeled value (phone/email/url). Reused across
/// create/update tool schemas so the shape stays uniform.
private let labeledValueSchema: Value = .object([
    "type": .string("object"),
    "properties": .object([
        "label": .object(["type": .string("string")]),
        "value": .object(["type": .string("string")]),
    ]),
    "required": .array([.string("value")]),
    "additionalProperties": .bool(false),
])

private func decodeLabeledArray(_ v: Value?) -> [LabeledString] {
    guard case .array(let items) = v else { return [] }
    return items.compactMap { item -> LabeledString? in
        guard case .object(let dict) = item else { return nil }
        guard let value = dict["value"]?.stringValue else { return nil }
        let label = dict["label"]?.stringValue
        return LabeledString(label: label, value: value)
    }
}

struct CreateContactTool: ToolHandler, ApprovalSummarizing {
    let name = "contacts.create"
    let spec = Tool(
        name: "contacts.create",
        description: """
        Create a new contact. WRITE — recommended ACL is `approve`.

        At least one of given_name, family_name, or organization is
        required. Phones, emails, and urls accept arrays of {label, value};
        label is optional and accepts friendly strings (\"home\", \"work\",
        \"mobile\", \"iPhone\", etc.) which Deckard maps to Apple's
        canonical labels. group_ids attaches the new contact to those
        groups in the same save transaction.

        The `note` field is accepted for forward-compat but currently
        ignored — see `contacts.get` description.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "given_name":   .object(["type": .string("string")]),
                "family_name":  .object(["type": .string("string")]),
                "organization": .object(["type": .string("string")]),
                "job_title":    .object(["type": .string("string")]),
                "department":   .object(["type": .string("string")]),
                "phones":       .object(["type": .string("array"), "items": labeledValueSchema]),
                "emails":       .object(["type": .string("array"), "items": labeledValueSchema]),
                "urls":         .object(["type": .string("array"), "items": labeledValueSchema]),
                "note":         .object(["type": .string("string")]),
                "group_ids":    .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
            ]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: ContactsAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        let groupIds: [String]? = {
            guard case .array(let arr) = arguments?["group_ids"] else { return nil }
            return arr.compactMap { $0.stringValue }
        }()
        let input = ContactsAdapter.ContactInput(
            givenName: arguments?["given_name"]?.stringValue,
            familyName: arguments?["family_name"]?.stringValue,
            organization: arguments?["organization"]?.stringValue,
            jobTitle: arguments?["job_title"]?.stringValue,
            department: arguments?["department"]?.stringValue,
            phones: decodeLabeledArray(arguments?["phones"]),
            emails: decodeLabeledArray(arguments?["emails"]),
            urls: decodeLabeledArray(arguments?["urls"]),
            note: arguments?["note"]?.stringValue,
            groupIds: groupIds
        )
        let detail = try await adapter.create(input)
        return contactsJSON(detail)
    }

    func approvalSummary(for arguments: [String: Value]?) -> [String] {
        var lines = ["Create contact"]
        let nameParts = [
            arguments?["given_name"]?.stringValue,
            arguments?["family_name"]?.stringValue,
        ].compactMap { $0 }.filter { !$0.isEmpty }
        if !nameParts.isEmpty { lines.append("Name: \(nameParts.joined(separator: " "))") }
        if let o = arguments?["organization"]?.stringValue, !o.isEmpty { lines.append("Org: \(o)") }
        if case .array(let phones) = arguments?["phones"], !phones.isEmpty {
            lines.append("Phones: \(phones.count)")
        }
        if case .array(let emails) = arguments?["emails"], !emails.isEmpty {
            lines.append("Emails: \(emails.count)")
        }
        if case .array(let groups) = arguments?["group_ids"], !groups.isEmpty {
            lines.append("Groups: \(groups.count)")
        }
        return lines
    }
}

struct UpdateContactTool: ToolHandler, ApprovalSummarizing {
    let name = "contacts.update"
    let spec = Tool(
        name: "contacts.update",
        description: """
        Update fields on an existing contact. Only fields supplied are
        changed. Pass null on a string field to clear it (e.g.
        `\"job_title\": null` empties that field). Phones / emails / urls
        REPLACE the existing array when supplied — pass `[]` to clear.

        Use `contacts.set_groups` for group membership changes; this tool
        does not touch group memberships.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id":           .object(["type": .string("string")]),
                "given_name":   .object(["type": .string("string")]),
                "family_name":  .object(["type": .string("string")]),
                "organization": .object(["type": .string("string")]),
                "job_title":    .object(["type": .string("string")]),
                "department":   .object(["type": .string("string")]),
                "phones":       .object(["type": .string("array"), "items": labeledValueSchema]),
                "emails":       .object(["type": .string("array"), "items": labeledValueSchema]),
                "urls":         .object(["type": .string("array"), "items": labeledValueSchema]),
                "note":         .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: ContactsAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let id = arguments?["id"]?.stringValue else {
            return contactsErrorResult("id is required")
        }
        var change = ContactsAdapter.ContactUpdate(id: id)
        change.givenName = doubleOptional(arguments?["given_name"])
        change.familyName = doubleOptional(arguments?["family_name"])
        change.organization = doubleOptional(arguments?["organization"])
        change.jobTitle = doubleOptional(arguments?["job_title"])
        change.department = doubleOptional(arguments?["department"])
        if let v = arguments?["phones"], case .array = v {
            change.phones = decodeLabeledArray(v)
        }
        if let v = arguments?["emails"], case .array = v {
            change.emails = decodeLabeledArray(v)
        }
        if let v = arguments?["urls"], case .array = v {
            change.urls = decodeLabeledArray(v)
        }
        change.note = doubleOptional(arguments?["note"])

        let detail = try await adapter.update(change)
        return contactsJSON(detail)
    }

    func approvalSummary(for arguments: [String: Value]?) -> [String] {
        var lines = ["Update contact"]
        lines.append("Id: \(arguments?["id"]?.stringValue ?? "?")")
        for k in ["given_name", "family_name", "organization", "job_title", "department"] {
            if let v = arguments?[k]?.stringValue {
                lines.append("\(k) → \(v.isEmpty ? "<clear>" : String(v.prefix(80)))")
            } else if case .null = arguments?[k] ?? .null {
                // suppress — only show explicit nulls when paired with a meaningful value
            }
        }
        for k in ["phones", "emails", "urls"] {
            if case .array(let arr) = arguments?[k] {
                lines.append("\(k): \(arr.isEmpty ? "<clear>" : "\(arr.count) items")")
            }
        }
        return lines
    }
}

struct DeleteContactTool: ToolHandler, ApprovalSummarizing {
    let name = "contacts.delete"
    let spec = Tool(
        name: "contacts.delete",
        description: "Delete a contact. DESTRUCTIVE — irreversible. Recommended ACL is `approve`.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: ContactsAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let id = arguments?["id"]?.stringValue else {
            return contactsErrorResult("id is required")
        }
        try await adapter.delete(id: id)
        return CallTool.Result(content: [.text(text: #"{"deleted":true}"#, annotations: nil, _meta: nil)], isError: false)
    }

    func approvalSummary(for arguments: [String: Value]?) -> [String] {
        ["Delete contact (irreversible)", "Id: \(arguments?["id"]?.stringValue ?? "?")"]
    }
}

struct SetGroupsTool: ToolHandler, ApprovalSummarizing {
    let name = "contacts.set_groups"
    let spec = Tool(
        name: "contacts.set_groups",
        description: """
        Replace a contact's group memberships with `group_ids` exactly.
        Computes the add/remove diff against current memberships and
        commits it as one save transaction. Pass `[]` to remove the
        contact from every group. Returns the resulting group_ids list.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id":        .object(["type": .string("string")]),
                "group_ids": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
            ]),
            "required": .array([.string("id"), .string("group_ids")]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: ContactsAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let id = arguments?["id"]?.stringValue else {
            return contactsErrorResult("id is required")
        }
        let groupIds: [String]
        if case .array(let arr) = arguments?["group_ids"] {
            groupIds = arr.compactMap { $0.stringValue }
        } else {
            return contactsErrorResult("group_ids is required (use [] to clear)")
        }
        let resulting = try await adapter.setGroups(contactId: id, targetGroupIds: groupIds)
        return contactsJSON(["group_ids": resulting])
    }

    func approvalSummary(for arguments: [String: Value]?) -> [String] {
        var lines = ["Set contact group membership"]
        lines.append("Id: \(arguments?["id"]?.stringValue ?? "?")")
        if case .array(let arr) = arguments?["group_ids"] {
            lines.append(arr.isEmpty ? "Target: <none — remove from all groups>" : "Target: \(arr.count) group(s)")
        }
        return lines
    }
}

// MARK: - Helpers

/// Decode an MCP `Value?` into Swift's "double-optional" pattern used by
/// the adapter's update structs:
///   - field absent      → `nil`        (don't touch)
///   - field = null      → `.some(nil)` (clear)
///   - field = "value"   → `.some("value")` (set)
private func doubleOptional(_ v: Value?) -> String?? {
    guard let v else { return nil }
    switch v {
    case .null:           return .some(nil)
    case .string(let s):  return .some(s)
    default:              return nil
    }
}

func contactsJSON<T: Encodable>(_ value: T) -> CallTool.Result {
    do {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let data = try enc.encode(value)
        let s = String(data: data, encoding: .utf8) ?? "{}"
        return CallTool.Result(content: [.text(text: s, annotations: nil, _meta: nil)], isError: false)
    } catch {
        return contactsErrorResult("encode failed: \(error)")
    }
}

func contactsErrorResult(_ message: String) -> CallTool.Result {
    CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
}
