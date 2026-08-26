/// A minimal wrapper over the system SQLite3 C API.
///
/// Deliberately not an ORM. The reference implementation
/// (`morningstar/docs/ARCHITECTURE.md`) argues the point: this domain is
/// append-only — rows are inserted, never updated — and an ORM's core
/// machinery (identity map, dirty tracking, UPDATE generation) is exactly
/// what the design must prevent. Plain SQL also keeps the schema and its
/// immutability triggers byte-identical to the Python reference, which is
/// what the parity claim actually rests on.
///
/// The connection is serialized behind a recursive lock so nested calls
/// inside `transaction {}` work, matching the reference store's RLock.

import Foundation
import SQLite3

/// SQLite wants either SQLITE_STATIC or SQLITE_TRANSIENT for text binds;
/// TRANSIENT tells it to copy, so Swift's temporary C string is safe.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String

    public var description: String { "SQLite error \(code): \(message)" }

    /// True when a `RAISE(ABORT, …)` trigger rejected the write — i.e. the
    /// database refused to mutate append-only evidence.
    public var isAppendOnlyViolation: Bool {
        code == SQLITE_CONSTRAINT && message.contains("integrity:")
    }
}

public enum SQLValue: Equatable, Sendable {
    case null
    case text(String)
    case int(Int64)
    case double(Double)

    public init(_ value: String?) { self = value.map { .text($0) } ?? .null }
    public init(_ value: Int) { self = .int(Int64(value)) }
    public init(_ value: Bool) { self = .int(value ? 1 : 0) }
    public init(_ value: Double?) { self = value.map { .double($0) } ?? .null }
}

public struct Row: Sendable {
    public let values: [String: SQLValue]

    public func string(_ key: String) -> String? {
        if case .text(let s)? = values[key] { return s }
        return nil
    }

    public func int(_ key: String) -> Int64? {
        if case .int(let n)? = values[key] { return n }
        return nil
    }

    public func double(_ key: String) -> Double? {
        if case .double(let d)? = values[key] { return d }
        if case .int(let n)? = values[key] { return Double(n) }
        return nil
    }

    public func bool(_ key: String) -> Bool { (int(key) ?? 0) != 0 }
}

public final class SQLiteConnection {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()

    public init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let opened = db else {
            var message = "unable to open database at \(path)"
            if let db {
                message = String(cString: sqlite3_errmsg(db))
                sqlite3_close_v2(db)
            }
            throw SQLiteError(code: rc, message: message)
        }
        handle = opened
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if let handle {
            sqlite3_close_v2(handle)
            self.handle = nil
        }
    }

    @discardableResult
    public func execute(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        try withStatement(sql, params) { stmt in
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw currentError(rc) }
            return Int(sqlite3_changes(handle))
        }
    }

    public func query(_ sql: String, _ params: [SQLValue] = []) throws -> [Row] {
        try withStatement(sql, params) { stmt in
            var rows: [Row] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw currentError(rc) }
                rows.append(Row(values: readRow(stmt)))
            }
            return rows
        }
    }

    public func queryOne(_ sql: String, _ params: [SQLValue] = []) throws -> Row? {
        try query(sql, params).first
    }

    /// Runs `body` inside a transaction, rolling back on any thrown error.
    @discardableResult
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - internals

    private func withStatement<T>(_ sql: String, _ params: [SQLValue],
                                  _ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else {
            throw SQLiteError(code: SQLITE_MISUSE, message: "connection is closed")
        }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let prepared = stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            throw currentError(rc)
        }
        defer { sqlite3_finalize(prepared) }
        for (index, param) in params.enumerated() {
            let position = Int32(index + 1)
            let brc: Int32
            switch param {
            case .null: brc = sqlite3_bind_null(prepared, position)
            case .text(let s): brc = sqlite3_bind_text(prepared, position, s, -1, SQLITE_TRANSIENT)
            case .int(let n): brc = sqlite3_bind_int64(prepared, position, n)
            case .double(let d): brc = sqlite3_bind_double(prepared, position, d)
            }
            guard brc == SQLITE_OK else { throw currentError(brc) }
        }
        return try body(prepared)
    }

    private func readRow(_ stmt: OpaquePointer) -> [String: SQLValue] {
        var values: [String: SQLValue] = [:]
        for index in 0..<sqlite3_column_count(stmt) {
            guard let namePointer = sqlite3_column_name(stmt, index) else { continue }
            let name = String(cString: namePointer)
            switch sqlite3_column_type(stmt, index) {
            case SQLITE_NULL:
                values[name] = .null
            case SQLITE_INTEGER:
                values[name] = .int(sqlite3_column_int64(stmt, index))
            case SQLITE_FLOAT:
                values[name] = .double(sqlite3_column_double(stmt, index))
            default:
                if let text = sqlite3_column_text(stmt, index) {
                    values[name] = .text(String(cString: text))
                } else {
                    values[name] = .null
                }
            }
        }
        return values
    }

    private func currentError(_ code: Int32) -> SQLiteError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
        return SQLiteError(code: code, message: message)
    }
}
