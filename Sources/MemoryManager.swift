// MemoryManager.swift
// Reads claude-mem SQLite database (read-only) and exposes memory data

import Foundation
import SQLite3

// MARK: - Models

struct ClaudeMemory: Identifiable {
    let id: Int64
    let sessionId: String
    let text: String
    let title: String?
    let subtitle: String?
    let facts: [String]
    let concepts: [String]
    let filesTouched: [String]
    let keywords: String?
    let project: String?
    let createdAt: Date

    var displayTitle: String {
        title ?? text.prefix(80).description
    }
}

struct MemoryStats {
    let totalMemories: Int
    let totalSessions: Int
    let totalProjects: Int
    let recentCount: Int  // last 7 days
    let topProjects: [(name: String, count: Int)]

    static let empty = MemoryStats(totalMemories: 0, totalSessions: 0, totalProjects: 0, recentCount: 0, topProjects: [])
}

// MARK: - Manager

class MemoryManager: ObservableObject {

    @Published var memories: [ClaudeMemory] = []
    @Published var stats: MemoryStats = .empty
    @Published var isInstalled = false
    @Published var isLoading = false
    @Published var searchText = ""
    @Published var selectedProject: String?
    @Published var projects: [String] = []

    static let dbPath: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-mem/claude-mem.db")
    }()

    // MARK: - Installation check

    func checkInstallation() {
        isInstalled = FileManager.default.fileExists(atPath: Self.dbPath.path)
    }

    // MARK: - Load data

    func refresh() {
        isLoading = true
        checkInstallation()
        guard isInstalled else {
            memories = []
            stats = .empty
            projects = []
            isLoading = false
            return
        }

        isLoading = true
        let search = searchText
        let project = selectedProject

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = Self.loadFromDB(search: search, project: project)
            DispatchQueue.main.async {
                self.memories = result.memories
                self.stats = result.stats
                self.projects = result.projects
                self.isLoading = false
            }
        }
    }

    // MARK: - SQLite reading

    private struct LoadResult {
        let memories: [ClaudeMemory]
        let stats: MemoryStats
        let projects: [String]
    }

    private static func loadFromDB(search: String, project: String?) -> LoadResult {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else {
            Log.error("Failed to open claude-mem database")
            return LoadResult(memories: [], stats: .empty, projects: [])
        }
        defer { sqlite3_close(db) }

        let allMemories = queryMemories(db: db, search: search, project: project)
        let stats = computeStats(db: db)
        let projects = queryProjects(db: db)

        return LoadResult(memories: allMemories, stats: stats, projects: projects)
    }

    private static func queryMemories(db: OpaquePointer, search: String, project: String?) -> [ClaudeMemory] {
        var sql = """
            SELECT id, session_id, text, title, subtitle, facts, concepts, files_touched, keywords, project, created_at_epoch
            FROM memories
            WHERE 1=1
            """
        var params: [String] = []

        if !search.isEmpty {
            sql += " AND (text LIKE ? OR title LIKE ? OR keywords LIKE ?)"
            let like = "%\(search)%"
            params.append(contentsOf: [like, like, like])
        }
        if let project {
            sql += " AND project = ?"
            params.append(project)
        }

        sql += " ORDER BY created_at_epoch DESC LIMIT 100"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Log.error("Failed to prepare memories query: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(stmt) }

        for (i, param) in params.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), (param as NSString).utf8String, -1, nil)
        }

        var results: [ClaudeMemory] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let sessionId = columnText(stmt, 1)
            let text = columnText(stmt, 2)
            let title = columnTextOptional(stmt, 3)
            let subtitle = columnTextOptional(stmt, 4)
            let facts = parseJSONArray(columnTextOptional(stmt, 5))
            let concepts = parseJSONArray(columnTextOptional(stmt, 6))
            let filesTouched = parseJSONArray(columnTextOptional(stmt, 7))
            let keywords = columnTextOptional(stmt, 8)
            let project = columnTextOptional(stmt, 9)
            let epoch = sqlite3_column_double(stmt, 10)

            results.append(ClaudeMemory(
                id: id,
                sessionId: sessionId,
                text: text,
                title: title,
                subtitle: subtitle,
                facts: facts,
                concepts: concepts,
                filesTouched: filesTouched,
                keywords: keywords,
                project: project,
                createdAt: Date(timeIntervalSince1970: epoch)
            ))
        }

        return results
    }

    private static func computeStats(db: OpaquePointer) -> MemoryStats {
        let totalMemories = queryCount(db: db, sql: "SELECT COUNT(*) FROM memories")
        let totalSessions = queryCount(db: db, sql: "SELECT COUNT(DISTINCT session_id) FROM memories")
        let totalProjects = queryCount(db: db, sql: "SELECT COUNT(DISTINCT project) FROM memories WHERE project IS NOT NULL AND project != ''")

        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 3600).timeIntervalSince1970
        let recentCount = queryCount(db: db, sql: "SELECT COUNT(*) FROM memories WHERE created_at_epoch > \(sevenDaysAgo)")

        // Top projects
        var topProjects: [(name: String, count: Int)] = []
        var stmt: OpaquePointer?
        let topSQL = "SELECT project, COUNT(*) as cnt FROM memories WHERE project IS NOT NULL AND project != '' GROUP BY project ORDER BY cnt DESC LIMIT 5"
        if sqlite3_prepare_v2(db, topSQL, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let name = columnText(stmt, 0)
                let count = Int(sqlite3_column_int(stmt, 1))
                topProjects.append((name: name, count: count))
            }
            sqlite3_finalize(stmt)
        }

        return MemoryStats(
            totalMemories: totalMemories,
            totalSessions: totalSessions,
            totalProjects: totalProjects,
            recentCount: recentCount,
            topProjects: topProjects
        )
    }

    private static func queryProjects(db: OpaquePointer) -> [String] {
        var projects: [String] = []
        var stmt: OpaquePointer?
        let sql = "SELECT DISTINCT project FROM memories WHERE project IS NOT NULL AND project != '' ORDER BY project"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                projects.append(columnText(stmt, 0))
            }
            sqlite3_finalize(stmt)
        }
        return projects
    }

    // MARK: - Helpers

    private static func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cStr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cStr)
    }

    private static func columnTextOptional(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cStr = sqlite3_column_text(stmt, index) else { return nil }
        let str = String(cString: cStr)
        return str.isEmpty ? nil : str
    }

    private static func parseJSONArray(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return array
    }

    private static func queryCount(db: OpaquePointer, sql: String) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }
}
