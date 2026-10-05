import SwiftUI
import UIKit

/// A square preview of an image attachment loaded from disk.
struct AttachmentThumbnail: View {
    let attachment: Attachment
    var size: CGFloat = 64

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.fill
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: Theme.Radius.small))
        .task(id: attachment.id) {
            let url = attachment.fileURL
            let side = size * 3
            image = await Task.detached {
                await UIImage(contentsOfFile: url.path())?.byPreparingThumbnail(ofSize: CGSize(width: side, height: side))
            }.value
        }
    }
}
