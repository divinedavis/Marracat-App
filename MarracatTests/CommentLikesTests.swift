import Foundation
import Testing
@testable import Marracat

/// The product page's top comments and liking (owner, 2026-11-04: "keep
/// comments to the top 3 comments that have the most likes", "we need to
/// allow likes").
struct CommentLikesTests {
    private func comment(_ id: String, likes: Int = 0, at t: Double = 0, deleted: Bool = false,
                         replies: [SocialStore.Comment]? = nil) -> SocialStore.Comment {
        SocialStore.Comment(id: id, author: deleted ? nil : .init(handle: id, name: id.uppercased()), body: deleted ? "" : "hi",
                            created_at: t, mine: false, deleted: deleted, under_review: false, replies: replies,
                            likes: likes, liked: false)
    }

    @Test func mostLikedFirstNewestAmongEqualsRemovedLast() {
        let ts = [comment("old", likes: 2, at: 1), comment("gone", deleted: true, replies: [comment("r")]),
                  comment("top", likes: 9, at: 2), comment("new", likes: 2, at: 5), comment("none", at: 9)]
        #expect(CommentsSection.ranked(ts).map(\.id) == ["top", "new", "old", "none", "gone"])
        #expect(CommentsSection.total(ts) == 5, "four comments and one reply; the removed one doesn't count")
    }

    @Test func aLikeTogglesAtOnceAndTheServerHasTheLastWord() throws {
        let ts = [comment("a", likes: 3, replies: [comment("r", likes: 1)])]
        let liked = CommentLikes.toggled(ts, "r")
        #expect(liked[0].replies?[0].likeCount == 2)
        #expect(liked[0].replies?[0].isLiked == true)
        #expect(liked[0].likeCount == 3, "only the comment liked")
        let back = CommentLikes.toggled(liked, "r")
        #expect(back[0].replies?[0].likeCount == 1)
        let json = Data(#"{"likes":7,"liked":true}"#.utf8)
        let server = CommentLikes.set(ts, "a", try JSONDecoder().decode(SocialStore.LikeState.self, from: json))
        #expect(server[0].likeCount == 7 && server[0].isLiked)
    }

    @Test func anOlderServerWithoutLikesReadsAsNone() throws {
        let json = Data(#"{"id":"x","author":null,"body":"hi","created_at":1,"mine":false,"deleted":false,"under_review":false,"replies":[]}"#.utf8)
        let c = try JSONDecoder().decode(SocialStore.Comment.self, from: json)
        #expect(c.likeCount == 0 && !c.isLiked)
    }
}
