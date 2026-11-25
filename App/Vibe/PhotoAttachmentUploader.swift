import Foundation
import PhotosUI
import SwiftUI
import UIKit
import SSHKit
import Store

/// Errors raised while preparing or uploading an attached image over SFTP.
enum PhotoAttachmentError: LocalizedError, Sendable {
    case notSSHConnection
    case loadFailed
    case invalidImage
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .notSSHConnection:
            "An active SSH session is required to upload attachments."
        case .loadFailed:
            "Could not load the selected photo."
        case .invalidImage:
            "The selected item could not be decoded as an image."
        case .encodingFailed:
            "Could not encode the image for upload."
        }
    }
}

/// Resized and encoded image payload ready for SFTP upload.
struct PreparedPhotoAttachment: Sendable {
    let data: Data
    let filename: String
}

/// Downscales picked screenshots/photos and uploads them to `/tmp` on the remote host via SFTP.
enum PhotoAttachmentUploader {
    static let maxLongestEdge: CGFloat = 2048
    static let maxPNGBytes = 2 * 1024 * 1024

    /// Loads `item`, resizes/encodes it off the main thread, uploads via SFTP, and returns the remote POSIX path.
    static func upload(item: PhotosPickerItem, session: any Session) async throws -> String {
        guard let sshConnection = session as? SSHConnection else {
            throw PhotoAttachmentError.notSSHConnection
        }
        guard let rawData = try await item.loadTransferable(type: Data.self) else {
            throw PhotoAttachmentError.loadFailed
        }

        let prepared = try await Task.detached(priority: .userInitiated) {
            try prepareAttachment(from: rawData)
        }.value

        let remotePath = RemoteAttachmentHelper.remotePath(filename: prepared.filename)
        try await sshConnection.sftpUploadFile(data: prepared.data, remotePath: remotePath)
        return remotePath
    }

    /// Downscales `rawData` to at most `maxLongestEdge` px and encodes as PNG (falling back to JPEG if > 2 MB).
    nonisolated static func prepareAttachment(from rawData: Data) throws -> PreparedPhotoAttachment {
        guard let image = UIImage(data: rawData) else {
            throw PhotoAttachmentError.invalidImage
        }

        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw PhotoAttachmentError.invalidImage
        }

        let longestEdge = max(pixelWidth, pixelHeight)
        let scaleFactor = longestEdge > maxLongestEdge ? (maxLongestEdge / longestEdge) : 1.0
        let targetSize = CGSize(
            width: max(1, (pixelWidth * scaleFactor).rounded()),
            height: max(1, (pixelHeight * scaleFactor).rounded())
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        if let pngData = rendered.pngData(), pngData.count <= maxPNGBytes {
            return PreparedPhotoAttachment(data: pngData, filename: "screenshot.png")
        }
        if let jpegData = rendered.jpegData(compressionQuality: 0.85) {
            return PreparedPhotoAttachment(data: jpegData, filename: "screenshot.jpg")
        }
        if let pngFallback = rendered.pngData() {
            return PreparedPhotoAttachment(data: pngFallback, filename: "screenshot.png")
        }
        throw PhotoAttachmentError.encodingFailed
    }
}
