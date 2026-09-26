//  make_icon.swift  — az app-ikon (1024×1024 PNG-k) előállítása CoreGraphics-szel.
//  Futtatás:  swift tools/make_icon.swift ScooterLink/Assets.xcassets/AppIcon.appiconset
//  Három változat: világos (AppIcon), sötét (AppIcon-dark) és színezett (AppIcon-tinted) — az iOS
//  a kezdőképernyő ikon-beállítása szerint választ. Saját rajzolt roller-sziluett
//  (SF Symbol app-ikonban nem használható).

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func gradient(_ colors: [CGColor], _ locs: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)!
}

// roller-sziluett (oldalnézet): hátsó kerék peremén futó deszka, döntött kormányszár.
// Egységes vonalvastagság: így a deszka lekerekített vége pontosan a gumi vonalára ül.
let rear = CGPoint(x: 300, y: 700), front = CGPoint(x: 730, y: 700)
let R: CGFloat = 96, tyre: CGFloat = 46, bar: CGFloat = 46
let stemTop = CGPoint(x: 628, y: 250), gripEnd = CGPoint(x: 520, y: 250)
let bbox = CGRect(x: rear.x - R - tyre / 2, y: stemTop.y - bar / 2,
                  width: (front.x + R + tyre / 2) - (rear.x - R - tyre / 2),
                  height: (rear.y + R + tyre / 2) - (stemTop.y - bar / 2))

func drawGlyph(_ ctx: CGContext) {
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1)); ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    for c in [rear, front] {                                            // kerekek: gumi + agy
        ctx.setLineWidth(tyre)
        ctx.strokeEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
        ctx.fillEllipse(in: CGRect(x: c.x - 22, y: c.y - 22, width: 44, height: 44))
    }
    ctx.setLineWidth(bar)
    let deckY = rear.y - R                                              // deszka a hátsó kerék peremén
    ctx.move(to: CGPoint(x: rear.x, y: deckY))
    ctx.addLine(to: CGPoint(x: front.x - (front.y - deckY) * (front.x - stemTop.x) / (front.y - stemTop.y), y: deckY))
    ctx.strokePath()
    ctx.move(to: front); ctx.addLine(to: stemTop); ctx.addLine(to: gripEnd); ctx.strokePath()   // szár + kormány
}

enum Variant: String, CaseIterable { case light = "AppIcon", dark = "AppIcon-dark", tinted = "AppIcon-tinted" }

func render(_ v: Variant) -> CGImage {
    // alfa nélküli bitmap (az app-ikon nem lehet átlátszó)
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)              // felülről lefelé koordináták

    // háttér
    switch v {
    case .light:
        ctx.drawLinearGradient(gradient([rgb(0x4BE393), rgb(0x1DB46D), rgb(0x0A774C)], [0, 0.55, 1]),
                               start: .zero, end: CGPoint(x: S, y: S), options: [])
        ctx.drawRadialGradient(gradient([CGColor(gray: 1, alpha: 0.24), CGColor(gray: 1, alpha: 0)]),
                               startCenter: CGPoint(x: 230, y: 160), startRadius: 0,
                               endCenter: CGPoint(x: 230, y: 160), endRadius: 780, options: [])
    case .dark:
        ctx.drawLinearGradient(gradient([rgb(0x1E2422), rgb(0x090B0A)]), start: .zero,
                               end: CGPoint(x: S, y: S), options: [])
        ctx.drawRadialGradient(gradient([rgb(0x2FD17A, 0.20), rgb(0x2FD17A, 0)]),
                               startCenter: CGPoint(x: 250, y: 190), startRadius: 0,
                               endCenter: CGPoint(x: 250, y: 190), endRadius: 720, options: [])
    case .tinted:
        ctx.drawLinearGradient(gradient([rgb(0x262626), rgb(0x0C0C0C)]), start: .zero,
                               end: CGPoint(x: S, y: S), options: [])
    }

    ctx.translateBy(x: S / 2 - bbox.midX, y: S / 2 - bbox.midY)       // a sziluett középre

    if v == .light {                                                    // lágy talaj-árnyék a kerekek alatt
        ctx.saveGState()
        ctx.translateBy(x: (rear.x + front.x) / 2, y: rear.y + R + tyre / 2 + 22)
        ctx.scaleBy(x: 1, y: 0.11)
        ctx.drawRadialGradient(gradient([CGColor(gray: 0, alpha: 0.22), CGColor(gray: 0, alpha: 0)]),
                               startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 400, options: [])
        ctx.restoreGState()
    }

    switch v {
    case .light: ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.20))
    case .dark:  ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: rgb(0x2FD17A, 0.28))
    case .tinted: break
    }
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    drawGlyph(ctx)
    if v != .light {                                                    // a sziluett átszínezése (csak ahol rajz van)
        ctx.setBlendMode(.sourceIn)
        let g = v == .dark ? gradient([rgb(0x62EDA3), rgb(0x1FB872)])
                           : gradient([CGColor(gray: 1, alpha: 1), CGColor(gray: 0.72, alpha: 1)])
        ctx.drawLinearGradient(g, start: CGPoint(x: bbox.minX, y: bbox.minY),
                               end: CGPoint(x: bbox.maxX, y: bbox.maxY), options: [])
    }
    ctx.endTransparencyLayer()
    return ctx.makeImage()!
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
for v in Variant.allCases {
    let out = dir.appendingPathComponent("\(v.rawValue).png")
    let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, render(v), nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("PNG írás sikertelen: \(out.path)") }
    print("kész: \(out.path)")
}
