import Foundation
import Logging
import TOMLKit

public enum ConfigError: Error, CustomStringConvertible {
    case fileNotFound(URL)
    case parse(URL, underlying: Error)
    case write(URL, underlying: Error)

    public var description: String {
        switch self {
        case .fileNotFound(let url):
            return "Config not found at \(url.path) — run `icloud-bridge config init`."
        case .parse(let url, let err):
            return "Failed to parse \(url.path): \(err)"
        case .write(let url, let err):
            return "Failed to write \(url.path): \(err)"
        }
    }
}

/// Loads / persists `Config`. Single source of truth: the TOML file on disk.
public struct ConfigStore: Sendable {
    public let url: URL
    private let logger: Logger

    public init(url: URL = BridgePaths.configFile, logger: Logger = Logger(label: "bridge.config")) {
        self.url = url
        self.logger = logger
    }

    public func exists() -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func load() throws -> Config {
        guard exists() else { throw ConfigError.fileNotFound(url) }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ConfigError.parse(url, underlying: error)
        }
        do {
            return try TOMLDecoder().decode(Config.self, from: text)
        } catch {
            throw ConfigError.parse(url, underlying: error)
        }
    }

    /// Loads the config or creates the default config on disk if missing.
    public func loadOrInit() throws -> Config {
        if exists() {
            return try load()
        }
        let defaultConfig = Config()
        try write(defaultConfig)
        logger.info("Initialized default config at \(url.path)")
        return defaultConfig
    }

    public func write(_ config: Config) throws {
        try BridgePaths.ensureDirs()
        let body: String
        do {
            body = try TOMLEncoder().encode(config)
        } catch {
            throw ConfigError.write(url, underlying: error)
        }
        let header = """
            # iCloud-Bridge config
            # Edited by `icloud-bridge config` or by hand. The bridge re-reads this
            # file on each `serve`. Restart the LaunchAgent after edits.

            """
        let full = header + body
        do {
            try full.write(to: url, atomically: true, encoding: .utf8)
            try setOwnerOnlyPermissions(url: url)
        } catch {
            throw ConfigError.write(url, underlying: error)
        }
    }

    private func setOwnerOnlyPermissions(url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
