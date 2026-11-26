import Foundation
import ImageIO
import SafariServices
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import TermApp

final class ReviewFixesTests: XCTestCase {
    // MARK: - CloudflareDNSFormatter.tunnelWebURL

    func testTunnelWebURLAcceptsValidHostnamesAndHTTPURLs() {
        XCTAssertEqual(
            CloudflareDNSFormatter.tunnelWebURL(hostname: "app.example.com", path: nil)?.absoluteString,
            "https://app.example.com"
        )
        XCTAssertEqual(
            CloudflareDNSFormatter.tunnelWebURL(hostname: "https://app.example.com", path: "/api/*")?.absoluteString,
            "https://app.example.com/api/"
        )
        XCTAssertEqual(
            CloudflareDNSFormatter.tunnelWebURL(hostname: "http://internal.example.com", path: "health")?.absoluteString,
            "http://internal.example.com/health"
        )
        XCTAssertEqual(
            CloudflareDNSFormatter.tunnelWebURL(hostname: "HTTPS://upper.example.com", path: nil)?.absoluteString,
            "HTTPS://upper.example.com"
        )
        XCTAssertEqual(
            CloudflareDNSFormatter.tunnelWebURL(hostname: "app.example.com:8443", path: nil)?.absoluteString,
            "https://app.example.com:8443"
        )
    }

    func testTunnelWebURLRejectsUnsafeSchemesAndInvalidHostnames() {
        let rejected = [
            "",
            "   ",
            "*.example.com",
            "file:///etc/passwd",
            "file://localhost/etc/passwd",
            "tel://+15551234567",
            "tel:15551234567",
            "javascript:alert(1)",
            "javascript://alert(1)",
            "mailto:user@example.com",
            "data:text/html,<script>alert(1)</script>",
            "custom://app/path",
            "custom:opaque",
            "https://",
            "http://",
            "https:///missing-host",
        ]
        for host in rejected {
            XCTAssertNil(
                CloudflareDNSFormatter.tunnelWebURL(hostname: host, path: nil),
                "Expected nil for unsafe/invalid hostname: \(host)"
            )
        }
    }

    // MARK: - InAppSafariView

    @MainActor
    func testInAppSafariViewValidatesSchemesWithoutCrashing() throws {
        let validHTTP = try XCTUnwrap(URL(string: "http://127.0.0.1:3000"))
        let validHTTPS = try XCTUnwrap(URL(string: "https://example.com"))
        XCTAssertTrue(InAppSafariView.isSupportedURL(validHTTP))
        XCTAssertTrue(InAppSafariView.isSupportedURL(validHTTPS))
        XCTAssertTrue(InAppSafariView.makeViewController(for: validHTTP) is SFSafariViewController)
        XCTAssertTrue(InAppSafariView.makeViewController(for: validHTTPS) is SFSafariViewController)

        let unsafeURLs = try [
            XCTUnwrap(URL(string: "file:///etc/passwd")),
            XCTUnwrap(URL(string: "tel://12345")),
            XCTUnwrap(URL(string: "javascript:alert(1)")),
            XCTUnwrap(URL(string: "custom://open")),
            XCTUnwrap(URL(string: "https:///no-host")),
        ]
        for url in unsafeURLs {
            XCTAssertFalse(InAppSafariView.isSupportedURL(url))
            let vc = InAppSafariView.makeViewController(for: url)
            XCTAssertFalse(vc is SFSafariViewController, "Must return fallback VC instead of SFSafariViewController for \(url)")
        }
    }

    // MARK: - PhotoAttachmentUploader

    func testPrepareAttachmentRejectsEmptyAndInvalidData() {
        XCTAssertThrowsError(try PhotoAttachmentUploader.prepareAttachment(from: Data())) { error in
            XCTAssertEqual(error as? PhotoAttachmentError, .invalidImage)
        }
        XCTAssertThrowsError(try PhotoAttachmentUploader.prepareAttachment(from: Data("not-an-image".utf8))) { error in
            XCTAssertEqual(error as? PhotoAttachmentError, .invalidImage)
        }
    }

