#!/usr/bin/env swift
// Generates resources/AppIcon.icns: a black squircle with a pink dot in the center.
// Drawn via AppKit at every required iconset size, then packaged with iconutil.

import AppKit
import Foundation

let iconRoot = "resources"
let iconsetDir = "\(iconRoot)/AppIcon.iconset"
let icnsPath = "\(iconRoot)/AppIcon.icns"

// Sizes Apple's iconset requires: filename → pixel size.
let sizes: [(String, Int)] = [
    ("icon_16x16.png",        16),
    ("icon_16x16@2x.png",     32),
    ("icon_32x32.png",        32),
    ("icon_32x32@2x.png",     64),
    ("icon_128x128.png",     128),
    ("icon_128x128@2x.png",  256),
    ("icon_256x256.png",     256),
    ("icon_256x256@2x.png",  512),
    ("icon_512x512.png",     512),
    ("icon_512x512@2x.png", 1024),
]

let fm = FileManager.default
try? fm.removeItem(atPath: iconsetDir)
try fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

func drawIcon(size: Int) -> Data {
    let pxSize = CGFloat(size)
    // Allocate a bitmap and bind a CG graphics context to it so we can draw
    // without needing an NSWindow / lockFocus (which fails in CLI tools).
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        FileHandle.standardError.write("Failed to allocate bitmap\n".data(using: .utf8)!)
        exit(1)
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Transparent backdrop.
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: pxSize, height: pxSize).fill()

    // Squircle: rounded rect with iOS-style continuous curvature. macOS apps
    // typically use ~22% corner radius relative to the icon side and inset
    // ~10% to leave Apple's standard padding around the artwork.
    let inset = pxSize * 0.10
    let body = NSRect(x: inset, y: inset, width: pxSize - 2 * inset, height: pxSize - 2 * inset)
    let cornerRadius = body.width * 0.22

    NSColor.black.setFill()
    NSBezierPath(roundedRect: body, xRadius: cornerRadius, yRadius: cornerRadius).fill()

    // Pink dot: ~30% of the squircle's width, centered.
    let dotDiameter = body.width * 0.30
    let dotRect = NSRect(
        x: body.midX - dotDiameter / 2,
        y: body.midY - dotDiameter / 2,
        width: dotDiameter,
        height: dotDiameter
    )
    NSColor.systemPink.setFill()
    NSBezierPath(ovalIn: dotRect).fill()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("Failed to encode PNG\n".data(using: .utf8)!)
        exit(1)
    }
    return png
}

for (name, px) in sizes {
    let data = drawIcon(size: px)
    let path = "\(iconsetDir)/\(name)"
    try data.write(to: URL(fileURLWithPath: path))
    print("  wrote \(path) (\(px)x\(px))")
}

// iconutil packages the .iconset into a single .icns file.
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", "-o", icnsPath, iconsetDir]
try task.run()
task.waitUntilExit()
if task.terminationStatus == 0 {
    print("Wrote \(icnsPath)")
} else {
    FileHandle.standardError.write("iconutil failed with status \(task.terminationStatus)\n".data(using: .utf8)!)
    exit(2)
}
