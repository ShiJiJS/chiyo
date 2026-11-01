import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct OwnerPdfPage {
  let png: Data
  let width: Int, height: Int, page: Int, pageCount: Int
}

/// Pixels only, from already verified Owner bytes. No URLs, PDF actions,
/// external viewers, JavaScript, temporary originals, or document cache.
enum OwnerPdfPreview {
  enum Failure: Error {
    case invalidPage, invalidDocument, locked, unsupported, renderFailed
    var code: String {
      switch self {
      case .invalidPage: return "invalid_request"
      case .invalidDocument: return "invalid_pdf"
      case .locked: return "pdf_locked"
      case .unsupported: return "pdf_unsupported"
      case .renderFailed: return "preview_unavailable"
      }
    }
  }
  static let byteLimit = 10 * 1024 * 1024
  static let edgeLimit = 1600
  static let pageLimit = 4096

  static func render(_ bytes: Data, page index: Int) throws -> OwnerPdfPage {
    guard index >= 0 else { throw Failure.invalidPage }
    guard !bytes.isEmpty, bytes.count <= byteLimit,
          let provider = CGDataProvider(data: bytes as CFData),
          let document = CGPDFDocument(provider) else { throw Failure.invalidDocument }
    guard !document.isEncrypted || document.isUnlocked else { throw Failure.locked }
    let count = document.numberOfPages
    guard count > 0, count <= pageLimit else { throw Failure.unsupported }
    guard index < count, let page = document.page(at: index + 1) else { throw Failure.invalidPage }
    let box = page.getBoxRect(.cropBox)
    guard box.origin.x.isFinite, box.origin.y.isFinite,
          box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0,
          box.width <= 100000, box.height <= 100000 else { throw Failure.unsupported }
    let rotated = abs(page.rotationAngle % 180) == 90
    let sourceWidth = rotated ? box.height : box.width
    let sourceHeight = rotated ? box.width : box.height
    let scale = min(2, CGFloat(edgeLimit) / max(sourceWidth, sourceHeight))
    let width = max(1, min(edgeLimit, Int(ceil(sourceWidth * scale))))
    let height = max(1, min(edgeLimit, Int(ceil(sourceHeight * scale))))
    guard let context = CGContext(data: nil, width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.renderFailed }
    let target = CGRect(x: 0, y: 0, width: width, height: height)
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(target)
    // CGPDFPageGetDrawingTransform only scales DOWN. Apply raster density
    // separately or small pages would occupy only the center of a 2x bitmap.
    context.scaleBy(x: scale, y: scale)
    let points = CGRect(x: 0, y: 0, width: CGFloat(width) / scale, height: CGFloat(height) / scale)
    context.concatenate(page.getDrawingTransform(.cropBox, rect: points, rotate: 0, preserveAspectRatio: true))
    context.drawPDFPage(page)
    guard let image = context.makeImage() else { throw Failure.renderFailed }
    let png = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
      throw Failure.renderFailed
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination), png.length > 0,
          png.length <= 12 * 1024 * 1024 else { throw Failure.renderFailed }
    return OwnerPdfPage(png: png as Data, width: width, height: height, page: index, pageCount: count)
  }
}
