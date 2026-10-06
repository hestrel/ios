import SwiftUI

/// A Markdown image: a remote picture, a `data:` URL, or an SVG from either.
struct MarkdownImageView: View {
    let alt: String
    let url: String

    var body: some View {
        Group {
            if let svg = MarkdownImageSource.inlineSVG(url) {
                SVGView(svg: svg)
                    .frame(maxWidth: SVGMarkup.width(of: svg))
            } else if let image = MarkdownImageSource.inlineBitmap(url) {
                fitted(image)
            } else if let remote = URL(string: url), ["http", "https"].contains(remote.scheme?.lowercased() ?? "") {
                if remote.pathExtension.lowercased() == "svg" {
                    // WebKit fetches and draws remote SVG through an <img>, which never runs scripts.
                    SVGView(svg: "<img src=\"\(remote.absoluteString)\" alt=\"\">")
                } else {
                    switch remoteImage {
                    case let .loaded(image)?: fitted(image)
                    case .failed?: placeholder(systemImage: "photo.badge.exclamationmark")
                    case nil: placeholder(systemImage: "photo").overlay { ProgressView() }
                    }
                }
            } else {
                placeholder(systemImage: "photo.badge.exclamationmark")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 420, alignment: .leading)
        .task(id: url) { await loadRemoteImage() }
        .accessibilityLabel(alt.isEmpty ? "Image" : alt)
    }

    private enum RemoteImage { case loaded(UIImage), failed }
    @State private var remoteImage: RemoteImage?

    /// Natural size (pixels read as @2x), shrunk to fit the chat but never enlarged.
    private func fitted(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: image.size.width * image.scale / 2, maxHeight: image.size.height * image.scale / 2)
            .clipShape(.rect(cornerRadius: Theme.Radius.small))
    }

    private func loadRemoteImage() async {
        guard remoteImage == nil, let remote = URL(string: url), ["http", "https"].contains(remote.scheme?.lowercased() ?? ""),
              remote.pathExtension.lowercased() != "svg"
        else { return }
        let image = try? await URLSession.shared.data(from: remote).0
        remoteImage = image.flatMap(UIImage.init(data:)).map(RemoteImage.loaded) ?? .failed
    }

    private func placeholder(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.title2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 160)
            .background(Color.surface)
    }
}

/// Decodes `data:` image URLs.
nonisolated enum MarkdownImageSource {
    static func inlineSVG(_ url: String) -> String? {
        guard url.lowercased().hasPrefix("data:image/svg+xml") else { return nil }
        return payload(of: url).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func inlineBitmap(_ url: String) -> UIImage? {
        guard url.lowercased().hasPrefix("data:image/"), !url.lowercased().hasPrefix("data:image/svg") else { return nil }
        return payload(of: url).flatMap(UIImage.init(data:))
    }

    /// The bytes after the comma, base64- or percent-decoded according to the header.
    private static func payload(of url: String) -> Data? {
        guard let comma = url.firstIndex(of: ",") else { return nil }
        let header = url[..<comma].lowercased()
        let body = String(url[url.index(after: comma)...])
        if header.hasSuffix(";base64") {
            return Data(base64Encoded: body, options: .ignoreUnknownCharacters)
        }
        return body.removingPercentEncoding.map { Data($0.utf8) }
    }
}
