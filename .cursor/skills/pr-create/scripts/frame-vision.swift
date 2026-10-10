// frame-vision.swift: local text and barcode reading plus hatch drawing for
// evidence frames. macOS Vision and CoreGraphics only: no network, no install.
//
// evidence-privacy.sh compiles this on first use and owns every decision about
// what a frame's text means; this file only reads pixels and draws boxes.
//
//   frame-vision ocr <image>...
//       One JSON object per line, in argument order:
//       { file, width, height, passes: [{ correction, lines: [{ text, box,
//         words: [{ text, box }] }] }], barcodes: [{ payload, box }] }
//       or { file, error } when the image cannot be read. Boxes are
//       [x, y, w, h] in pixels from the top-left corner. Two passes are run,
//       language correction off and on: correction repairs dictionary words
//       and mangles key material, so neither pass alone reads both.
//
//   frame-vision hatch <in> <out> <x,y,w,h>...
//       Writes a PNG copy of <in> with each box covered by an opaque hatched
//       panel. <in> is never written to.
//
//   frame-vision render <out> <width> <height> [<x,y,size,text>...]
//       Draws white text on a dark canvas. Tests use it to synthesize frames,
//       so no fixture image has to be committed.
//
// Exit codes: 0 ok, 1 bad usage or unwritable output. An unreadable input in
// `ocr` is reported on that file's line and does not change the exit code, so
// one bad file never hides the results for the rest of a batch.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

func fail(_ msg: String) -> Never {
  FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
  exit(1)
}

