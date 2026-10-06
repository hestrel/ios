import Foundation

/// What a coding agent reports as it works, read from the MCP notifications its server streams during a turn:
/// Codex's `codex/event`, Claude Code's `claude/event`, and `hestrel/event` from every other harness.
nonisolated enum AgentEvent: Equatable, Sendable {
    case sessionStarted(threadID: String, model: String?)
    case textDelta(itemID: String, text: String)
    /// The full text of a message, which supersedes its deltas.
    case textCompleted(itemID: String, text: String)
    case reasoningDelta(String)
    case stepStarted(ToolCall)
    case stepFinished(id: ToolCall.ID, ToolResult)
    case failed(String)

    static func events(from notification: MCPNotification) -> [AgentEvent] {
        switch notification.method {
        case "codex/event":
            notification.params["msg"].flatMap(codexEvent).map { [$0] } ?? []
        case "claude/event":
            claudeEvents(notification.params)
        case "hestrel/event":
            hestrelEvent(notification.params).map { [$0] } ?? []
        default:
            []
        }
    }

    // MARK: Codex

    private static func codexEvent(_ event: JSONValue) -> AgentEvent? {
        let host = CodeAgent.codex.title
        switch event["type"]?.stringValue {
        case "session_configured":
            guard let threadID = (event["thread_id"] ?? event["session_id"])?.stringValue else { return nil }
            return .sessionStarted(threadID: threadID, model: event["model"]?.stringValue)

        case "agent_message_content_delta":
            guard let itemID = event["item_id"]?.stringValue, let delta = event["delta"]?.stringValue else { return nil }
            return .textDelta(itemID: itemID, text: delta)

        case "item_completed":
            guard let item = event["item"], item["type"]?.stringValue == "AgentMessage",
                  let itemID = item["id"]?.stringValue
            else { return nil }
            let text = (item["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined()
            return .textCompleted(itemID: itemID, text: text)

        case "agent_reasoning_delta", "agent_reasoning_raw_content_delta":
            return event["delta"]?.stringValue.map(AgentEvent.reasoningDelta)

        case "exec_command_begin":
            guard let id = event["call_id"]?.stringValue else { return nil }
            let argv = (event["command"]?.arrayValue ?? []).compactMap(\.stringValue)
            // Codex wraps commands as `zsh -lc "<script>"`; the script is what the user cares about.
            let command = argv.count == 3 && argv[1].hasPrefix("-") && argv[1].hasSuffix("c") ? argv[2] : argv.joined(separator: " ")
            let summaries = Set((event["parsed_cmd"]?.arrayValue ?? []).compactMap(codexSummary))
            return .stepStarted(AgentStep.command(command, summary: summaries.count == 1 ? summaries.first : nil).call(id: id, host: host))

        case "exec_command_end":
            guard let id = event["call_id"]?.stringValue else { return nil }
            let output = (event["aggregated_output"] ?? event["formatted_output"])?.stringValue ?? ""
            let exitCode = event["exit_code"]?.numberValue ?? 0
            return .stepFinished(id: id, ToolResult(content: output, isError: exitCode != 0))

        case "patch_apply_begin":
            guard let id = event["call_id"]?.stringValue else { return nil }
            guard case let .object(changes) = event["changes"] ?? .null else { return nil }
            let files = changes.sorted { $0.key < $1.key }.map { path, change in
                AgentStep.FileChange(
                    path: path,
                    kind: change["type"]?.stringValue.flatMap(AgentStep.FileChange.Kind.init) ?? .update,
                    diff: (change["unified_diff"] ?? change["content"])?.stringValue ?? ""
                )
            }
            return .stepStarted(AgentStep.edit(files).call(id: id, host: host))

        case "patch_apply_end":
            guard let id = event["call_id"]?.stringValue else { return nil }
            let success = event["success"]?.boolValue ?? true
            let output = [event["stdout"]?.stringValue, event["stderr"]?.stringValue].compactMap { $0?.nonBlank }.joined(separator: "\n")
            return .stepFinished(id: id, ToolResult(content: output, isError: !success))

        // `stream_error` only reports that Codex is retrying, so it's left out.
        case "error":
            return event["message"]?.stringValue.map(AgentEvent.failed)

        default:
            return nil
        }
    }

    /// Codex's own reading of a command: "Read notes.md", "Listed files in src".
    private static func codexSummary(_ parsed: JSONValue) -> String? {
        switch parsed["type"]?.stringValue {
        case "read":
            return (parsed["name"] ?? parsed["path"])?.stringValue.map { "Read \($0)" }
        case "list_files":
            return parsed["path"]?.stringValue.map { "Listed files in \($0)" } ?? "Listed files"
        case "search":
            switch (parsed["query"]?.stringValue, parsed["path"]?.stringValue) {
            case let (query?, path?): return "Searched for \(query) in \(path)"
            case let (query?, nil): return "Searched for \(query)"
            default: return "Searched files"
            }
        default:
            return nil
        }
    }

    // MARK: Other harnesses

    /// The bridge's own format, already in Hestrel's terms (see `EventWriter` in the bridge).
    private static func hestrelEvent(_ event: JSONValue) -> AgentEvent? {
        switch event["type"]?.stringValue {
        case "session":
            return event["sessionId"]?.stringValue.map { .sessionStarted(threadID: $0, model: event["model"]?.stringValue) }
        case "text_delta":
            guard let item = event["item"]?.stringValue, let text = event["text"]?.stringValue else { return nil }
            return .textDelta(itemID: item, text: text)
        case "text":
            guard let item = event["item"]?.stringValue, let text = event["text"]?.stringValue else { return nil }
            return .textCompleted(itemID: item, text: text)
        case "reasoning_delta":
            return event["text"]?.stringValue.map(AgentEvent.reasoningDelta)
        case "step":
            guard let id = event["id"]?.stringValue, let step = event["step"], let host = event["host"]?.stringValue else { return nil }
            let agentStep: AgentStep
            switch step["kind"]?.stringValue {
            case "command":
                agentStep = .command(step["command"]?.stringValue ?? "", summary: step["summary"]?.stringValue)
            case "edit":
                agentStep = .edit((step["files"]?.arrayValue ?? []).map { file in
                    AgentStep.FileChange(
                        path: file["path"]?.stringValue ?? "",
                        kind: file["kind"]?.stringValue.flatMap(AgentStep.FileChange.Kind.init) ?? .update,
                        diff: file["diff"]?.stringValue ?? ""
                    )
                })
            default:
                agentStep = .activity(
                    summary: step["summary"]?.stringValue ?? "Used a tool",
                    detail: step["detail"]?.stringValue,
                    symbol: step["symbol"]?.stringValue ?? "wrench.and.screwdriver"
                )
            }
            return .stepStarted(agentStep.call(id: id, host: host))
        case "step_done":
            guard let id = event["id"]?.stringValue else { return nil }
            return .stepFinished(id: id, ToolResult(content: event["output"]?.stringValue ?? "", isError: event["isError"]?.boolValue ?? false))
        case "error":
            return event["message"]?.stringValue.map(AgentEvent.failed)
        default:
            return nil
        }
    }

    // MARK: Claude Code

    /// Claude Code's `stream-json` events, as the bridge forwards them.
    private static func claudeEvents(_ event: JSONValue) -> [AgentEvent] {
        // A subagent's own steps stay inside its Task step.
        if event["parent_tool_use_id"]?.stringValue != nil { return [] }

        switch event["type"]?.stringValue {
        case "system":
            guard event["subtype"]?.stringValue == "init", let sessionID = event["session_id"]?.stringValue else { return [] }
            return [.sessionStarted(threadID: sessionID, model: event["model"]?.stringValue)]

        case "stream_event":
            let delta = event["event"]?["delta"]
            let itemID = event["message_id"]?.stringValue ?? "message"
            switch delta?["type"]?.stringValue {
            case "text_delta": return delta?["text"]?.stringValue.map { [.textDelta(itemID: itemID, text: $0)] } ?? []
            case "thinking_delta": return delta?["thinking"]?.stringValue.map { [.reasoningDelta($0)] } ?? []
            default: return []
            }

        case "assistant":
            guard let message = event["message"] else { return [] }
            let itemID = message["id"]?.stringValue ?? "message"
            return (message["content"]?.arrayValue ?? []).compactMap { block in
                switch block["type"]?.stringValue {
                case "text":
                    return block["text"]?.stringValue.map { .textCompleted(itemID: itemID, text: $0) }
                case "tool_use":
                    guard let id = block["id"]?.stringValue, let name = block["name"]?.stringValue else { return nil }
                    let step = claudeStep(name: name, input: block["input"] ?? .emptyObject)
                    return .stepStarted(step.call(id: id, host: CodeAgent.claudeCode.title))
                default:
                    return nil
                }
            }

        case "user":
            return (event["message"]?["content"]?.arrayValue ?? []).compactMap { block in
                guard block["type"]?.stringValue == "tool_result", let id = block["tool_use_id"]?.stringValue else { return nil }
                let content = block["content"]
                let text = content?.stringValue
                    ?? (content?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
                return .stepFinished(id: id, ToolResult(content: text, isError: block["is_error"]?.boolValue ?? false))
            }

        default:
            return []
        }
    }

    /// Claude Code's tools as steps: shell commands, file edits, and a one-line summary for the rest.
    private static func claudeStep(name: String, input: JSONValue) -> AgentStep {
        let path = input["file_path"]?.stringValue ?? input["notebook_path"]?.stringValue
        let fileName = path.map { ($0 as NSString).lastPathComponent }

        switch name {
        case "Bash":
            return .command(input["command"]?.stringValue ?? "", summary: input["description"]?.stringValue)
        case "Edit":
            return .edit([.replacing(path ?? "", old: input["old_string"]?.stringValue ?? "", new: input["new_string"]?.stringValue ?? "")])
        case "MultiEdit":
            let diff = (input["edits"]?.arrayValue ?? []).map { edit in
                AgentStep.FileChange.replacing("", old: edit["old_string"]?.stringValue ?? "", new: edit["new_string"]?.stringValue ?? "").diff
            }
            return .edit([AgentStep.FileChange(path: path ?? "", kind: .update, diff: diff.joined(separator: "\n"))])
        case "Write":
            return .edit([AgentStep.FileChange(path: path ?? "", kind: .add, diff: input["content"]?.stringValue ?? "")])
        case "Read":
            return .activity(summary: "Read \(fileName ?? "a file")", detail: path, symbol: "doc.text")
        case "Grep":
            let pattern = input["pattern"]?.stringValue ?? ""
            return .activity(summary: "Searched for \(pattern)", detail: input["path"]?.stringValue, symbol: "magnifyingglass")
        case "Glob":
            return .activity(summary: "Found files matching \(input["pattern"]?.stringValue ?? "")", detail: input["path"]?.stringValue, symbol: "magnifyingglass")
        case "WebSearch":
            return .activity(summary: "Searched the web for \(input["query"]?.stringValue ?? "")", detail: nil, symbol: "globe")
        case "WebFetch":
            let url = input["url"]?.stringValue
            return .activity(summary: "Read \(url.flatMap { URL(string: $0)?.host() } ?? "a page")", detail: url, symbol: "globe")
        case "Task", "Agent":
            return .activity(summary: input["description"]?.stringValue ?? "Ran a subagent", detail: input["prompt"]?.stringValue, symbol: "person.2")
        case "TodoWrite":
            let todos = (input["todos"]?.arrayValue ?? []).compactMap { todo -> String? in
                guard let content = todo["content"]?.stringValue else { return nil }
                return (todo["status"]?.stringValue == "completed" ? "✓ " : "• ") + content
            }
            return .activity(summary: "Updated the plan", detail: todos.joined(separator: "\n").nonBlank, symbol: "checklist")
        case "NotebookEdit":
            return .activity(summary: "Edited \(fileName ?? "a notebook")", detail: path, symbol: "pencil")
        default:
            return .activity(summary: "Used \(name)", detail: input.jsonString(pretty: true).nonBlank, symbol: "wrench.and.screwdriver")
        }
    }
}
