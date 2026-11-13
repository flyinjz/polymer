// Renders the CoreText reference images that PolymerText is tuned against.
// Mac only. Run: swift Tools/Reference/coretext_reference.swift
// Output: Tests/Reference/Text/<font>-<size>pt-<scale>x-<theme>.png and manifest.json
import CoreText
import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let fontsDir = root.appendingPathComponent("Tests/Fixtures/Fonts")
let outDir = root.appendingPathComponent("Tests/Reference/Text")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let fonts = ["JetBrainsMono-Regular.ttf", "GeistMono-Regular.otf", "Inter-Regular.otf", "Geist-Regular.otf"]
let sizes: [CGFloat] = [10, 11, 12, 13, 15, 18, 24, 36]
let scales: [CGFloat] = [1, 2]
let text = "Hamburgefonstiv 0123456789 AVAWAy Tracks: 12 of 48, 3:42"
// Themes: (name, background, foreground) in sRGB 0...1.
let themes: [(String, CGFloat, CGFloat)] = [("dark", 0.063, 0.902), ("light", 0.965, 0.110)]
let originX: CGFloat = 8.25   // fractional on purpose: positioning must be exact

var manifest: [[String: Any]] = []
for file in fonts {
    let url = fontsDir.appendingPathComponent(file)
    guard let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], let desc = descs.first else {
        fatalError("cannot load \(file)")
    }
    let stem = (file as NSString).deletingPathExtension
    for size in sizes {
        for scale in scales {
            let font = CTFontCreateWithFontDescriptor(desc, size * scale, nil)
            let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
            for (theme, bg, fg) in themes {
                let attr = NSAttributedString(string: text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: fg, green: fg, blue: fg, alpha: 1),
                ])
                let line = CTLineCreateWithAttributedString(attr)
                let width = Int(ceil(CTLineGetTypographicBounds(line, nil, nil, nil) + 2 * originX * scale))
                let height = Int(ceil(ascent + descent + 8 * scale))
                let baseline = (CGFloat(height) - (ascent + descent)) / 2 + descent
                let cs = CGColorSpace(name: CGColorSpace.sRGB)!
                let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.setFillColor(CGColor(srgbRed: bg, green: bg, blue: bg, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                ctx.setAllowsAntialiasing(true); ctx.setShouldAntialias(true)
                ctx.setAllowsFontSmoothing(true); ctx.setShouldSmoothFonts(true)
                ctx.setAllowsFontSubpixelPositioning(true); ctx.setShouldSubpixelPositionFonts(true)
                ctx.setAllowsFontSubpixelQuantization(false); ctx.setShouldSubpixelQuantizeFonts(false)
                ctx.textPosition = CGPoint(x: originX * scale, y: baseline)
                CTLineDraw(line, ctx)
                let name = "\(stem)-\(Int(size))pt-\(Int(scale))x-\(theme).png"
                let dest = CGImageDestinationCreateWithURL(outDir.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
                CGImageDestinationFinalize(dest)
                manifest.append(["file": name, "font": file, "pointSize": size, "scale": scale, "theme": theme,
                                 "background": bg, "foreground": fg, "text": text,
                                 "originX": originX * scale, "baselineFromBottom": baseline, "width": width, "height": height])
            }
        }
    }
}
let json = try JSONSerialization.data(withJSONObject: ["renderer": "CoreText", "fontSmoothing": true, "subpixelPositioning": true, "images": manifest], options: [.prettyPrinted, .sortedKeys])
try json.write(to: outDir.appendingPathComponent("manifest.json"))
print("wrote \(manifest.count) images")
