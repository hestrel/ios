import ComposableArchitecture
import Foundation

@Reducer
struct ChatFeature {
    @ObservableState
    struct State: Equatable {
        var conversationID: Conversation.ID?
        /// The kind of conversation the next message starts, when no conversation is open yet.
        var newConversationKind = Conversation.Kind.chat
        var draft = ""
        var isModelPickerPresented = false
        var openSettingsAfterModelPicker = false
        var draftAttachments: [Attachment] = []
        var isProcessingAttachments = false
        /// Replies being generated, keyed by conversation. They keep going when another chat is opened.
        var responses: [Conversation.ID: ActiveResponse] = [:]
        @Presents var alert: AlertState<Action.Alert>?

        @Shared(.conversations) var conversations: IdentifiedArrayOf<Conversation>
        @Shared(.providers) var providers: IdentifiedArrayOf<Provider>
        @Shared(.modelCatalog) var catalog: ModelCatalog
        @Shared(.selectedModelID) var selectedModelID: String?
        @Shared(.reasoningEffort) var reasoningEffort: ReasoningEffort
        @Shared(.webSearchEnabled) var webSearchEnabled: Bool
        @Shared(.systemPrompt) var systemPrompt: String
        @Shared(.mcpServers) var mcpServers: IdentifiedArrayOf<MCPServer>
        @Shared(.toolCatalog) var toolCatalog: ToolCatalog
        @Shared(.googleConnection) var googleConnection: GoogleConnection

        init(conversationID: Conversation.ID? = nil) {
            self.conversationID = conversationID
        }

        var conversation: Conversation? {
            conversationID.flatMap { conversations[id: $0] }
        }

        var kind: Conversation.Kind {
            conversation?.kind ?? newConversationKind
        }

        var messages: IdentifiedArrayOf<Message> {
            conversation?.messages ?? []
        }

        var modelGroups: [ModelGroup] {
            providers
                .filter(\.isEnabled)
                .map { ModelGroup(provider: $0, models: catalog.models(for: $0.id)) }
                .filter { !$0.models.isEmpty }
        }

        /// An explicit choice never silently falls back to a different model.
        /// The open chat's own model while it's available, otherwise the default for new chats.
        var selectedModel: ChatModel? {
            let enabledProviderIDs = modelGroups.map(\.provider.id)
            if let chatModelID = conversation?.modelID,
               let model = catalog.selection(id: chatModelID, enabledProviderIDs: enabledProviderIDs) {
                return model
            }
            return catalog.selection(id: selectedModelID, enabledProviderIDs: enabledProviderIDs)
        }

        /// The effort shown and sent for the selected model; providers without the setting always use `auto`.
        var effectiveEffort: ReasoningEffort {
            selectedProvider?.kind.supportsReasoningEffort == true ? reasoningEffort : .auto
        }

        /// The provider serving the selected model; its MCP servers are the ones in play.
        var selectedProvider: Provider? {
            selectedModel.flatMap { providers[id: $0.providerID] }
        }

        var providerMCPServers: [MCPServer] {
            guard let provider = selectedProvider else { return [] }
            return mcpServers.filter { $0.providerID == provider.id }
        }

        /// The reply streaming into the open conversation, if any.
        var streamingMessageID: Message.ID? {
            conversationID.flatMap { responses[$0]?.messageID }
        }

        var isStreaming: Bool { streamingMessageID != nil }

        var canSend: Bool {
            (draft.nonBlank != nil || !draftAttachments.isEmpty) && !isStreaming && !isProcessingAttachments
        }
    }

    /// A reply in progress: the assistant message it streams into and the model producing it.
    struct ActiveResponse: Equatable {
        var messageID: Message.ID
        let model: ChatModel
        /// Model → tool → model round-trips so far, to stop runaway loops.
        var toolRounds = 0
    }

    struct ModelGroup: Identifiable {
        let provider: Provider
        let models: [ChatModel]
        var id: Provider.ID { provider.id }
    }

