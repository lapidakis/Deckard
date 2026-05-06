import Foundation
import Logging

/// Sets up swift-log to emit human-readable lines on stderr.
///
/// stdout is reserved for MCP framing when running over stdio; logs MUST go to
/// stderr or they will corrupt the protocol stream.
enum LoggingSetup {
    static func bootstrap(level: Logger.Level = .info) {
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = level
            return handler
        }
    }
}
