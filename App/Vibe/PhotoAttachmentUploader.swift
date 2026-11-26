import Foundation
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import SSHKit
import Store

/// Errors raised while preparing or uploading an attached image over SFTP.
enum PhotoAttachmentError: LocalizedError, Sendable, Equatable {
    case notSSHConnection
    case loadFailed
    case fileTooLarge
    case invalidImage
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .notSSHConnection:
            "An active SSH session is required to upload attachments."
        case .loadFailed:
            "Could not load the selected photo."
        case .fileTooLarge:
            "The selected photo exceeds the 50 MB size limit."
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
    static let maxRawBytes = 50 * 1024 * 1024

    /// Loads `item`, resizes/encodes it off the main thread, uploads via SFTP, and returns the remote POSIX path.
    static func upload(item: PhotosPickerItem, session: any Session) async throws -> String {
        guard let sshConnection = session as? SSHConnection else {
            throw PhotoAttachmentError.notSSHConnection
        }
        guard let rawData = try await item.loadTransferable(type: Data.self) else {
            throw PhotoAttachmentError.loadFailed
        }
        guard rawData.count <= maxRawBytes else {
            throw PhotoAttachmentError.fileTooLarge
        }

        let prepared = try await Task.detached(priority: .userInitiated) {
            try prepareAttachment(from: rawData)
        }.value

        let remotePath = RemoteAttachmentHelper.remotePath(filename: prepared.filename)
        try await sshConnection.sftpUploadFile(
            data: prepared.data,
            remotePath: remotePath,
            permissions: 0o600,
            exclusive: true
        )
        return remotePath
    }

    /// Downscales `rawData` to at most `maxLongestEdge` px via ImageIO without EXIF and encodes as PNG (falling back to JPEG if > 2 MB).
    nonisolated static func prepareAttachment(from rawData: Data) throws -> PreparedPhotoAttachment {
        guard !rawData.isEmpty else {
            throw PhotoAttachmentError.invalidImage
        }
        guard rawData.count <= maxRawBytes else {
            throw PhotoAttachmentError.fileTooLarge
        }

        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
        ]
        guard let imageSource = CGImageSourceCreateWithData(rawData as CFData, sourceOptions as CFDictionary) else {
            throw PhotoAttachmentError.invalidImage
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxLongestEdge),
            kCGImageSourceShouldCache: false,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary),
              cgImage.width > 0,
              cgImage.height > 0 else {
            throw PhotoAttachmentError.invalidImage
        }

        let targetSize = CGSize(width: cgImage.width, height: cgImage.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let rendered = renderer.image { _ in
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: targetSize))
        }

        let pngData = rendered.pngData()
        if let pngData, pngData.count <= maxPNGBytes {
            return PreparedPhotoAttachment(data: pngData, filename: "screenshot.png")
        }
        if let jpegData = rendered.jpegData(compressionQuality: 0.85) {
            return PreparedPhotoAttachment(data: jpegData, filename: "screenshot.jpg")
        }
        if let pngData {
            return PreparedPhotoAttachment(data: pngData, filename: "screenshot.png")
        }
        throw PhotoAttachmentError.encodingFailed
    }
}
