import ComposableArchitecture
import Foundation

/// Code conversations: prompts go straight to a coding agent on the user's computer, with no chat model in between.
extension ChatFeature {
    func startAgentResponse(_ state: inout State, in conversationID: Conversation.ID) -> Effect<Action> {
        guard let conversation = state.conversations[id: conversationID],
              let prompt = conversation.messages.last(where: { $0.role == .user })?.content.nonBlank
        else { return .none }
        guard let server = state.codeServer else {
            state.alert = .codeAgentNotConnected
            return .none
        }
        let agent = state.codeAgent
        var session = conversation.codeSession ?? Conversation.CodeSession(
            agent: agent,
            serverID: server.id,
            folder: state.codeFolder,
            model: state.codeModel,
            effort: state.codeEffort
        )
        // A session lives on the computer that started it; on another one, start over in the same folder.
        if session.serverID != server.id {
            session.serverID = server.id
            session.threadID = nil
        }
        let turn = agent.turn(prompt: prompt, session: session)
        // If the agent can't find the session any more, a new one gets the story so far.
        let restart = session.threadID == nil ? nil : agent.turn(
            prompt: agent.recap(of: Array(conversation.messages.dropLast()), then: prompt),
            session: session,
            resume: false
        )

        // Continued sessions may not report their model again, so name the chosen one up front.
        let modelName = session.model.map { agentModelName(agent: agent, model: $0, state: state) }
        let reply = Message(id: uuid(), role: .assistant, modelName: modelName ?? agent.title, createdAt: now)
        state.$conversations.withLock {
            $0[id: conversationID]?.codeSession = session
            $0[id: conversationID]?.messages.append(reply)
            $0[id: conversationID]?.updatedAt = now
        }
        state.responses[conversationID] = ActiveResponse(messageID: reply.id, model: nil, agentModelName: modelName)

        return .run { [backgroundTask, mcp, mcpAuth] send in
            try await backgroundTask.run(agent.title) {
                let headers = try await mcpAuth.headers(server: server)
                var next: (tool: String, arguments: JSONValue)? = turn
                var isRestart = false
                while let current = next {
                    next = nil
                    for try await event in mcp.streamTool(server: server, headers: headers, name: current.tool, arguments: current.arguments) {
                        switch event {
                        case let .notification(notification):
                            for event in AgentEvent.events(from: notification) {
                                await send(.agentEvent(event, in: conversationID))
                            }
                        case let .resumable(streamID):
                            await send(.agentResumable(streamID: streamID, in: conversationID))
                        case let .result(result):
                            if !isRestart, let restart, CodeAgent.isLostSession(result) {
                                next = restart
                                isRestart = true
                            } else {
                                await send(.agentFinished(result, in: conversationID))
                            }
                        }
                    }
                }
            }
        } catch: { error, send in
            await send(.streamFailed(Self.describe(error), in: conversationID))
        }
        .cancellable(id: CancelID.response(conversationID), cancelInFlight: true)
    }

    /// Picks a turn back up after the app was relaunched while it ran on the computer. The bridge replays the turn
    /// from its first event, so the reply is rebuilt whole, then continues live until it finishes.
    func reattachAgentResponse(_ state: inout State, in conversationID: Conversation.ID) -> Effect<Action> {
        guard let conversation = state.conversations[id: conversationID],
              let session = conversation.codeSession,
              let streamID = session.pendingStreamID
        else { return .none }
        // The saved server, enabled or not yet listed: tools may still be loading at launch.
        guard let server = state.mcpServers[id: session.serverID] else {
            state.$conversations.withLock { $0[id: conversationID]?.codeSession?.pendingStreamID = nil }
            return .none
        }

        // Whatever arrived before the app quit is replayed, so start the reply over.
        let lastPrompt = conversation.messages.last { $0.role == .user }
        let modelName = session.model.map { agentModelName(agent: session.agent, model: $0, state: state) }
        let reply = Message(id: uuid(), role: .assistant, modelName: modelName ?? session.agent.title, createdAt: now)
        state.$conversations.withLock { conversations in
            if let lastPrompt {
                conversations[id: conversationID]?.messages.removeAll { $0.role == .assistant && $0.createdAt >= lastPrompt.createdAt }
            }
            conversations[id: conversationID]?.messages.append(reply)
        }
        state.responses[conversationID] = ActiveResponse(messageID: reply.id, model: nil, agentModelName: modelName)

        return .run { [backgroundTask, mcp, mcpAuth] send in
            try await backgroundTask.run(session.agent.title) {
                let headers = try await mcpAuth.headers(server: server)
                for try await event in mcp.resumeTool(server: server, headers: headers, streamID: streamID) {
                    switch event {
                    case let .notification(notification):
                        for event in AgentEvent.events(from: notification) {
                            await send(.agentEvent(event, in: conversationID))
                        }
                    case .resumable:
                        break
                    case let .result(result):
                        await send(.agentFinished(result, in: conversationID))
                    }
                }
            }
        } catch: { error, send in
            await send(.streamFailed(Self.describe(error), in: conversationID))
        }
        .cancellable(id: CancelID.response(conversationID), cancelInFlight: true)
    }

