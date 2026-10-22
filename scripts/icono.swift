// Dibuja el ícono de la app (una M de barritas negras sobre amarillo) y arma Recursos/Minuta.icns.
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
    // Fondo: cuadrado redondeado amarillo (el de la ventana de Minuta) con el margen de los íconos de macOS.
    let fondo = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    NSGradient(starting: NSColor(srgbRed: 0.99, green: 0.94, blue: 0.50, alpha: 1),
               ending: NSColor(srgbRed: 0.96, green: 0.90, blue: 0.39, alpha: 1))!
        .draw(in: NSBezierPath(roundedRect: fondo, xRadius: s * 0.18, yRadius: s * 0.18), angle: -90)
    // Una M negra hecha de barritas, como las que se mueven cuando hablas.
    NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).setFill()
    let zona = fondo.insetBy(dx: s * 0.12, dy: s * 0.19)
    let alturas: [CGFloat] = [1, 0.72, 0.42, 0.72, 1]
    let ancho = s * 0.075, espacio = s * 0.035
    var x = zona.midX - (CGFloat(alturas.count) * ancho + CGFloat(alturas.count - 1) * espacio) / 2
    for a in alturas {
        let h = zona.height * a
        NSBezierPath(roundedRect: NSRect(x: x, y: zona.midY - h / 2, width: ancho, height: h),
                     xRadius: ancho / 2, yRadius: ancho / 2).fill()
        x += ancho + espacio
    }
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
