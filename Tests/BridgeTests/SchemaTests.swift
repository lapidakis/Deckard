import Testing
import Foundation
import MCP
import BridgeCore
import ServiceMail
import ServiceCalendar
import ServiceDrive
import ServiceVoiceMemo
import ServiceReminders

/// Meta-tests that walk every registered tool's `inputSchema` and assert
/// invariants. Catches at test time the kind of bug that otherwise only
/// surfaces when an Anthropic API consumer hits the bridge:
///
///   1. Top-level `oneOf` / `allOf` / `anyOf` — Anthropic API rejects
///      these in tool input_schema with HTTP 400.
///   2. `required` field that doesn't exist in `properties`.
///   3. Property declared with no `type` keyword.
///   4. `tool.name != tool.spec.name`.
///   5. Missing or non-`object` `type` at the schema root.
///
/// Runs against the same provider list `Serve.swift` registers in
/// production, so adding a tool there automatically gets validated.

private func allRegisteredTools() -> [any ToolHandler] {
    let providers: [any ToolProvider] = [
        BuiltinTools(),
        MailTools(),
        CalendarTools(),
        DriveTools(),
        VoiceMemoTools(),
        RemindersTools(),
    ]
    return providers.flatMap { $0.handlers }
}

@Test func everyToolHasMatchingNameAndSpec() {
    for tool in allRegisteredTools() {
        #expect(tool.name == tool.spec.name,
                "tool \(tool.name) has spec.name=\(tool.spec.name) — must match")
    }
}

@Test func everyToolSchemaIsObjectType() {
    for tool in allRegisteredTools() {
        guard case .object(let root) = tool.spec.inputSchema else {
            Issue.record("tool \(tool.name): inputSchema is not an object")
            continue
        }
        guard let typeVal = root["type"], case .string(let t) = typeVal else {
            Issue.record("tool \(tool.name): inputSchema has no `type` field")
            continue
        }
        #expect(t == "object", "tool \(tool.name): root type must be `object`, got `\(t)`")
    }
}

@Test func noToolUsesTopLevelOneOfAllOfAnyOf() {
    // Anthropic API rejects tool schemas with these keywords at the top
    // level. The bridge silently surfaced a `oneOf` in May and only an
    // API client's 400 caught it; this test makes that class of bug a
    // build-time failure.
    let banned = ["oneOf", "allOf", "anyOf"]
    for tool in allRegisteredTools() {
        guard case .object(let root) = tool.spec.inputSchema else { continue }
        for key in banned {
            #expect(root[key] == nil,
                    "tool \(tool.name): inputSchema uses banned top-level keyword `\(key)` — Anthropic API will reject. Express the constraint in field descriptions + runtime validation instead.")
        }
    }
}

@Test func everyRequiredFieldExistsInProperties() {
    for tool in allRegisteredTools() {
        guard case .object(let root) = tool.spec.inputSchema else { continue }
        guard case .array(let required)? = root["required"] else { continue }

        let propsKeys = propertiesKeySet(root)

        for entry in required {
            guard case .string(let name) = entry else {
                Issue.record("tool \(tool.name): required[] contains non-string entry")
                continue
            }
            #expect(propsKeys.contains(name),
                    "tool \(tool.name): required field `\(name)` is not declared in properties — agents will see a contradictory schema")
        }
    }
}

@Test func everyPropertyDeclaresAType() {
    for tool in allRegisteredTools() {
        guard case .object(let root) = tool.spec.inputSchema else { continue }
        guard case .object(let props)? = root["properties"] else { continue }

        for (name, schema) in props {
            guard case .object(let propSchema) = schema else {
                Issue.record("tool \(tool.name).\(name): property schema is not an object")
                continue
            }
            #expect(propSchema["type"] != nil,
                    "tool \(tool.name).\(name): property has no `type` keyword — model can't tell what to send")
        }
    }
}

@Test func toolNamesAreUniqueAcrossProviders() {
    // A duplicate tool name silently shadows in MCPHostBuilder's
    // `Dictionary(uniqueKeysWithValues:)` — actually that crashes, so
    // this test is the safety net that surfaces the conflict in CI
    // before it crashes the daemon.
    var seen: [String: Int] = [:]
    for tool in allRegisteredTools() {
        seen[tool.name, default: 0] += 1
    }
    let dups = seen.filter { $0.value > 1 }
    #expect(dups.isEmpty, "duplicate tool names registered: \(dups.keys.sorted())")
}

// MARK: - helpers

private func propertiesKeySet(_ root: [String: Value]) -> Set<String> {
    guard case .object(let props)? = root["properties"] else { return [] }
    return Set(props.keys)
}