    func testPrepareAttachmentEnforcesMaxRawBytesLimit() {
        let oversized = Data(count: PhotoAttachmentUploader.maxRawBytes + 1)
        XCTAssertThrowsError(try PhotoAttachmentUploader.prepareAttachment(from: oversized)) { error in
            XCTAssertEqual(error as? PhotoAttachmentError, .fileTooLarge)
        }
    }

    func testPrepareAttachmentDownscalesLargeImageAndPreservesSmallImage() throws {
        let largePNG = try makeSolidPNGData(width: 4096, height: 2048)
        let downscaled = try PhotoAttachmentUploader.prepareAttachment(from: largePNG)
        let downscaledSize = try decodedPixelSize(from: downscaled.data)
        XCTAssertEqual(downscaledSize.width, 2048)
        XCTAssertEqual(downscaledSize.height, 1024)

        let smallPNG = try makeSolidPNGData(width: 320, height: 240)
        let preserved = try PhotoAttachmentUploader.prepareAttachment(from: smallPNG)
        let preservedSize = try decodedPixelSize(from: preserved.data)
        XCTAssertEqual(preservedSize.width, 320)
        XCTAssertEqual(preservedSize.height, 240)
    }

    func testPrepareAttachmentAppliesOrientationTransformAndStripsEXIF() throws {
        let orientedJPEG = try makeOrientedJPEGWithoutTransform(width: 200, height: 100, orientation: 6)
        let prepared = try PhotoAttachmentUploader.prepareAttachment(from: orientedJPEG)
        let preparedSize = try decodedPixelSize(from: prepared.data)

        // Orientation 6 (90 deg CW) swaps width and height when applied.
        XCTAssertEqual(preparedSize.width, 100)
        XCTAssertEqual(preparedSize.height, 200)

        let source = try XCTUnwrap(CGImageSourceCreateWithData(prepared.data as CFData, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let exif = props?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifUserComment])
        XCTAssertNil(props?[kCGImagePropertyGPSDictionary])
        let orientation = props?[kCGImagePropertyOrientation] as? Int
        XCTAssertTrue(orientation == nil || orientation == 1)
    }

    // MARK: - AgentAuthHelper & AgentNotificationManager

    func testAgentAuthHelperRejectsUnsupportedAndInteractiveMethods() {
        let interactiveTarget = AgentHostTarget(
            label: "2FA Box",
            hostname: "example.com",
            authMethod: "keyboardInteractive"
        )
        XCTAssertThrowsError(try AgentAuthHelper.buildAuth(for: interactiveTarget)) { error in
            guard case AgentRemoteError.needsInteractiveAuth = error else {
                return XCTFail("Expected needsInteractiveAuth, got \(error)")
            }
        }

        let unsupportedTarget = AgentHostTarget(
            label: "Weird Box",
            hostname: "example.com",
            authMethod: "custom-unknown"
        )
        XCTAssertThrowsError(try AgentAuthHelper.buildAuth(for: unsupportedTarget)) { error in
            guard case AgentRemoteError.needsInteractiveAuth = error else {
                return XCTFail("Expected needsInteractiveAuth, got \(error)")
            }
        }
    }

    func testAgentNotificationManagerRequestPrefix() {
        XCTAssertEqual(AgentNotificationManager.requestIdentifierPrefix, "termapp.agent.")
    }

    // MARK: - Helpers

    private func makeSolidPNGData(width: Int, height: Int) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try XCTUnwrap(image.pngData())
    }

    private func makeOrientedJPEGWithoutTransform(width: Int, height: Int, orientation: Int) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            UIColor.systemOrange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let mutableData = NSMutableData()
        let dest = try XCTUnwrap(
            CGImageDestinationCreateWithData(mutableData, UTType.jpeg.identifier as CFString, 1, nil)
        )
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "secret-exif"],
        ]
        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return mutableData as Data
    }

    private func decodedPixelSize(from data: Data) throws -> (width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try XCTUnwrap(props[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(props[kCGImagePropertyPixelHeight] as? Int)
        return (width, height)
    }
}