    enum Action: BindableAction {
        case alert(PresentationAction<Alert>)
        case attachmentRemoved(Attachment.ID)
        case attachmentsAdded([Attachment])
        case attachmentsFailed(String)
        case binding(BindingAction<State>)
        case conversationRemoved(Conversation.ID)
        case delegate(Delegate)
        case effortSelected(ReasoningEffort)
        case imagesPicked([Data])
        case modelPickerDismissed
        case modelPickerManageProvidersTapped
        case modelPickerTapped
        case modelSelected(String)
        case open(Conversation.ID)
        case openSettingsTapped
        case regenerateTapped
        case sendTapped
        case startNewConversation(Conversation.Kind)
        case stopTapped
        case streamEvent(ChatStreamEvent, in: Conversation.ID)
        case streamFailed(String, in: Conversation.ID)
        case streamFinished(Conversation.ID)
        case suggestionTapped(String)
        case titleGenerated(String, for: Conversation.ID)
        case toolCallFinished(id: ToolCall.ID, ToolResult, in: Conversation.ID)
        case toolCallsFinished(Conversation.ID)

        enum Alert: Equatable {
            case openSettings
        }

        enum Delegate: Equatable {
            case conversationStarted(Conversation.ID)
            case openSettings
        }
    }

    nonisolated enum CancelID: Hashable {
        case response(Conversation.ID)
        case title(Conversation.ID)
    }

    /// Upper bound on model → tool → model round-trips for a single reply.
    static let maxToolRounds = 10

    @Dependency(\.attachments) var attachments
    @Dependency(\.backgroundTask) var backgroundTask
    @Dependency(\.credentials) var credentials
    @Dependency(\.date.now) var now
    @Dependency(\.llm) var llm
    @Dependency(\.mcp) var mcp
    @Dependency(\.google) var google
    @Dependency(\.webSearch) var webSearch
    @Dependency(\.uuid) var uuid

    var body: some Reducer<State, Action> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .alert(.presented(.openSettings)), .openSettingsTapped:
                return .send(.delegate(.openSettings))

            case .alert, .binding, .delegate:
                return .none

            case let .conversationRemoved(conversationID):
                state.responses[conversationID] = nil
                return .merge(
                    .cancel(id: CancelID.response(conversationID)),
                    .cancel(id: CancelID.title(conversationID))
                )

            case let .attachmentRemoved(id):
                guard let attachment = state.draftAttachments.first(where: { $0.id == id }) else { return .none }
                state.draftAttachments.removeAll { $0.id == id }
                return .run { [attachments] _ in attachments.delete(attachments: [attachment]) }

            case let .attachmentsAdded(added):
                state.isProcessingAttachments = false
                state.draftAttachments += added
                return .none

            case let .attachmentsFailed(message):
                state.isProcessingAttachments = false
                state.alert = AlertState { TextState(message) }
                return .none

            case let .imagesPicked(images):
                guard !images.isEmpty else { return .none }
                state.isProcessingAttachments = true
                return .run { [attachments] send in
                    var saved: [Attachment] = []
                    for image in images {
                        saved.append(try await attachments.save(imageData: image))
                    }
                    await send(.attachmentsAdded(saved))
                } catch: { error, send in
                    await send(.attachmentsFailed(error.localizedDescription))
                }

            case let .effortSelected(effort):
                state.$reasoningEffort.withLock { $0 = effort }
                return .none

            case .modelPickerManageProvidersTapped:
                state.openSettingsAfterModelPicker = true
                state.isModelPickerPresented = false
                return .none

            case .modelPickerDismissed:
                guard state.openSettingsAfterModelPicker else { return .none }
                state.openSettingsAfterModelPicker = false
                return .send(.delegate(.openSettings))

            case .modelPickerTapped:
                state.isModelPickerPresented = true
                return .none

            case let .modelSelected(id):
                guard let model = state.catalog.models[id: id],
                      state.providers[id: model.providerID]?.isEnabled == true else { return .none }
                // The open chat keeps this model, and new chats start with it.
                state.$selectedModelID.withLock { $0 = id }
                if let conversationID = state.conversationID {
                    state.$conversations.withLock { $0[id: conversationID]?.modelID = id }
                }
                state.isModelPickerPresented = false
                return .none

            case let .open(conversationID):
                guard conversationID != state.conversationID else { return .none }
                state.conversationID = conversationID
                state.draft = ""
                return .none

            case .regenerateTapped:
                guard !state.isStreaming,
                      let conversationID = state.conversationID,
                      let lastPrompt = state.messages.last(where: { $0.role == .user })
                else { return .none }
                // Drop the whole previous reply, including any tool-calling steps.
                state.$conversations.withLock { conversations in
                    conversations[id: conversationID]?.messages.removeAll {
                        $0.role == .assistant && $0.createdAt >= lastPrompt.createdAt
                    }
                }
                return startResponse(&state, in: conversationID)

