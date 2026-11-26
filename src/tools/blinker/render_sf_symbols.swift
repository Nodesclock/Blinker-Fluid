import AppKit
// render_sf_symbols.swift <out-dir> <name>...
// SF Symbols у PNG для iOS 12, де systemImageNamed нема.
let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args[1])
var missing: [String] = []
for name in args.dropFirst(2) {
  let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
  guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
        let image = base.withSymbolConfiguration(config) else {
    missing.append(name)
    continue
  }
  let size = image.size
  for scale in [2, 3] {
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int((size.width * CGFloat(scale)).rounded(.up)),
      pixelsHigh: Int((size.height * CGFloat(scale)).rounded(.up)), bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0) else { continue }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: size))
    NSColor.black.set()
    NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
    NSGraphicsContext.restoreGraphicsState()
    // Крапки стають підкресленнями, бо imageNamed бере крапку за розширення.
    let stem = name.replacingOccurrences(of: ".", with: "_")
    let file = outDir.appendingPathComponent("sf_\(stem)@\(scale)x.png")
    try! rep.representation(using: .png, properties: [:])!.write(to: file)
  }
}
print("missing:", missing)
