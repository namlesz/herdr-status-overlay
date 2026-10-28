// Cuts the green-screen dog sheets in Art/dog into transparent mascot frames.
// Usage, from the repository root: swift scripts/prepare-corgi-assets.swift
// Retains the legacy Resources/Corgi directory and script name; the art is now the approved dog.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let cell = 512
let canvas = 256
let padding = 8
let output = URL(fileURLWithPath: "Sources/OverlayApp/Resources/Corgi")
let sheets = URL(fileURLWithPath: "Art/dog")

/// Each sequence shares a crop box so motion between its 2×2 cells survives the cut.
var groups: [(sheet: String, frames: [(name: String, column: Int, row: Int)])] = []
for activity in ["run", "sniff", "splash", "dig", "tug", "roll", "fetch", "blocked", "flip"] {
    let frames: [(name: String, column: Int, row: Int)] = (0..<4).map { index in
        let name = activity == "blocked" && index == 0 ? "blocked" : "\(activity)-\(index)"
        return (name, index % 2, index / 2)
    }
    groups.append((activity + "-sheet", frames))
}
groups += [
        ("states-sheet", [("sleeping", 0, 0)]),
        ("states-sheet", [("unavailable", 1, 0)]),
        ("states-sheet", [("celebrating", 0, 1)]),
        ("states-sheet", [("standing", 1, 1)]),
    ]

let pairGroups: [(sheet: String, frames: [(name: String, column: Int, row: Int)])] =
    ["chase", "tug", "fetch", "wrestle", "hop", "dig", "splash", "steal", "enter", "exit"].map { activity in
        ("pair-\(activity)-sheet", (0..<4).map { ("pair-\(activity)-\($0)", $0 % 2, $0 / 2) })
    }
struct Box {
    var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }
    mutating func add(_ x: Int, _ y: Int) {
        minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
    }
    mutating func add(_ other: Box) {
        add(other.minX, other.minY); add(other.maxX, other.maxY)
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func rgba(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return bytes
}

func load(_ name: String) -> CGImage {
    let url = sheets.appendingPathComponent(name + ".png")
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("cannot read \(url.path)") }
    guard image.width == cell * 2, image.height == cell * 2 else { fail("\(name) is not 1024×1024") }
    return image
}

/// Premultiplied RGBA cell with green keyed out (feathered) and green spill removed. Rows run top-down.
func key(_ sheet: [UInt8], column: Int, row: Int) -> (pixels: [UInt8], box: Box) {
    var pixels = [UInt8](repeating: 0, count: cell * cell * 4)
    var box = Box()
    for y in 0..<cell {
        for x in 0..<cell {
            let source = ((row * cell + y) * cell * 2 + column * cell + x) * 4
            let r = Int(sheet[source]), g = Int(sheet[source + 1]), b = Int(sheet[source + 2])
            let greenness = g - max(r, b)
            var alpha = 1 - Double(greenness - 12) / Double(70 - 12)
            alpha = min(1, max(0, alpha))
            // A few pixels at the cell edge are never part of the dog.
            if x < 4 || y < 4 || x >= cell - 4 || y >= cell - 4 { alpha = 0 }
            guard alpha > 0 else { continue }
            let despilled = min(g, max(r, b))
            let target = (y * cell + x) * 4
            pixels[target] = UInt8(Double(r) * alpha)
            pixels[target + 1] = UInt8(Double(despilled) * alpha)
            pixels[target + 2] = UInt8(Double(b) * alpha)
            pixels[target + 3] = UInt8(alpha * 255)
            if alpha > 0.125 { box.add(x, y) }
        }
    }
    return (pixels, box)
}

func image(_ pixels: [UInt8], width: Int, height: Int) -> CGImage {
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
}

func context(width: Int, height: Int) -> CGContext {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    return context
}