            case .sendTapped:
                guard state.canSend else { return .none }
                guard state.selectedModel != nil else {
                    state.alert = .noModelAvailable
                    return .none
                }
                let prompt = state.draft.trimmed
                let images = state.draftAttachments
                state.draft = ""
                state.draftAttachments = []
                let (conversationID, isNew) = appendUserMessage(prompt, attachments: images, to: &state)
                return .merge(
                    isNew ? .send(.delegate(.conversationStarted(conversationID))) : .none,
                    startResponse(&state, in: conversationID)
                )

            case let .startNewConversation(kind):
                state.conversationID = nil
                state.newConversationKind = kind
                state.draft = ""
                return .none

            case .stopTapped:
                guard let conversationID = state.conversationID else { return .none }
                finishResponse(in: conversationID, state: &state)
                return .cancel(id: CancelID.response(conversationID))

            case let .streamEvent(event, conversationID):
                updateReply(in: conversationID, state: &state) { message in
                    switch event {
                    case let .text(text): message.content += text
                    case let .textReplaced(text): message.content = text
                    case let .reasoning(text): message.reasoning += text
                    case let .toolCall(call):
                        if let index = message.toolCalls.firstIndex(where: { $0.id == call.id }) {
                            message.toolCalls[index] = call
                        } else {
                            message.toolCalls.append(call)
                        }
                    }
                }
                return .none

            case let .streamFailed(error, conversationID):
                updateReply(in: conversationID, state: &state) { $0.errorDescription = error }
                state.responses[conversationID] = nil
                return .none

            case let .streamFinished(conversationID):
                guard let response = state.responses[conversationID] else { return .none }
                // Calls the provider ran itself already carry their result; the rest are ours to run.
                let pendingCalls = reply(in: conversationID, state: state)?.toolCalls.filter { !$0.isHosted && $0.result == nil } ?? []
                guard !pendingCalls.isEmpty else {
                    state.responses[conversationID] = nil
                    return generateTitleIfNeeded(in: conversationID, model: response.model, state: state)
                }
                guard response.toolRounds < Self.maxToolRounds else {
                    updateReply(in: conversationID, state: &state) { message in
                        for index in message.toolCalls.indices where message.toolCalls[index].result == nil {
                            message.toolCalls[index].result = ToolResult(content: "Tool call limit reached.", isError: true)
                        }
                    }
                    state.responses[conversationID] = nil
                    return .none
                }
                state.responses[conversationID]?.toolRounds += 1
                return runTools(pendingCalls, in: conversationID, state: state)

            case let .suggestionTapped(prompt):
                state.draft = prompt
                return .send(.sendTapped)

            case let .titleGenerated(title, conversationID):
                state.$conversations.withLock { $0[id: conversationID]?.title = title }
                return .none

            case let .toolCallFinished(callID, result, conversationID):
                updateReply(in: conversationID, state: &state) { message in
                    guard let index = message.toolCalls.firstIndex(where: { $0.id == callID }) else { return }
                    message.toolCalls[index].result = result
                }
                return .none

