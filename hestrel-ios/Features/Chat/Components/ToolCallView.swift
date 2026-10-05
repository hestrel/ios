import SwiftUI

/// A tool call in the chat log, ChatGPT style: a quiet one-line summary with the app's logo
/// that expands to show the request and the response.
struct ToolCallView: View {
    let call: ToolCall
    let isRunning: Bool

    @State private var isExpanded = false

    private var googleTool: GoogleTool? { GoogleTool(rawValue: call.name) }
    private var webActivity: WebActivity? { WebActivity(call) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                HStack(spacing: Theme.Spacing.small) {
                    icon
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if isRunning {
                        ProgressView()
                            .controlSize(.mini)
                    } else if call.result?.isError == true {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    section("Request", text: JSONValue(json: call.arguments)?.jsonString(pretty: true) ?? call.arguments)
                    if let result = call.result {
                        section(result.isError ? "Error" : "Response", text: result.content)
                    }
                }
                .padding(Theme.Spacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.surface, in: .rect(cornerRadius: Theme.Radius.medium))
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let googleTool {
            GoogleServiceLogo(service: googleTool.service, size: 18)
        } else {
            Image(systemName: webActivity != nil ? "globe" : "hammer")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .symbolEffect(.pulse, isActive: isRunning)
        }
    }

    private var title: String {
        if let googleTool {
            return isRunning ? googleTool.progressTitle : googleTool.completedTitle
        }
        if let webActivity {
            return isRunning ? webActivity.progressTitle : webActivity.completedTitle
        }
        return isRunning ? "Running \(call.name)…" : "Used \(call.name)"
    }

    /// The search query or site for web activity; otherwise where the tool came from.
    /// Google tools are identified by their logo already.
    private var subtitle: String? {
        if let webActivity { return webActivity.detail }
        guard googleTool == nil else { return nil }
        return switch (call.serverName, call.hostedBy) {
        case let (server?, host?) where server != "Web": "\(server) · \(host)"
        case let (server?, _): server == "Web" ? nil : server
        case let (nil, host?): host
        case (nil, nil): nil
        }
    }

    private func section(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text.count > 4_000 ? String(text.prefix(4_000)) + "\n…" : text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }
}

private extension GoogleTool {
    var progressTitle: String {
        switch self {
        case .gmailSearch: "Searching Gmail…"
        case .gmailRead: "Reading email…"
        case .calendarList: "Checking calendars…"
        case .calendarEvents: "Checking Calendar…"
        case .driveSearch: "Searching Drive…"
        case .driveGet: "Getting file details…"
        case .driveRead: "Reading document…"
        }
    }

    var completedTitle: String {
        switch self {
        case .gmailSearch: "Searched Gmail"
        case .gmailRead: "Read an email"
        case .calendarList: "Checked calendars"
        case .calendarEvents: "Checked Calendar"
        case .driveSearch: "Searched Drive"
        case .driveGet: "Got file details"
        case .driveRead: "Read a document"
        }
    }
}

/// Web search and page reads, whether the provider ran them (OpenAI, Anthropic) or the app did.
private enum WebActivity {
    case search(query: String?)
    case readPage(url: String?)
    case findInPage(url: String?)

    init?(_ call: ToolCall) {
        let arguments = JSONValue(json: call.arguments)
        let query = arguments?["query"]?.stringValue ?? arguments?["queries"]?.arrayValue?.first?.stringValue
        let url = arguments?["url"]?.stringValue
        switch (WebTool(rawValue: call.name), call.serverName == "Web" ? call.name : nil) {
        case (.search, _), (nil, "Web search"): self = .search(query: query)
        case (.fetch, _), (nil, "Open page"): self = .readPage(url: url)
        case (nil, "Find in page"): self = .findInPage(url: url)
        default: return nil
        }
    }

    var progressTitle: String {
        switch self {
        case .search: "Searching the web…"
        case .readPage: "Reading a page…"
        case .findInPage: "Searching the page…"
        }
    }

    var completedTitle: String {
        switch self {
        case .search: "Searched the web"
        case .readPage: "Read a page"
        case .findInPage: "Searched the page"
        }
    }

    var detail: String? {
        switch self {
        case let .search(query): query
        case let .readPage(url), let .findInPage(url): url.flatMap { URL(string: $0)?.host() } ?? url
        }
    }
}
