//
//  ImageAttachment.swift
//  Agmente
//
//  Image attachment model for including images in prompts.
//

import Foundation
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

/// Represents an image attachment ready to be sent in a prompt.
struct ImageAttachment: Identifiable, Equatable {
    let id: UUID
    let image: PlatformImage
    let mimeType: String
    let base64Data: String

    /// Original file size in bytes (before compression).
    let originalSize: Int

    /// Compressed size in bytes (base64 encoded).
    var compressedSize: Int {
        base64Data.count
    }

    /// Human-readable size string.
    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(compressedSize), countStyle: .file)
    }

    /// Creates a thumbnail for preview display.
    func thumbnail(maxSize: CGFloat = 80) -> PlatformImage {
        ImageProcessor.resizedImage(image, maxDimension: maxSize)
    }

    static func == (lhs: ImageAttachment, rhs: ImageAttachment) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Image Processing

enum ImageProcessor {
    /// Maximum image dimension (width or height) before resizing.
    static let maxDimension: CGFloat = 1024

    /// JPEG compression quality for images.
    static let jpegQuality: CGFloat = 0.8

    /// Maximum number of attachments allowed per prompt.
    static let maxAttachments: Int = 5

    /// Creates an ImageAttachment from a platform image, with optional resizing and compression.
    /// - Parameters:
    ///   - image: The source image.
    ///   - resize: Whether to resize large images.
    /// - Returns: An ImageAttachment ready for sending, or nil if encoding fails.
    static func processImage(_ image: PlatformImage, resize: Bool = true) -> ImageAttachment? {
        let originalData = image.agmentePNGData() ?? image.agmenteJPEGData(compressionQuality: 1.0)
        let originalSize = originalData?.count ?? 0

        // Resize if needed
        let processedImage: PlatformImage
        if resize && (image.size.width > maxDimension || image.size.height > maxDimension) {
            processedImage = resizedImage(image, maxDimension: maxDimension)
        } else {
            processedImage = image
        }

        // Determine format and encode
        // Prefer JPEG for photos (smaller), PNG for images with transparency
        let (data, mimeType) = encodeImage(processedImage)

        guard let imageData = data else {
            return nil
        }

        let base64String = imageData.base64EncodedString()

        return ImageAttachment(
            id: UUID(),
            image: processedImage,
            mimeType: mimeType,
            base64Data: base64String,
            originalSize: originalSize
        )
    }

    /// Resizes an image to fit within the specified maximum dimension.
    static func resizedImage(_ image: PlatformImage, maxDimension: CGFloat) -> PlatformImage {
        let scale = min(maxDimension / image.size.width, maxDimension / image.size.height)
        guard scale < 1 else { return image }
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

#if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
#else
        let resized = NSImage(size: newSize)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1
        )
        resized.unlockFocus()
        return resized
#endif
    }

    /// Encodes an image to data with appropriate format detection.
    private static func encodeImage(_ image: PlatformImage) -> (Data?, String) {
        // Check if image has alpha channel (transparency)
        if hasAlphaChannel(image) {
            // Use PNG to preserve transparency
            return (image.agmentePNGData(), "image/png")
        } else {
            // Use JPEG for smaller file size
            return (image.agmenteJPEGData(compressionQuality: jpegQuality), "image/jpeg")
        }
    }

    /// Checks if an image has an alpha channel.
    private static func hasAlphaChannel(_ image: PlatformImage) -> Bool {
        guard let cgImage = image.agmenteCGImage() else { return false }
        let alphaInfo = cgImage.alphaInfo
        return alphaInfo == .first || alphaInfo == .last ||
               alphaInfo == .premultipliedFirst || alphaInfo == .premultipliedLast
    }
}

// MARK: - ChatMessage Image Storage

/// Lightweight image data for display in chat history (thumbnail only).
struct ChatImageData: Identifiable, Equatable {
    let id: UUID
    let thumbnail: PlatformImage
    let mimeType: String

    /// Creates a ChatImageData from an ImageAttachment (for storing in chat history).
    init(from attachment: ImageAttachment) {
        self.id = attachment.id
        self.thumbnail = attachment.thumbnail(maxSize: 200) // Larger thumbnail for chat display
        self.mimeType = attachment.mimeType
    }
    
    static func == (lhs: ChatImageData, rhs: ChatImageData) -> Bool {
        lhs.id == rhs.id
    }
}

private extension PlatformImage {
    func agmenteCGImage() -> CGImage? {
#if canImport(UIKit)
        return cgImage
#else
        var rect = NSRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
#endif
    }

    func agmentePNGData() -> Data? {
#if canImport(UIKit)
        return pngData()
#else
        guard let bitmap = agmenteBitmapRep() else { return nil }
        return bitmap.representation(using: .png, properties: [:])
#endif
    }

    func agmenteJPEGData(compressionQuality: CGFloat) -> Data? {
#if canImport(UIKit)
        return jpegData(compressionQuality: compressionQuality)
#else
        guard let bitmap = agmenteBitmapRep() else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
#endif
    }

#if canImport(AppKit)
    private func agmenteBitmapRep() -> NSBitmapImageRep? {
        if let tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiffRepresentation) {
            return bitmap
        }
        guard let cgImage = agmenteCGImage() else { return nil }
        return NSBitmapImageRep(cgImage: cgImage)
    }
#endif
}