            case let .toolCallsFinished(conversationID):
                // Hand the tool results back to the model in a fresh assistant message.
                return startResponse(&state, in: conversationID, isContinuation: true)
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }

    // MARK: Helpers

    private func appendUserMessage(
        _ prompt: String,
        attachments: [Attachment],
        to state: inout State
    ) -> (Conversation.ID, isNew: Bool) {
        let message = Message(id: uuid(), role: .user, content: prompt, attachments: attachments, createdAt: now)

        if let conversationID = state.conversationID, state.conversations[id: conversationID] != nil {
            state.$conversations.withLock {
                $0[id: conversationID]?.messages.append(message)
                $0[id: conversationID]?.updatedAt = now
            }
            return (conversationID, false)
        }

        let conversation = Conversation(
            id: uuid(),
            kind: state.newConversationKind,
            title: prompt.isEmpty ? "Image" : Conversation.provisionalTitle(for: prompt),
            messages: [message],
            createdAt: now
        )
        state.$conversations.withLock { _ = $0.insert(conversation, at: 0) }
        state.conversationID = conversation.id
        return (conversation.id, true)
    }

    private func startResponse(
        _ state: inout State,
        in conversationID: Conversation.ID,
        isContinuation: Bool = false
    ) -> Effect<Action> {
        // A tool-call continuation stays on the model that started the reply.
        let previous = state.responses[conversationID]
        let chosenModel = isContinuation ? previous?.model : state.selectedModel
        guard let model = chosenModel,
              let provider = state.providers[id: model.providerID],
              let conversation = state.conversations[id: conversationID]
        else {
            state.alert = .noModelAvailable
            state.responses[conversationID] = nil
            return .none
        }
        let effort = state.reasoningEffort
        let systemPrompt = [conversation.kind.systemPrompt, state.systemPrompt.nonBlank]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        let history = conversation.messages.filter(\.isPartOfHistory)
        let servers = state.mcpServers.filter { $0.providerID == provider.id && $0.isEnabled }
        let serverIDs = Set(servers.map(\.id))
        // Web search runs on the provider's servers where it can, and on this device everywhere else.
        let builtInWebSearch = state.webSearchEnabled && provider.kind.hasBuiltInWebSearch
        let webTools = state.webSearchEnabled && !provider.kind.hasBuiltInWebSearch ? WebTool.allCases.map(\.definition) : []
        let tools = (provider.kind.mcpExecution == .client
            ? state.toolCatalog.tools.filter { serverIDs.contains($0.serverID) }.map(\.definition) : [])
            + state.googleConnection.tools
            + webTools
        let hostedServers = provider.kind.mcpExecution == .hosted ? servers.filter(\.hasValidURL) : []

        let reply = Message(id: uuid(), role: .assistant, modelName: model.displayName, createdAt: now)
        state.$conversations.withLock {
            $0[id: conversationID]?.messages.append(reply)
            $0[id: conversationID]?.modelID = model.id
            $0[id: conversationID]?.updatedAt = now
        }
        state.responses[conversationID] = ActiveResponse(
            messageID: reply.id,
            model: model,
            toolRounds: isContinuation ? previous?.toolRounds ?? 0 : 0
        )

        return .run { [attachments, backgroundTask, credentials, llm] send in
            try await backgroundTask.run("Reply") {
                let request = ChatRequest(
                    provider: provider,
                    apiKey: provider.kind == .openAI ? nil : credentials.secret(id: provider.id),
                    model: model.name,
                    systemPrompt: systemPrompt.nonBlank,
                    turns: history.map { message in
                        ChatRequest.Turn(
                            role: message.role,
                            content: message.display.answer,
                            images: message.attachments.compactMap { try? attachments.load(attachment: $0) },
                            toolCalls: message.replayableToolCalls
                        )
                    },
                    reasoningEffort: provider.kind.supportsReasoningEffort ? effort : .auto,
                    webSearchEnabled: builtInWebSearch,
                    tools: tools,
                    hostedMCPServers: hostedServers.map { server in
                        HostedMCPServer(
                            name: ToolCatalog.sanitize(server.name),
                            url: server.url.trimmed,
                            headers: server.authHeaders(token: credentials.secret(id: server.id))
                        )
                    }
                )
                for try await event in llm.streamChat(request: request) {
                    await send(.streamEvent(event, in: conversationID))
                }
            }
            await send(.streamFinished(conversationID))
        } catch: { error, send in
            await send(.streamFailed(Self.describe(error), in: conversationID))
        }
        .cancellable(id: CancelID.response(conversationID), cancelInFlight: true)
    }

    /// Runs the requested tools one after another on their MCP servers.
    private func runTools(_ calls: [ToolCall], in conversationID: Conversation.ID, state: State) -> Effect<Action> {
        let invocations = calls.map { call in
            let tool = state.toolCatalog.tools[id: call.name]
            return (call: call, tool: tool, server: tool.flatMap { state.mcpServers[id: $0.serverID] })
        }
        return .run { [backgroundTask, credentials, mcp, google, webSearch] send in
            try await backgroundTask.run("Tools") {
                for invocation in invocations {
                    let result: ToolResult
                    if WebTool(rawValue: invocation.call.name) != nil {
                        do {
                            result = try await webSearch.call(name: invocation.call.name, arguments: invocation.call.arguments)
                        } catch {
                            result = ToolResult(content: error.localizedDescription, isError: true)
                        }
                    } else if GoogleTool(rawValue: invocation.call.name) != nil {
                        do {
                            result = try await google.call(name: invocation.call.name, arguments: invocation.call.arguments)
                        } catch {
                            result = ToolResult(content: error.localizedDescription, isError: true)
                        }
                    } else if let tool = invocation.tool, let server = invocation.server, server.isEnabled {
                        do {
                            result = try await mcp.callTool(
                                server: server,
                                headers: server.authHeaders(token: credentials.secret(id: server.id)),
                                name: tool.name,
                                arguments: invocation.call.arguments
                            )
                        } catch {
                            result = ToolResult(content: error.localizedDescription, isError: true)
                        }
                    } else {
                        result = ToolResult(content: "Tool “\(invocation.call.name)” is not available.", isError: true)
                    }
                    await send(.toolCallFinished(id: invocation.call.id, result, in: conversationID))
                }
            }
            await send(.toolCallsFinished(conversationID))
        }
        .cancellable(id: CancelID.response(conversationID), cancelInFlight: true)
    }

    /// Asks the model for a short title once the first reply of a conversation completes.
    private func generateTitleIfNeeded(in conversationID: Conversation.ID, model: ChatModel, state: State) -> Effect<Action> {
        let prompts = state.conversations[id: conversationID]?.messages.filter { $0.role == .user } ?? []
        guard prompts.count == 1,
              let prompt = prompts.first?.content.nonBlank,
              let provider = state.providers[id: model.providerID]
        else { return .none }

        return .run { [credentials, llm] send in
            let request = ChatRequest(
                provider: provider,
                apiKey: provider.kind == .openAI ? nil : credentials.secret(id: provider.id),
                model: model.name,
                systemPrompt: "You write short, descriptive titles for chats. Reply with the title only: 2 to 6 words, no quotes, no punctuation at the end.",
                turns: [.init(role: .user, content: "Write a title for a chat that starts with:\n\n\(prompt.prefix(1_000))")]
            )
            var reply = Message(id: UUID(), role: .assistant, createdAt: .distantPast)
            for try await case let .text(text) in llm.streamChat(request: request) {
                reply.content += text
            }
            if let title = Self.sanitizeTitle(reply.display.answer) {
                await send(.titleGenerated(title, for: conversationID))
            }
        } catch: { _, _ in
            // Keep the provisional title; a failed title request shouldn't surface as an error.
        }
        .cancellable(id: CancelID.title(conversationID), cancelInFlight: true)
    }

    /// The assistant message a conversation's reply is streaming into.
    private func reply(in conversationID: Conversation.ID, state: State) -> Message? {
        guard let messageID = state.responses[conversationID]?.messageID else { return nil }
        return state.conversations[id: conversationID]?.messages[id: messageID]
    }

    private func updateReply(in conversationID: Conversation.ID, state: inout State, _ update: (inout Message) -> Void) {
        guard let messageID = state.responses[conversationID]?.messageID else { return }
        state.$conversations.withLock { conversations in
            guard var message = conversations[id: conversationID]?.messages[id: messageID] else { return }
            update(&message)
            conversations[id: conversationID]?.messages[id: messageID] = message
        }
    }

    /// Ends a conversation's reply, discarding it if nothing arrived yet.
    private func finishResponse(in conversationID: Conversation.ID, state: inout State) {
        guard let messageID = state.responses.removeValue(forKey: conversationID)?.messageID else { return }
        state.$conversations.withLock { conversations in
            guard let message = conversations[id: conversationID]?.messages[id: messageID],
                  message.content.isEmpty, message.reasoning.isEmpty, message.toolCalls.isEmpty
            else { return }
            conversations[id: conversationID]?.messages.remove(id: messageID)
        }
    }

    /// A dropped connection usually means iOS suspended the app mid-reply; say so instead of the raw error.
    nonisolated static func describe(_ error: any Error) -> String {
        switch (error as? URLError)?.code {
        case .networkConnectionLost?:
            "The reply was interrupted, usually because Hestrel went to the background. Tap Try Again to continue."
        case .notConnectedToInternet?:
            "You’re offline. Check your connection and tap Try Again."
        default:
            error.localizedDescription
        }
    }

    nonisolated static func sanitizeTitle(_ raw: String) -> String? {
        let firstLine = raw.trimmed.components(separatedBy: .newlines).first ?? ""
        let title = firstLine
            .replacing(/[*_`#]/, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’.").union(.whitespaces))
        guard let title = title.nonBlank else { return nil }
        return title.count > 60 ? String(title.prefix(60)) : title
    }
}

extension AlertState where Action == ChatFeature.Action.Alert {
    static let noModelAvailable = AlertState {
        TextState("No Model Available")
    } actions: {
        ButtonState(action: .openSettings) {
            TextState("Open Settings")
        }
        ButtonState(role: .cancel) {
            TextState("Cancel")
        }
    } message: {
        TextState("Connect a provider in Settings to start chatting.")
    }
}
