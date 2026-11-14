import Foundation
import Testing
@testable import Marracat

/// The header title that glides left when it doesn't fit (owner, 2026-11-04,
/// picked "1 · Loop").
struct MarqueeTextTests {
    @Test func aNameThatFitsOrReduceMotionStandsStill() {
        #expect(!MarqueeText.moves(textWidth: 180, in: 200, reduceMotion: false))
        #expect(MarqueeText.moves(textWidth: 320, in: 200, reduceMotion: false))
        #expect(!MarqueeText.moves(textWidth: 320, in: 200, reduceMotion: true))
    }

    @Test func itWaitsThenMovesAndComesRoundAgain() {
        let w: CGFloat = 320
        #expect(MarqueeText.offset(elapsed: 1.0, textWidth: w) == 0, "still for the pause")
        #expect(MarqueeText.offset(elapsed: MarqueeText.pause + 1, textWidth: w) == -MarqueeText.speed)
        let cycle = MarqueeText.pause + Double((w + MarqueeText.gap) / MarqueeText.speed)
        #expect(MarqueeText.offset(elapsed: cycle + 0.5, textWidth: w) == 0, "the second copy has taken the first's place")
    }
}
