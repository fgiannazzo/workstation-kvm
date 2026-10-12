import AppCore
import Foundation
import SwitchboardCore
import Testing

@Suite("StatusGlyph")
struct StatusGlyphTests {
    @Test("PBP on, off and unknown pick the three symbols")
    func symbols() {
        #expect(StatusGlyph.symbol(for: SwitchboardState(pbp: .on, dualUpReachable: true)).name == "rectangle.split.1x2")
        #expect(StatusGlyph.symbol(for: SwitchboardState(pbp: .off, dualUpReachable: true)).name == "rectangle")
        #expect(StatusGlyph.symbol(for: SwitchboardState(pbp: .unknown, dualUpReachable: true)).name == "questionmark.square.dashed")
    }

    @Test("a healthy state is untinted")
    func healthy() {
        #expect(StatusGlyph.symbol(for: SwitchboardState(pbp: .off, dualUpReachable: true)).tint == .primary)
    }

    @Test("an unreachable DualUp dims the glyph but keeps the last PBP state")
    func unreachable() {
        let glyph = StatusGlyph.symbol(for: SwitchboardState(pbp: .on, dualUpReachable: false))
        #expect(glyph.name == "rectangle.split.1x2")
        #expect(glyph.tint == .secondary)
    }

    @Test("a state nothing has been read into is the dashed question mark, dimmed")
    func fresh() {
        let glyph = StatusGlyph.symbol(for: SwitchboardState())
        #expect(glyph.name == "questionmark.square.dashed")
        #expect(glyph.tint == .secondary)
    }

    @Test("a last error turns the glyph red, also when the DualUp is unreachable")
    func error() {
        #expect(StatusGlyph.symbol(for: SwitchboardState(pbp: .off, dualUpReachable: true, lastError: "guest: boom")).tint == .red)
        #expect(StatusGlyph.symbol(for: SwitchboardState(pbp: .off, dualUpReachable: false, lastError: "guest: boom")).tint == .red)
    }
}
