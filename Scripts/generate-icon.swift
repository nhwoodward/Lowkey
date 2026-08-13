#!/usr/bin/env swift
import AppKit

let master = 1024
let image = NSImage(size: NSSize(width: master, height: master))
image.lockFocus()

let bounds = NSRect(x: 0, y: 0, width: master, height: master)
NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
bounds.fill()

let bars: [CGFloat] = [0.26, 0.46, 0.74, 1.0, 0.62, 0.40, 0.30]
let count = CGFloat(bars.count)
let area = bounds.insetBy(dx: 236, dy: 248)
let gap: CGFloat = 28
let barW = (area.width - gap * (count - 1)) / count
NSColor.white.withAlphaComponent(0.92).setFill()
for (index, raw) in bars.enumerated() {
    let h = max(36, area.height * raw)
    let x = area.minX + CGFloat(index) * (barW + gap)
    let y = area.midY - h / 2
    let path = NSBezierPath(
        roundedRect: NSRect(x: x, y: y, width: barW, height: h),
        xRadius: barW / 2,
        yRadius: barW / 2
    )
    path.fill()
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("failed to encode icon\n", stderr)
    exit(1)
}

let root = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let masterURL = root.appendingPathComponent("AppIcon-1024.png")
try png.write(to: masterURL)

let set = root.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

let sizes = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for (size, name) in sizes {
    let dest = set.appendingPathComponent(name)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    process.arguments = ["-z", "\(size)", "\(size)", masterURL.path, "--out", dest.path]
    try process.run()
    process.waitUntilExit()
}

let icns = root.appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", set.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fputs("iconutil failed\n", stderr)
    exit(1)
}

print(icns.path)