func loadImage(_ path: String) -> CGImage? {
  guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
  return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func writePNG(_ image: CGImage, _ path: String) -> Bool {
  let url = URL(fileURLWithPath: path) as CFURL
  guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else { return false }
  CGImageDestinationAddImage(dest, image, nil)
  return CGImageDestinationFinalize(dest)
}

// Vision boxes are normalized with a bottom-left origin.
func pixelBox(_ r: CGRect, _ w: Int, _ h: Int) -> [Int] {
  let x = r.minX * CGFloat(w)
  let y = (1 - r.maxY) * CGFloat(h)
  return [Int(x.rounded(.down)), Int(y.rounded(.down)), Int((r.width * CGFloat(w)).rounded(.up)), Int((r.height * CGFloat(h)).rounded(.up))]
}

func recognize(_ image: CGImage, correction: Bool) throws -> [[String: Any]] {
  let request = VNRecognizeTextRequest()
  request.recognitionLevel = .accurate
  request.usesLanguageCorrection = correction
  request.recognitionLanguages = ["en-US"]
  request.minimumTextHeight = 0
  try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
  var lines: [[String: Any]] = []
  for obs in request.results ?? [] {
    guard let top = obs.topCandidates(1).first else { continue }
    let text = top.string
    var words: [[String: Any]] = []
    var idx = text.startIndex
    while idx < text.endIndex {
      while idx < text.endIndex, text[idx].isWhitespace { idx = text.index(after: idx) }
      var end = idx
      while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
      if idx < end {
        let box = (try? top.boundingBox(for: idx..<end))??.boundingBox ?? obs.boundingBox
        words.append(["text": String(text[idx..<end]), "box": pixelBox(box, image.width, image.height)])
      }
      idx = end
    }
    lines.append(["text": text, "box": pixelBox(obs.boundingBox, image.width, image.height), "words": words])
  }
  return lines
}

func barcodes(_ image: CGImage) throws -> [[String: Any]] {
  let request = VNDetectBarcodesRequest()
  try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
  var out: [[String: Any]] = []
  for obs in request.results ?? [] {
    guard let payload = obs.payloadStringValue else { continue }
    out.append(["payload": payload, "box": pixelBox(obs.boundingBox, image.width, image.height)])
  }
  return out
}

func emit(_ obj: [String: Any]) {
  let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

func ocr(_ files: [String]) {
  for file in files {
    autoreleasepool {
      guard let image = loadImage(file) else { emit(["file": file, "error": "unreadable image"]); return }
      do {
        let off = try recognize(image, correction: false)
        let on = try recognize(image, correction: true)
        emit([
          "file": file, "width": image.width, "height": image.height,
          "passes": [["correction": false, "lines": off], ["correction": true, "lines": on]],
          "barcodes": try barcodes(image)
        ])
      } catch {
        emit(["file": file, "error": "vision failed: \(error.localizedDescription)"])
      }
    }
  }
}

func canvas(_ w: Int, _ h: Int) -> CGContext {
  guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("cannot create a \(w)x\(h) canvas") }
  return ctx
}

func parseBox(_ s: String) -> [Int] {
  let p = s.split(separator: ",").compactMap { Int($0) }
  guard p.count == 4, p[2] > 0, p[3] > 0 else { fail("bad box '\(s)': want x,y,w,h in pixels") }
  return p
}

func hatch(_ args: [String]) {
  guard args.count >= 3 else { fail("usage: frame-vision hatch <in> <out> <x,y,w,h>...") }
  guard let image = loadImage(args[0]) else { fail("unreadable image: \(args[0])") }
  let w = image.width, h = image.height
  let ctx = canvas(w, h)
  ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
  let stroke = max(1, CGFloat(w) / 480)
  for spec in args[2...] {
    let b = parseBox(spec)
    // CoreGraphics draws from the bottom-left corner.
    let rect = CGRect(x: b[0], y: h - b[1] - b[3], width: b[2], height: b[3]).intersection(CGRect(x: 0, y: 0, width: w, height: h))
    if rect.isEmpty { continue }
    ctx.saveGState()
    ctx.setFillColor(CGColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1))
    ctx.fill(rect)
    ctx.clip(to: rect)
    ctx.setStrokeColor(CGColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1))
    ctx.setLineWidth(stroke)
    let step = max(8, CGFloat(w) / 36)
    var offset = -rect.height
    while offset < rect.width {
      ctx.move(to: CGPoint(x: rect.minX + offset, y: rect.minY))
      ctx.addLine(to: CGPoint(x: rect.minX + offset + rect.height, y: rect.maxY))
      offset += step
    }
    ctx.strokePath()
    ctx.restoreGState()
    ctx.setStrokeColor(CGColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1))
    ctx.setLineWidth(stroke * 2)
    ctx.stroke(rect.insetBy(dx: stroke, dy: stroke))
  }
  guard let out = ctx.makeImage(), writePNG(out, args[1]) else { fail("cannot write \(args[1])") }
}

func render(_ args: [String]) {
  guard args.count >= 3, let w = Int(args[1]), let h = Int(args[2]) else { fail("usage: frame-vision render <out> <width> <height> [<x,y,size,text>...]") }
  let ctx = canvas(w, h)
  ctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
  NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
  for spec in args[3...] {
    let parts = spec.split(separator: ",", maxSplits: 3, omittingEmptySubsequences: false)
    guard parts.count == 4, let x = Double(parts[0]), let y = Double(parts[1]), let size = Double(parts[2]) else { fail("bad text spec '\(spec)': want x,y,size,text") }
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.white]
    let text = NSAttributedString(string: String(parts[3]), attributes: attrs)
    // y names the top of the line, measured from the top of the canvas.
    text.draw(at: CGPoint(x: x, y: Double(h) - y - Double(text.size().height)))
  }
  guard let out = ctx.makeImage(), writePNG(out, args[0]) else { fail("cannot write \(args[0])") }
}

let argv = Array(CommandLine.arguments.dropFirst())
switch argv.first {
case "ocr": ocr(Array(argv.dropFirst()))
case "hatch": hatch(Array(argv.dropFirst()))
case "render": render(Array(argv.dropFirst()))
default: fail("usage: frame-vision ocr|hatch|render ...")
}
