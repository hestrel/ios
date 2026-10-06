import Foundation

/// A popular app with a hosted MCP server, offered as a one-tap plugin.
nonisolated struct Connector: Equatable, Identifiable, Sendable {
    enum Auth: Equatable, Sendable {
        /// MCP's OAuth flow with dynamic client registration.
        case oauth
        /// A personal access token the user creates on the service's website.
        case token(createURL: String)
        /// Open server; no sign-in.
        case none
    }

    let id: String
    let name: String
    let summary: String
    let url: String
    let auth: Auth

    /// The logo in the asset catalog's `Connectors` folder.
    var logoAsset: String { "Connectors/\(id)" }
}

nonisolated extension Connector {
    /// Only services whose MCP server lets any app register. Figma, Canva, Asana, Box and Atlassian
    /// limit sign-in to apps they've approved, so they can't be offered here.
    static let directory: [Connector] = [
        Connector(id: "notion", name: "Notion", summary: "Search and edit pages and databases", url: "https://mcp.notion.com/mcp", auth: .oauth),
        Connector(id: "linear", name: "Linear", summary: "Find and update issues and projects", url: "https://mcp.linear.app/mcp", auth: .oauth),
        Connector(id: "github", name: "GitHub", summary: "Repositories, issues and pull requests", url: "https://api.githubcopilot.com/mcp/",
                  auth: .token(createURL: "https://github.com/settings/personal-access-tokens/new")),
        Connector(id: "stripe", name: "Stripe", summary: "Customers, payments and invoices", url: "https://mcp.stripe.com", auth: .oauth),
        Connector(id: "sentry", name: "Sentry", summary: "Investigate errors and performance issues", url: "https://mcp.sentry.dev/mcp", auth: .oauth),
        Connector(id: "vercel", name: "Vercel", summary: "Projects, deployments and logs", url: "https://mcp.vercel.com", auth: .oauth),
        Connector(id: "supabase", name: "Supabase", summary: "Databases, tables and SQL", url: "https://mcp.supabase.com/mcp", auth: .oauth),
        Connector(id: "cloudflare", name: "Cloudflare", summary: "Workers, KV, R2 and D1 resources", url: "https://bindings.mcp.cloudflare.com/mcp", auth: .oauth),
        Connector(id: "intercom", name: "Intercom", summary: "Conversations and customer data", url: "https://mcp.intercom.com/mcp", auth: .oauth),
        Connector(id: "paypal", name: "PayPal", summary: "Invoices, orders and transactions", url: "https://mcp.paypal.com/mcp", auth: .oauth),
        Connector(id: "square", name: "Square", summary: "Payments, catalog and orders", url: "https://mcp.squareup.com/mcp", auth: .oauth),
        Connector(id: "webflow", name: "Webflow", summary: "Sites, pages and CMS collections", url: "https://mcp.webflow.com/mcp", auth: .oauth),
        Connector(id: "huggingface", name: "Hugging Face", summary: "Search models, datasets and papers", url: "https://huggingface.co/mcp", auth: .none),
    ]

    static func named(_ id: String?) -> Connector? {
        id.flatMap { id in directory.first { $0.id == id } }
    }
}
