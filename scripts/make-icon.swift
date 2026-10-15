#!/usr/bin/env swift
// Genera el ícono de Loro: squircle con gradiente menta→teal y el loro del emoji 🦜 encima.
// Uso: swift scripts/make-icon.swift
import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("App/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func render(size: Int) -> NSImage {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError() }
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // Squircle al 82% del lienzo (macOS deja aire alrededor).
    let inset = s * 0.09
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.height * 0.225)
    ctx.saveGState()
    path.addClip()
    let gradient = NSGradient(starting: color(0xFFF6E5), ending: color(0xFFD08A))!
    gradient.draw(in: rect, angle: -90)
    ctx.restoreGState()

    // Sombra suave para que el loro "flote" sobre el fondo.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.02), blur: s * 0.05, color: NSColor.black.withAlphaComponent(0.28).cgColor)

    // El loro del emoji, centrado, ocupando ~68% del squircle.
    let font = NSFont(name: "AppleColorEmoji", size: rect.width * 0.68)!
    let attrs: [NSAttributedString.Key: Any] = [.font: font]
    let str = NSAttributedString(string: "🦜", attributes: attrs)
    let bounds = str.boundingRect(with: NSSize(width: s, height: s), options: [.usesLineFragmentOrigin])
    let origin = CGPoint(x: rect.midX - bounds.width / 2, y: rect.midY - bounds.height / 2 + rect.height * 0.01)
    str.draw(at: origin)
    ctx.restoreGState()
    img.unlockFocus()
    return img
}

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let master = render(size: 1024)
let sizes: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for (pt, scale) in sizes {
    let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
    try png(master, pixels: pt * scale).write(to: iconset.appendingPathComponent(name))
    images.append(["size": "\(pt)x\(pt)", "idiom": "mac", "filename": name, "scale": "\(scale)x"])
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: iconset.appendingPathComponent("Contents.json"))
try #"{"info":{"author":"xcode","version":1}}"#.data(using: .utf8)!.write(to: iconset.deletingLastPathComponent().appendingPathComponent("Contents.json"))
print("ícono generado en \(iconset.path)")
