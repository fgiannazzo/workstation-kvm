import AppCore
import AppKit
import SwiftUI

/// The status item's glyph: `StatusGlyph` for the current state.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let glyph = StatusGlyph.symbol(for: model.state)
        Image(nsImage: StatusImage.make(symbol: glyph.name, tint: glyph.tint))
            .accessibilityLabel("Switchboard")
    }
}

/// SF Symbols as menu bar images. The menu bar draws template images in its own colour, which is
/// what `primary` wants (light and dark menu bars). `secondary` is the same template at reduced
/// opacity. Only `red` is a real colour, so it is not a template.
@MainActor
enum StatusImage {
    static func make(symbol: String, tint: Tint) -> NSImage {
        let size = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "Switchboard")?
            .withSymbolConfiguration(size)
        else { return NSImage() }

        switch tint {
        case .primary:
            base.isTemplate = true
            return base
        case .secondary:
            let dimmed = NSImage(size: base.size, flipped: false) { rect in
                base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.45)
                return true
            }
            dimmed.isTemplate = true
            return dimmed
        case .red:
            let colored = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            let image = base.withSymbolConfiguration(size.applying(colored)) ?? base
            image.isTemplate = false
            return image
        }
    }
}
