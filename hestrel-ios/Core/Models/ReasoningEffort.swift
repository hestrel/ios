import Foundation

/// How hard a reasoning model should think before answering.
///
/// `auto` sends nothing, leaving each model on its own default, so it's always safe to use.
nonisolated enum ReasoningEffort: String, CaseIterable, Codable, Identifiable, Sendable {
    case auto
    case low
    case medium
    case high

    var id: Self { self }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    /// The value providers expect, or `nil` to leave the model's default in place.
    var apiValue: String? {
        self == .auto ? nil : rawValue
    }
}

nonisolated extension ProviderKind {
    /// Whether the provider's API accepts a reasoning-effort setting.
    var supportsReasoningEffort: Bool {
        switch self {
        case .openAI, .anthropic, .gemini, .openAICompatible: true
        case .ollama: false
        }
    }
}