func write(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("cannot write \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("cannot write \(url.path)") }
}

// Key every cell first: one scale for all frames keeps the dog the same size in every mood.
let loaded = Dictionary(uniqueKeysWithValues: Set(groups.map(\.sheet)).map { ($0, rgba(load($0))) })
let keyed = groups.map { group in group.frames.map { key(loaded[group.sheet]!, column: $0.column, row: $0.row) } }
let unions = keyed.map { frames in frames.dropFirst().reduce(into: frames[0].box) { $0.add($1.box) } }
let largest = unions.map { max($0.width, $0.height) }.max()!
let scale = Double(canvas - padding * 2) / Double(largest)

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var frames: [(name: String, image: CGImage)] = []
for (index, group) in groups.enumerated() {
    let union = unions[index]
    // Bottom-aligned on a shared baseline, horizontally centred on the group's box.
    let drawnWidth = Double(cell) * scale
    let originX = Double(canvas) / 2 - (Double(union.minX) + Double(union.width) / 2) * scale
    let originY = Double(padding) - Double(cell - 1 - union.maxY) * scale
    for (frame, keyedCell) in zip(group.frames, keyed[index]) {
        let target = context(width: canvas, height: canvas)
        target.draw(image(keyedCell.pixels, width: cell, height: cell),
                    in: CGRect(x: originX, y: originY, width: drawnWidth, height: drawnWidth))
        let result = target.makeImage()!
        write(result, to: output.appendingPathComponent(frame.name + ".png"))
        frames.append((frame.name, result))
    }
}
// Pair scenes use their own shared scale; the legacy frame scale above stays byte-for-byte stable.
let pairLoaded = Dictionary(uniqueKeysWithValues: Set(pairGroups.map(\.sheet)).map { ($0, rgba(load($0))) })
let pairKeyed = pairGroups.map { group in group.frames.map { key(pairLoaded[group.sheet]!, column: $0.column, row: $0.row) } }
let pairUnions = pairKeyed.map { cells in cells.dropFirst().reduce(into: cells[0].box) { $0.add($1.box) } }
let pairLargest = pairUnions.map { max($0.width, $0.height) }.max()!
let pairScale = Double(canvas - padding * 2) / Double(pairLargest)
for (index, group) in pairGroups.enumerated() {
    let union = pairUnions[index]
    let drawnWidth = Double(cell) * pairScale
    let originX = Double(canvas) / 2 - (Double(union.minX) + Double(union.width) / 2) * pairScale
    let originY = Double(padding) - Double(cell - 1 - union.maxY) * pairScale
    for (frame, keyedCell) in zip(group.frames, pairKeyed[index]) {
        let target = context(width: canvas, height: canvas)
        target.draw(image(keyedCell.pixels, width: cell, height: cell),
                    in: CGRect(x: originX, y: originY, width: drawnWidth, height: drawnWidth))
        let result = target.makeImage()!
        write(result, to: output.appendingPathComponent(frame.name + ".png"))
        frames.append((frame.name, result))
    }
}


// Verification: alpha present, transparent perimeter, no visible green left.
for (name, frame) in frames {
    let bytes = rgba(frame)
    var perimeter = 0, green = 0, opaque = 0
    for y in 0..<canvas {
        for x in 0..<canvas {
            let i = (y * canvas + x) * 4
            let r = Int(bytes[i]), g = Int(bytes[i + 1]), b = Int(bytes[i + 2]), a = Int(bytes[i + 3])
            if a > 0 && (x == 0 || y == 0 || x == canvas - 1 || y == canvas - 1) { perimeter += 1 }
            if a > 128 { opaque += 1; if g - max(r, b) > 24 { green += 1 } }
        }
    }
    let ok = frame.alphaInfo != .none && perimeter == 0 && green == 0 && opaque > 0
    print("\(ok ? "ok  " : "FAIL") \(name).png \(canvas)×\(canvas) opaque=\(opaque) perimeter=\(perimeter) green=\(green)")
    if !ok { exit(1) }
}

// Review sheet: every frame on a dark and on a light background, to expose fringes.
let columns = 4, rows = (frames.count + columns - 1) / columns
let sheet = context(width: canvas * columns, height: canvas * rows * 2)
for (band, gray) in [(0, 0.20), (1, 0.92)] {
    sheet.setFillColor(CGColor(srgbRed: gray, green: gray + 0.02, blue: gray + 0.06, alpha: 1))
    sheet.fill(CGRect(x: 0, y: canvas * rows * (1 - band), width: canvas * columns, height: canvas * rows))
    for (index, frame) in frames.enumerated() {
        let x = index % columns * canvas
        let y = canvas * rows * (2 - band) - (index / columns + 1) * canvas
        sheet.draw(frame.image, in: CGRect(x: x, y: y, width: canvas, height: canvas))
    }
}
try FileManager.default.createDirectory(at: URL(fileURLWithPath: ".build"), withIntermediateDirectories: true)
write(sheet.makeImage()!, to: URL(fileURLWithPath: ".build/corgi-contact-sheet.png"))
print("scale \(String(format: "%.3f", scale)); contact sheet .build/corgi-contact-sheet.png")
