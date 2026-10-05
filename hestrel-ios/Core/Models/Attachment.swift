import Foundation

/// An image attached to a user message. The bytes live on disk (see `AttachmentClient`), not in the chat history.
nonisolated struct Attachment: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: UUID
    let mimeType: String

    var fileExtension: String {
        mimeType == "image/png" ? "png" : "jpg"
    }

    static let storageDirectory = URL.documentsDirectory.appending(component: "Attachments", directoryHint: .isDirectory)

    var fileURL: URL {
        Self.storageDirectory.appending(component: "\(id.uuidString).\(fileExtension)")
    }
}

/// Image bytes ready to send to a model.
nonisolated struct ImageInput: Equatable, Sendable {
    let mimeType: String
    let data: Data

    var base64: String { data.base64EncodedString() }
    var dataURL: String { "data:\(mimeType);base64,\(base64)" }
}
