import Foundation

nonisolated enum ProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case openAI
    case anthropic
    case gemini
    case ollama
    case openAICompatible

    var id: Self { self }

    var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        case .ollama: "Ollama"
        case .openAICompatible: "OpenAI Compatible"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .ollama: "http://localhost:11434"
        case .openAICompatible: "http://localhost:1234/v1"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .anthropic, .gemini: true
        case .openAI, .ollama, .openAICompatible: false
        }
    }

    var symbol: String {
        switch self {
        case .openAI: "circle.hexagongrid"
        case .anthropic: "asterisk"
        case .gemini: "sparkle"
        case .ollama: "desktopcomputer"
        case .openAICompatible: "server.rack"
        }
    }

    var setupHint: String {
        switch self {
        case .openAI: "Connect your ChatGPT account to use your plan. No API key is needed."
        case .anthropic: "Create a key at console.anthropic.com."
        case .gemini: "Create a key at aistudio.google.com."
        case .ollama: "Run `OLLAMA_HOST=0.0.0.0 ollama serve` on your computer and use its local network address, e.g. http://192.168.1.10:11434."
        case .openAICompatible: "Works with LM Studio, OpenRouter, Groq, Together, vLLM and any server exposing /chat/completions."
        }
    }
}

nonisolated extension ProviderKind {
    /// Who connects to MCP servers and runs their tools.
    enum MCPExecution: Sendable {
        /// The provider's API calls the MCP servers itself.
        case hosted
        /// The app calls the tools and sends the results back to the model.
        case client
    }

    var mcpExecution: MCPExecution {
        switch self {
        case .anthropic: .hosted
        case .openAI, .gemini, .ollama, .openAICompatible: .client
        }
    }

    /// Self-hosted servers can publish their own `mcp.json` for the app to inherit.
    var inheritsMCPServersFromHost: Bool {
        switch self {
        case .ollama, .openAICompatible: true
        case .openAI, .anthropic, .gemini: false
        }
    }

    var mcpExecutionDescription: String {
        switch mcpExecution {
        case .hosted: "Tools run on \(displayName)’s servers, so MCP servers must be reachable from the internet."
        case .client: "Tools run on this device and their results are sent back to the model."
        }
    }
}
