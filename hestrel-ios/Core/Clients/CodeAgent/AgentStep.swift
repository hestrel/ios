import Foundation

/// Something a coding agent did: ran a command, edited files, or used another tool.
/// Stored as a `ToolCall` hosted by the agent, so it lives in the chat log alongside its result.
nonisolated enum AgentStep: Equatable {
    case command(String, summary: String?)
    case edit([FileChange])
    /// Reading, searching and other tools, as one line with optional detail.
    case activity(summary: String, detail: String?, symbol: String)

    struct FileChange: Equatable, Identifiable {
        enum Kind: String { case add, delete, update }
        let path: String
        let kind: Kind
        /// A unified diff for updates; the whole content for added and deleted files.
        let diff: String
        var id: String { path }

        var fileName: String { (path as NSString).lastPathComponent }

        /// Lines added and removed.
        var stats: (added: Int, removed: Int) {
            switch kind {
            case .add: return (diff.split(separator: "\n", omittingEmptySubsequences: false).count, 0)
            case .delete: return (0, diff.split(separator: "\n", omittingEmptySubsequences: false).count)
            case .update:
                let lines = diff.split(separator: "\n")
                return (
                    lines.count { $0.hasPrefix("+") && !$0.hasPrefix("+++") },
                    lines.count { $0.hasPrefix("-") && !$0.hasPrefix("---") }
                )
            }
        }

        /// A replacement of one string with another, shown as a diff: lines both share are context, the rest changed.
        static func replacing(_ path: String, old: String, new: String) -> FileChange {
            let before = old.isEmpty ? [] : old.components(separatedBy: "\n")
            let after = new.isEmpty ? [] : new.components(separatedBy: "\n")
            let prefix = zip(before, after).prefix { $0 == $1 }.count
            let suffix = zip(before.dropFirst(prefix).reversed(), after.dropFirst(prefix).reversed()).prefix { $0 == $1 }.count
            let lines = ["@@"]
                + before.prefix(prefix).map { " " + $0 }
                + before.dropFirst(prefix).dropLast(suffix).map { "-" + $0 }
                + after.dropFirst(prefix).dropLast(suffix).map { "+" + $0 }
                + before.suffix(suffix).map { " " + $0 }
            return FileChange(path: path, kind: .update, diff: lines.joined(separator: "\n"))
        }
    }

    init?(_ call: ToolCall) {
        // Agent steps are hosted by their agent; provider-hosted calls (web search, MCP) have other names.
        guard call.hostedBy != nil, let arguments = JSONValue(json: call.arguments) else { return nil }
        switch call.name {
        case "command":
            self = .command(arguments["command"]?.stringValue ?? "", summary: arguments["summary"]?.stringValue)
        case "edit":
            self = .edit((arguments["files"]?.arrayValue ?? []).compactMap { file in
                guard let path = file["path"]?.stringValue else { return nil }
                return FileChange(
                    path: path,
                    kind: file["kind"]?.stringValue.flatMap(FileChange.Kind.init) ?? .update,
                    diff: file["diff"]?.stringValue ?? ""
                )
            })
        case "activity":
            self = .activity(
                summary: arguments["summary"]?.stringValue ?? "",
                detail: arguments["detail"]?.stringValue,
                symbol: arguments["symbol"]?.stringValue ?? "wrench.and.screwdriver"
            )
        default:
            return nil
        }
    }

    /// The step as a tool call made by `host`, the agent's title.
    func call(id: String, host: String) -> ToolCall {
        let (name, arguments): (String, [String: JSONValue]) = switch self {
        case let .command(command, summary):
            ("command", ["command": .string(command), "summary": summary.map(JSONValue.string) ?? .null])
        case let .edit(files):
            ("edit", ["files": .array(files.map { file in
                .object(["path": .string(file.path), "kind": .string(file.kind.rawValue), "diff": .string(file.diff)])
            })])
        case let .activity(summary, detail, symbol):
            ("activity", ["summary": .string(summary), "detail": detail.map(JSONValue.string) ?? .null, "symbol": .string(symbol)])
        }
        return ToolCall(id: id, name: name, arguments: JSONValue.object(arguments).jsonString(), hostedBy: host)
    }
}
