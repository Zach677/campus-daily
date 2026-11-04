import Foundation
import os

/// One log line per request: method, host, the request's log name, status, latency, decoded
/// `code`. Never the path (it can hold ids), query strings, bodies or headers.
public struct HTTPLogEntry: Sendable, Equatable {
    public var service: Service
    public var method: String
    public var host: String
    /// `HTTPRequest.logName`.
    public var name: String
    public var status: Int?
    public var milliseconds: Int
    public var code: String?
    public var error: String?

    public var line: String {
        var s = "\(service.rawValue) \(method) \(host) \(name)"
        s += status.map { " → \($0)" } ?? ""
        s += " \(milliseconds)ms"
        if let code { s += " code=\(code)" }
        if let error { s += " error=\(error)" }
        return s
    }
}

public protocol HTTPLogSink: Sendable {
    func record(_ entry: HTTPLogEntry)
}

/// Default sink: `os.Logger`, everything public because it contains nothing secret.
public struct OSLogSink: HTTPLogSink {
    public init() {}
    public func record(_ entry: HTTPLogEntry) {
        let logger = Logger(subsystem: "org.zaxh.xiaorichang", category: "http")
        logger.info("\(entry.line, privacy: .public)")
    }
}
