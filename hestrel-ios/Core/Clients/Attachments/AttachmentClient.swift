import ComposableArchitecture
import Foundation
import UIKit

/// Stores image attachments as files under Documents/Attachments.
@DependencyClient
nonisolated struct AttachmentClient: Sendable {
    /// Downscales and re-encodes an image, then saves it.
    var save: @Sendable (_ imageData: Data) async throws -> Attachment
    var load: @Sendable (_ attachment: Attachment) throws -> ImageInput
    var delete: @Sendable (_ attachments: [Attachment]) -> Void
}

nonisolated enum AttachmentError: LocalizedError {
    case unreadableImage

    var errorDescription: String? { "That image couldn’t be read." }
}

nonisolated extension AttachmentClient: DependencyKey {
    /// Long edge of stored images; larger images cost more tokens without helping most models.
    private static let maxDimension: CGFloat = 1568

    static let liveValue: AttachmentClient = {
        AttachmentClient(
            save: { imageData in
                guard let image = UIImage(data: imageData) else { throw AttachmentError.unreadableImage }
                let resized = await image.byPreparingThumbnail(ofSize: fittedSize(image.size)) ?? image
                guard let jpeg = resized.jpegData(compressionQuality: 0.8) else { throw AttachmentError.unreadableImage }
                let attachment = Attachment(id: UUID(), mimeType: "image/jpeg")
                try FileManager.default.createDirectory(at: Attachment.storageDirectory, withIntermediateDirectories: true)
                try jpeg.write(to: attachment.fileURL, options: .atomic)
                return attachment
            },
            load: { attachment in
                ImageInput(mimeType: attachment.mimeType, data: try Data(contentsOf: attachment.fileURL))
            },
            delete: { attachments in
                for attachment in attachments {
                    try? FileManager.default.removeItem(at: attachment.fileURL)
                }
            }
        )
    }()

    static let testValue = AttachmentClient()

    private static func fittedSize(_ size: CGSize) -> CGSize {
        let scale = min(1, maxDimension / max(size.width, size.height, 1))
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}

nonisolated extension DependencyValues {
    var attachments: AttachmentClient {
        get { self[AttachmentClient.self] }
        set { self[AttachmentClient.self] = newValue }
    }
}
