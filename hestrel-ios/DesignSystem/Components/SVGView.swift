import SwiftUI
import WebKit

/// Renders SVG markup, sized to the drawing's own aspect ratio.
///
/// JavaScript is off: SVG can carry scripts, and a picture in a chat has no business running them.
struct SVGView: View {
    let svg: String
    var maxHeight: CGFloat = 420

    @State private var page = SVGView.makePage()

    var body: some View {
        WebView(page)
            .scrollDisabled(true)
            .aspectRatio(SVGMarkup.aspectRatio(of: svg), contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: maxHeight)
            .task(id: svg) {
                page.load(html: SVGMarkup.document(for: svg), baseURL: URL(string: "about:blank")!)
            }
            .accessibilityLabel("Image")
    }

    private static func makePage() -> WebPage {
        var configuration = WebPage.Configuration()
        configuration.defaultNavigationPreferences.allowsContentJavaScript = false
        return WebPage(configuration: configuration)
    }
}

/// Recognizes and measures SVG drawings.
nonisolated enum SVGMarkup {
    /// A finished drawing: has an opening `<svg` and a closing tag, so it isn't still streaming in.
    static func isComplete(_ text: String) -> Bool {
        guard let open = text.range(of: "<svg", options: .caseInsensitive) else { return false }
        return text.range(of: "</svg>", options: [.caseInsensitive, .backwards], range: open.upperBound..<text.endIndex) != nil
    }

    /// Width ÷ height from `viewBox`, or the `width`/`height` attributes; square when neither is usable.
    static func aspectRatio(of svg: String) -> CGFloat {
        if let viewBox = attribute("viewBox", in: svg) {
            let numbers = viewBox.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
            if numbers.count == 4, numbers[2] > 0, numbers[3] > 0 { return numbers[2] / numbers[3] }
        }
        if let width = attribute("width", in: svg).flatMap(leadingNumber),
           let height = attribute("height", in: svg).flatMap(leadingNumber),
           width > 0, height > 0 {
            return width / height
        }
        return 1
    }

    /// The drawing's intended width in points, from its `width` attribute or `viewBox`; `nil` if unknown.
    static func width(of svg: String) -> CGFloat? {
        if let width = attribute("width", in: svg).flatMap(leadingNumber), width > 0 { return width }
        if let viewBox = attribute("viewBox", in: svg) {
            let numbers = viewBox.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
            if numbers.count == 4, numbers[2] > 0 { return numbers[2] }
        }
        return nil
    }

    /// A page that scales the drawing to fill the view, on a transparent background.
    static func document(for svg: String) -> String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:transparent;display:flex;align-items:center;justify-content:center}
        svg,img{max-width:100%;max-height:100%;width:100%;height:100%}</style></head><body>\(svg)</body></html>
        """
    }

    /// The first `<svg …>` tag's value for `name`.
    private static func attribute(_ name: String, in svg: String) -> String? {
        guard let tagStart = svg.range(of: "<svg", options: .caseInsensitive),
              let tagEnd = svg.range(of: ">", range: tagStart.upperBound..<svg.endIndex)
        else { return nil }
        let tag = svg[tagStart.upperBound..<tagEnd.lowerBound]
        guard let match = tag.firstMatch(of: try! Regex("\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']").ignoresCase()),
              let value = match.output[1].substring
        else { return nil }
        return String(value)
    }

    private static func leadingNumber(_ text: String) -> Double? {
        Double(text.prefix { $0.isNumber || $0 == "." })
    }
}
