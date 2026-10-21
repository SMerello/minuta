// Dibuja el ícono de la app (botón de grabar rojo sobre fondo claro) y arma Recursos/Minuta.icns.
// Uso: swift scripts/icono.swift   (desde la raíz del repo)
import AppKit

let carpeta = URL(fileURLWithPath: "Recursos/Minuta.iconset")
try? FileManager.default.removeItem(at: carpeta)
try! FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)

func dibujar(_ lado: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: lado, pixelsHigh: lado, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(lado)
    // Fondo: cuadrado redondeado con el margen que usan los íconos de macOS.
    let fondo = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    NSGradient(starting: NSColor(white: 1, alpha: 1), ending: NSColor(white: 0.9, alpha: 1))!
        .draw(in: NSBezierPath(roundedRect: fondo, xRadius: s * 0.18, yRadius: s * 0.18), angle: -90)
    // Anillo gris y punto rojo: un botón de grabar.
    let anillo = NSBezierPath(ovalIn: fondo.insetBy(dx: s * 0.14, dy: s * 0.14))
    anillo.lineWidth = s * 0.035
    NSColor(white: 0.25, alpha: 1).setStroke()
    anillo.stroke()
    NSColor(srgbRed: 0.93, green: 0.2, blue: 0.2, alpha: 1).setFill()
    NSBezierPath(ovalIn: fondo.insetBy(dx: s * 0.235, dy: s * 0.235)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! dibujar(base).write(to: carpeta.appendingPathComponent("icon_\(base)x\(base).png"))
    try! dibujar(base * 2).write(to: carpeta.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", carpeta.path, "-o", "Recursos/Minuta.icns"]
try! p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: carpeta)
print(p.terminationStatus == 0 ? "✓ Recursos/Minuta.icns" : "iconutil falló")
