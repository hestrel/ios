import SwiftUI

struct CodeBlockView: View {
    let language: String?
    let code: String

    /// SVG blocks open on the picture; tap Code for the source.
    @State private var showsSource = false

    /// A finished SVG drawing, as opposed to HTML that merely contains one or a half-streamed block.
    private var isSVG: Bool {
        let lead = code.trimmed.prefix(5).lowercased()
        let tagged = language?.lowercased() == "svg" || lead == "<svg " || lead == "<svg>" || lead == "<?xml"
        return tagged && SVGMarkup.isComplete(code)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.medium) {
                Text(language ?? "code")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if isSVG {
                    Button(showsSource ? "Preview" : "Code", systemImage: showsSource ? "photo" : "chevron.left.forwardslash.chevron.right") {
                        showsSource.toggle()
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                }
                CopyButton(text: code, title: "Copy")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)
            .background(Color.subtleFill)

            if isSVG && !showsSource {
                SVGView(svg: code)
                    .padding(Theme.Spacing.medium)
                    .background(.white)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(.callout, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(Theme.Spacing.medium)
                }
            }
        }
        .background(Color.surface)
        .clipShape(.rect(cornerRadius: Theme.Radius.medium))
    }
}