    func applyAgentEvent(_ event: AgentEvent, in conversationID: Conversation.ID, state: inout State) {
        // Events after Stop are dropped.
        guard state.responses[conversationID] != nil else { return }

        switch event {
        case let .sessionStarted(threadID, model):
            state.$conversations.withLock { $0[id: conversationID]?.codeSession?.threadID = threadID }
            if let model, let agent = state.conversations[id: conversationID]?.codeSession?.agent {
                let name = agentModelName(agent: agent, model: model, state: state)
                state.responses[conversationID]?.agentModelName = name
                updateReply(in: conversationID, state: &state) { $0.modelName = name }
            }

        case let .textDelta(itemID, text):
            beginAgentText(itemID, in: conversationID, state: &state)
            updateReply(in: conversationID, state: &state) { $0.content += text }

        case let .textCompleted(itemID, text):
            beginAgentText(itemID, in: conversationID, state: &state)
            let prefix = state.responses[conversationID]?.agentTextPrefix ?? ""
            updateReply(in: conversationID, state: &state) { $0.content = prefix + text }

        case let .reasoningDelta(text):
            if let message = reply(in: conversationID, state: state), !message.content.isEmpty || !message.toolCalls.isEmpty {
                startAgentMessage(in: conversationID, state: &state)
            }
            updateReply(in: conversationID, state: &state) { $0.reasoning += text }

        case let .stepStarted(call):
            // Steps go below the text that announced them, so the log reads in order.
            if let message = reply(in: conversationID, state: state), !message.content.isEmpty {
                startAgentMessage(in: conversationID, state: &state)
            }
            state.responses[conversationID]?.agentTextItemID = nil
            updateReply(in: conversationID, state: &state) { message in
                if let index = message.toolCalls.firstIndex(where: { $0.id == call.id }) {
                    message.toolCalls[index] = call
                } else {
                    message.toolCalls.append(call)
                }
            }

        case let .stepFinished(callID, result):
            state.$conversations.withLock { conversations in
                guard let messages = conversations[id: conversationID]?.messages,
                      let message = messages.last(where: { $0.toolCalls.contains { $0.id == callID } }),
                      let index = message.toolCalls.firstIndex(where: { $0.id == callID })
                else { return }
                conversations[id: conversationID]?.messages[id: message.id]?.toolCalls[index].result = result
            }

        case let .failed(error):
            updateReply(in: conversationID, state: &state) { $0.errorDescription = error }
        }
    }

    func finishAgentResponse(_ result: ToolResult, in conversationID: Conversation.ID, state: inout State) {
        let answer = CodeAgent.answer(from: result.content)
        let agent = state.conversations[id: conversationID]?.codeSession?.agent ?? state.codeAgent
        updateReply(in: conversationID, state: &state) { message in
            if result.isError {
                message.errorDescription = message.errorDescription ?? answer.nonBlank ?? "\(agent.title) couldn’t finish."
            } else if message.content.isEmpty, message.toolCalls.isEmpty {
                // Servers that don't stream events still return the final answer.
                message.content = answer
            }
        }
        finishResponse(in: conversationID, state: &state)
    }

    /// Asks the bridge which models the chosen harness can use, once per agent.
    func loadHarnessModels(_ state: inout State) -> Effect<Action> {
        let agent = state.codeAgent
        guard agent.kind == .harness, state.harnessModels[agent.id] == nil, state.loadingModelsFor != agent.id,
              let server = state.codeServer
        else { return .none }
        state.loadingModelsFor = agent.id
        return .run { [mcp, mcpAuth] send in
            let arguments = JSONValue.object(["agent": .string(agent.id)]).jsonString()
            let result = try? await mcp.callTool(server: server, headers: mcpAuth.headers(server: server), name: CodeAgent.harnessModelsTool, arguments: arguments)
            let models = (JSONValue(json: CodeAgent.answer(from: result?.content ?? ""))?.arrayValue ?? []).compactMap { model -> CodeModel? in
                guard let id = model["id"]?.stringValue else { return nil }
                return CodeModel(id: id, title: model["title"]?.stringValue ?? id)
            }
            await send(.harnessModelsLoaded(agentID: agent.id, models))
        }
    }

    /// Applies a settings change to the open conversation's session, before it starts.
    func updateCodeSession(state: inout State, _ update: (inout Conversation.CodeSession) -> Void) {
        guard let conversationID = state.conversationID else { return }
        state.$conversations.withLock { conversations in
            guard var session = conversations[id: conversationID]?.codeSession else { return }
            update(&session)
            conversations[id: conversationID]?.codeSession = session
        }
    }

    /// "Codex · GPT-6-Astra", "Claude Code · Opus".
    private func agentModelName(agent: CodeAgent, model: String, state: State) -> String {
        let options = agent == state.codeAgent ? state.codeModels : []
        return "\(agent.title) · \(agent.displayName(forModel: model, options: options))"
    }

    /// Text from a new agent message: continues the current reply message unless steps came in between.
    private func beginAgentText(_ itemID: String, in conversationID: Conversation.ID, state: inout State) {
        guard state.responses[conversationID]?.agentTextItemID != itemID else { return }
        if let message = reply(in: conversationID, state: state), !message.toolCalls.isEmpty {
            startAgentMessage(in: conversationID, state: &state)
        }
        let content = reply(in: conversationID, state: state)?.content ?? ""
        state.responses[conversationID]?.agentTextItemID = itemID
        state.responses[conversationID]?.agentTextPrefix = content.isEmpty ? "" : content + "\n\n"
    }

    /// Continues the reply in a fresh message, so text and steps interleave in the order they happened.
    private func startAgentMessage(in conversationID: Conversation.ID, state: inout State) {
        let agent = state.conversations[id: conversationID]?.codeSession?.agent ?? state.codeAgent
        let modelName = state.responses[conversationID]?.agentModelName ?? agent.title
        let message = Message(id: uuid(), role: .assistant, modelName: modelName, createdAt: now)
        state.$conversations.withLock { _ = $0[id: conversationID]?.messages.append(message) }
        state.responses[conversationID]?.messageID = message.id
        state.responses[conversationID]?.agentTextItemID = nil
        state.responses[conversationID]?.agentTextPrefix = ""
    }
}
