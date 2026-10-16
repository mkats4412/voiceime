import AppKit
import CoreGraphics

func createIconImage(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let scale = size / 1024.0

    // 1. 背景のドロップシャドウ付き角丸長方形 (Squircle)
    let margin: CGFloat = 100.0 * scale
    let cornerRadius: CGFloat = 185.0 * scale
    let rectSize: CGFloat = 824.0 * scale
    let bgRect = CGRect(x: margin, y: margin, width: rectSize, height: rectSize)

    // 外側のソフトドロップシャドウ
    ctx.saveGState()
    let shadowColor = NSColor.black.withAlphaComponent(0.35).cgColor
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 28 * scale, color: shadowColor)
    let clipPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(clipPath)
    ctx.setFillColor(NSColor(red: 0.12, green: 0.15, blue: 0.28, alpha: 1.0).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // 2. メイングラーデーション背景
    ctx.saveGState()
    ctx.addPath(clipPath)
    ctx.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    // 鮮やかで洗練されたロイヤルブルー〜ディープバイオレットのグラデーション
    let gradColors = [
        NSColor(red: 0.18, green: 0.48, blue: 0.98, alpha: 1.0).cgColor, // Top: #2E7BFA
        NSColor(red: 0.38, green: 0.22, blue: 0.88, alpha: 1.0).cgColor, // Mid: #6138E0
        NSColor(red: 0.48, green: 0.16, blue: 0.82, alpha: 1.0).cgColor  // Bottom: #7B29D2
    ] as CFArray
    let gradLocations: [CGFloat] = [0.0, 0.6, 1.0]
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradColors, locations: gradLocations) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: size / 2, y: bgRect.maxY),
            end: CGPoint(x: size / 2, y: bgRect.minY),
            options: []
        )
    }

    // 上部からのソフトなハイライト光
    if let highlightGrad = CGGradient(
        colorsSpace: colorSpace,
        colors: [NSColor.white.withAlphaComponent(0.25).cgColor, NSColor.white.withAlphaComponent(0.0).cgColor] as CFArray,
        locations: [0.0, 1.0]
    ) {
        ctx.drawLinearGradient(
            highlightGrad,
            start: CGPoint(x: size / 2, y: bgRect.maxY),
            end: CGPoint(x: size / 2, y: bgRect.midY),
            options: []
        )
    }

    // 微細なインナーボーダー
    ctx.setLineWidth(2.0 * scale)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
    ctx.addPath(clipPath)
    ctx.strokePath()

    ctx.restoreGState()

    // 3. マイクアイコンとオーディオウェーブの描画
    ctx.saveGState()
    let centerX = size / 2.0
    let centerY = size / 2.0 + 8.0 * scale

    // シンボルのドロップシャドウ
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 12 * scale, color: NSColor.black.withAlphaComponent(0.28).cgColor)

    // A. サウンドウェーブ（左右の音波バー）
    let waveColor = NSColor.white.withAlphaComponent(0.85).cgColor
    ctx.setFillColor(waveColor)

    // 左側の3本の音波バー
    let barWidth = 18.0 * scale
    let waveSpacings: [CGFloat] = [170.0, 215.0, 260.0]
    let waveHeights: [CGFloat] = [130.0, 190.0, 110.0]

    for (i, dist) in waveSpacings.enumerated() {
        let h = waveHeights[i] * scale
        let w = barWidth
        let leftX = centerX - dist * scale - w / 2
        let rightX = centerX + dist * scale - w / 2
        let barY = centerY - h / 2

        let leftBar = CGPath(roundedRect: CGRect(x: leftX, y: barY, width: w, height: h), cornerWidth: w / 2, cornerHeight: w / 2, transform: nil)
        let rightBar = CGPath(roundedRect: CGRect(x: rightX, y: barY, width: w, height: h), cornerWidth: w / 2, cornerHeight: w / 2, transform: nil)
        ctx.addPath(leftBar)
        ctx.addPath(rightBar)
    }
    ctx.fillPath()

    // B. マイクのカプセル（本体）
    let micWidth: CGFloat = 140.0 * scale
    let micHeight: CGFloat = 250.0 * scale
    let micCapsuleY: CGFloat = centerY - 50.0 * scale
    let micRect = CGRect(x: centerX - micWidth / 2, y: micCapsuleY, width: micWidth, height: micHeight)
    let micPath = CGPath(roundedRect: micRect, cornerWidth: micWidth / 2, cornerHeight: micWidth / 2, transform: nil)

    // カプセル本体（ピュアホワイト〜ごく微細なグラデーション）
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.addPath(micPath)
    ctx.fillPath()

    // カプセル中央のスリットアクセントライン（スタジオマイク感）
    let slitY = micRect.midY + 15.0 * scale
    ctx.setStrokeColor(NSColor(red: 0.35, green: 0.25, blue: 0.8, alpha: 0.25).cgColor)
    ctx.setLineWidth(5.0 * scale)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: centerX - micWidth * 0.32, y: slitY))
    ctx.addLine(to: CGPoint(x: centerX + micWidth * 0.32, y: slitY))
    ctx.strokePath()

    // C. マイククレードル（U字アーム）
    let cradleWidth: CGFloat = 220.0 * scale
    let cradleRadius: CGFloat = cradleWidth / 2.0
    let cradleLineWidth: CGFloat = 24.0 * scale
    let cradleCenterY: CGFloat = micCapsuleY + micWidth / 2.0 + 15.0 * scale

    let cradlePath = CGMutablePath()
    // U字の弧（下半分）
    cradlePath.addArc(
        center: CGPoint(x: centerX, y: cradleCenterY),
        radius: cradleRadius,
        startAngle: 0,
        endAngle: .pi,
        clockwise: true
    )
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(cradleLineWidth)
    ctx.setLineCap(.round)
    ctx.addPath(cradlePath)
    ctx.strokePath()

    // D. 垂直ステム（支柱）
    let stemTopY = cradleCenterY - cradleRadius
    let stemHeight: CGFloat = 80.0 * scale
    let stemWidth: CGFloat = 24.0 * scale
    let stemRect = CGRect(x: centerX - stemWidth / 2, y: stemTopY - stemHeight, width: stemWidth, height: stemHeight)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(stemRect)

    // E. 台座（ベース）
    let baseWidth: CGFloat = 160.0 * scale
    let baseHeight: CGFloat = 26.0 * scale
    let baseY = stemRect.minY - baseHeight / 2
    let basePath = CGPath(roundedRect: CGRect(x: centerX - baseWidth / 2, y: baseY, width: baseWidth, height: baseHeight), cornerWidth: baseHeight / 2, cornerHeight: baseHeight / 2, transform: nil)
    ctx.addPath(basePath)
    ctx.fillPath()

    ctx.restoreGState()

    image.unlockFocus()
    return image
}

func savePNG(image: NSImage, path: String) {
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        print("Failed to generate PNG for \(path)")
        return
    }
    do {
        try pngData.write(to: URL(fileURLWithPath: path))
    } catch {
        print("Error saving PNG: \(error)")
    }
}

// アイコンセットの生成
let fileManager = FileManager.default
let iconsetDir = "AppIcon.iconset"
try? fileManager.removeItem(atPath: iconsetDir)
try? fileManager.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let sizes: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

print("-> Generating AppIcon PNGs...")
for (name, s) in sizes {
    let img = createIconImage(size: s)
    savePNG(image: img, path: "\(iconsetDir)/\(name)")
}

print("-> Running iconutil...")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetDir, "-o", "AppIcon.icns"]
try task.run()
task.waitUntilExit()

if task.terminationStatus == 0 {
    print("✅ AppIcon.icns successfully created!")
    // iconset ディレクトリは保持またはクリーンアップ
} else {
    print("❌ iconutil failed with exit code \(task.terminationStatus)")
}
