import MCP

/// Runtime validation for the JSON Schema subset used by Deckard's tools.
/// A client need not obey tools/list; silently dropping malformed array items
/// can otherwise turn a contacts update into a destructive clear operation.
enum ToolArguments {
    static func isValid(_ value: Value, schema: Value) -> Bool {
        guard case .object(let spec) = schema else { return false }
        let types: [String]
        if case .string(let type) = spec["type"] { types = [type] }
        else if case .array(let values) = spec["type"] { types = values.compactMap(\.stringValue) }
        else { return false }
        let matches = types.contains { type in
            switch (type, value) {
            case ("null", .null), ("string", .string), ("boolean", .bool),
                 ("integer", .int), ("number", .int), ("number", .double),
                 ("array", .array), ("object", .object): return true
            default: return false
            }
        }
        guard matches else { return false }
        if case .array(let allowed) = spec["enum"], !allowed.contains(value) { return false }
        if case .object(let object) = value {
            if case .array(let required) = spec["required"],
               required.compactMap(\.stringValue).contains(where: { object[$0] == nil }) { return false }
            let properties = spec["properties"]?.objectValue ?? [:]
            for (key, item) in object {
                if let property = properties[key] {
                    guard isValid(item, schema: property) else { return false }
                } else if spec["additionalProperties"] == .bool(false) { return false }
            }
        }
        if case .array(let array) = value, let itemSchema = spec["items"] {
            guard array.allSatisfy({ isValid($0, schema: itemSchema) }) else { return false }
        }
        return true
    }
}
