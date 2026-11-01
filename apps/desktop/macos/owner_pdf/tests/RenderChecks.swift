import Foundation
import CoreGraphics
import ImageIO
import CoreText

@main struct RenderChecks {
  static func require(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
  }
  static func refused(_ code: String, _ action: () throws -> Void) {
    do { try action(); fatalError("Expected refusal: \(code)") }
    catch let failure as OwnerPdfPreview.Failure { require(failure.code == code, "Wrong PDF failure") }
    catch { fatalError("Unclassified failure") }
  }
  static func document(locked: Bool = false, pages: Int = 2) -> Data {
    let bytes = NSMutableData()
    let consumer = CGDataConsumer(data: bytes)!
    var box = CGRect(x: 0, y: 0, width: 200, height: 100)
    let options: [CFString: Any] = locked ? [kCGPDFContextUserPassword: "synthetic-password",
      kCGPDFContextOwnerPassword: "synthetic-owner", kCGPDFContextEncryptionKeyLength: 128] : [:]
    let context = CGContext(consumer: consumer, mediaBox: &box, options as CFDictionary)!
    for index in 0..<pages {
      let rgb: [CGFloat] = index % 2 == 0 ? [1,0,0] : [0,0,1]
      context.beginPDFPage(nil)
      context.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: rgb + [1])!)
      context.fill(box)
      let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Synthetic PDF page \(index + 1)",
        attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 12, nil),
                     NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]))
      context.textPosition = CGPoint(x: 10, y: 45); CTLineDraw(line, context)
      // Drawing does not follow this annotation URL or invoke an external viewer.
      context.setURL(URL(string: "https://invalid.example/synthetic-only")! as CFURL, for: box)
      context.endPDFPage()
    }
    context.closePDF()
    return bytes as Data
  }
  static func customPage(_ attributes: String) -> Data {
    let objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Contents 4 0 R \(attributes) >>",
      "<< /Length 24 >>\nstream\n0 1 0 rg 0 0 200 100 re f\nendstream"]
    var text = "%PDF-1.4\n", offsets = [0]
    for (index, object) in objects.enumerated() {
      offsets.append(text.utf8.count); text += "\(index+1) 0 obj\n\(object)\nendobj\n"
    }
    let xref = text.utf8.count
    text += "xref\n0 5\n0000000000 65535 f \n"
    for offset in offsets.dropFirst() { text += String(format: "%010d 00000 n \n", offset) }
    text += "trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
    return Data(text.utf8)
  }
  static func pixel(_ data: Data) -> [UInt8] {
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    var rgba = [UInt8](repeating: 0, count: 4)
    rgba.withUnsafeMutableBytes { pointer in
      let context = CGContext(data: pointer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return rgba
  }
  static func main() throws {
    let pdf = document()
    let first = try OwnerPdfPreview.render(pdf, page: 0), second = try OwnerPdfPreview.render(pdf, page: 1)
    require(first.pageCount == 2 && first.page == 0 && second.page == 1, "Exact page identity")
    require(first.width == 400 && first.height == 200, "Bounded scale")
    let red = pixel(first.png), blue = pixel(second.png)
    if CommandLine.arguments.count == 2 {
      let out = URL(fileURLWithPath: CommandLine.arguments[1])
      try first.png.write(to: out.appendingPathComponent("page-1.png"))
      try second.png.write(to: out.appendingPathComponent("page-2.png"))
    }
    FileHandle.standardError.write(Data("Pixel probes: \(red), \(blue)\n".utf8))
    require(red[0] > 240 && red[2] < 15 && blue[0] < 15 && blue[2] > 240, "Actual page pixels")
    refused("invalid_request") { _ = try OwnerPdfPreview.render(pdf, page: -1) }
    refused("invalid_request") { _ = try OwnerPdfPreview.render(pdf, page: 2) }
    refused("invalid_pdf") { _ = try OwnerPdfPreview.render(Data([0,255,7]), page: 0) }
    refused("invalid_pdf") { _ = try OwnerPdfPreview.render(Data(), page: 0) }
    refused("invalid_pdf") { _ = try OwnerPdfPreview.render(Data(repeating: 0, count: OwnerPdfPreview.byteLimit + 1), page: 0) }
    let locked = document(locked: true)
    require(CGPDFDocument(CGDataProvider(data: locked as CFData)!)!.isEncrypted, "Encrypted fixture")
    refused("pdf_locked") { _ = try OwnerPdfPreview.render(locked, page: 0) }
    refused("pdf_unsupported") { _ = try OwnerPdfPreview.render(document(pages: OwnerPdfPreview.pageLimit + 1), page: 0) }
    let rotated = try OwnerPdfPreview.render(customPage("/Rotate 90"), page: 0)
    require(rotated.width == 200 && rotated.height == 400, "Rotation changes aspect")
    let cropped = try OwnerPdfPreview.render(customPage("/CropBox [50 20 150 70]"), page: 0)
    require(cropped.width == 200 && cropped.height == 100, "Crop box respected")
    let large = try OwnerPdfPreview.render(customPage("/MediaBox [0 0 10000 5000]"), page: 0)
    require(large.width == 1600 && large.height == 800, "Large page bounded before bitmap")
    refused("pdf_unsupported") { _ = try OwnerPdfPreview.render(customPage("/MediaBox [0 0 100001 100]"), page: 0) }
    if CommandLine.arguments.count == 2 {
      let out = URL(fileURLWithPath: CommandLine.arguments[1])
      try first.png.write(to: out.appendingPathComponent("page-1.png"))
      try second.png.write(to: out.appendingPathComponent("page-2.png"))
      try rotated.png.write(to: out.appendingPathComponent("rotated.png"))
      try cropped.png.write(to: out.appendingPathComponent("cropped.png"))
    }
    print("PASS: actual two-page pixels; exact page identity; invalid/corrupt/empty/oversize/encrypted refusals; rotation/crop; bounded dimensions; annotation drawn without viewer")
  }
}
