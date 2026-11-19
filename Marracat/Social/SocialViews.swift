import SwiftUI

// MARK: - Comments

/// Comments under a product (owner, 2026-11-04, picked "A · Instagram
/// classic" from three previews): the three most-liked comments, each with
/// its heart, then "View all N comments" and "Add a comment…". Touching any
/// of it opens CommentsSheet, Instagram's half-height sheet that drags up
/// to full. Anyone can read; liking needs an account, posting an account and
/// the community terms.
struct CommentsSection: View {
    let productID: String
    @Environment(SocialStore.self) private var social
    @Environment(AppNav.self) private var nav
    @State private var threads: [SocialStore.Comment] = []
    @State private var loaded = false
    @State private var sheet: CommentsSheet.Opening?

    /// How many comments the product page shows.
    static let shown = 3

    /// The most-liked comments first, newest first among equals; removed
    /// ones never lead.
    static func ranked(_ threads: [SocialStore.Comment]) -> [SocialStore.Comment] {
        threads.enumerated().sorted { a, b in
            if a.element.deleted != b.element.deleted { return !a.element.deleted }
            if a.element.likeCount != b.element.likeCount { return a.element.likeCount > b.element.likeCount }
            return a.element.created_at != b.element.created_at ? a.element.created_at > b.element.created_at : a.offset < b.offset
        }.map(\.element)
    }

    /// Every comment and reply still standing.
    static func total(_ threads: [SocialStore.Comment]) -> Int {
        threads.reduce(0) { $0 + ($1.deleted ? 0 : 1) + ($1.replies ?? []).filter { !$0.deleted }.count }
    }

    var body: some View {
        let top = Array(Self.ranked(threads).filter { !$0.deleted }.prefix(Self.shown))
        let total = Self.total(threads)
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Comments").font(.headline)
                if total > 0 { Text("\(total)").font(.subheadline).foregroundStyle(.secondary) }
            }
            .accessibilityIdentifier("commentsHeader")

            if loaded && top.isEmpty {
                Text("No comments yet. Be the first to say what you think.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(top) { c in
                CommentLine(comment: c, compact: true, onLike: { await like(c) })
                    .contentShape(Rectangle())
                    .onTapGesture { sheet = .read }
            }
            if total > top.count {
                Button { sheet = .read } label: {
                    Text("View all \(total) comments", comment: "Under the top comments on a product page; the argument is how many there are")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("viewAllComments")
            }
            if social.signedIn {
                Button { sheet = .write } label: {
                    Text("Add a comment…").font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Capsule().fill(Theme.field))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("addComment")
            } else {
                Button { nav.tab = .you } label: {
                    Label("Sign in to comment", systemImage: "person.crop.circle")
                        .font(.subheadline.weight(.semibold))
                }
                .accessibilityIdentifier("commentSignIn")
            }
        }
        .task(id: "\(productID)-\(social.revision)") { await reload() }
        .sheet(item: $sheet, onDismiss: { Task { await reload() } }) { opening in
            CommentsSheet(productID: productID, startWriting: opening == .write)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.surface)
        }
    }

    private func reload() async {
        guard let t = try? await social.comments(for: productID) else { loaded = true; return }
        threads = t.comments; loaded = true
    }

    private func like(_ c: SocialStore.Comment) async {
        guard social.signedIn else { nav.tab = .you; return }
        threads = CommentLikes.toggled(threads, c.id)
        if let state = try? await social.setLike(c, !c.isLiked) {
            threads = CommentLikes.set(threads, c.id, state)
        } else {
            threads = CommentLikes.toggled(threads, c.id)
        }
    }
}

/// Liking changes a comment wherever it sits in a thread.
enum CommentLikes {
    static func map(_ threads: [SocialStore.Comment], _ id: String,
                    _ change: (inout SocialStore.Comment) -> Void) -> [SocialStore.Comment] {
        threads.map { t in
            var t = t
            if t.id == id { change(&t) }
            t.replies = t.replies?.map { r in var r = r; if r.id == id { change(&r) }; return r }
            return t
        }
    }
    /// At once, before the server answers.
    static func toggled(_ threads: [SocialStore.Comment], _ id: String) -> [SocialStore.Comment] {
        map(threads, id) { c in
            let on = !c.isLiked
            c.liked = on
            c.likes = max(0, c.likeCount + (on ? 1 : -1))
        }
    }
    /// What the server says.
    static func set(_ threads: [SocialStore.Comment], _ id: String, _ s: SocialStore.LikeState) -> [SocialStore.Comment] {
        map(threads, id) { c in c.likes = s.likes; c.liked = s.liked }
    }
}

/// Instagram's comments sheet: every thread, most-liked first, replies
/// folded under "View N replies", a heart on each, a row of quick emoji and
/// the comment box at the foot.
struct CommentsSheet: View {
    enum Opening: Identifiable { case read, write; var id: Self { self } }

    let productID: String
    var startWriting = false
    @Environment(SocialStore.self) private var social
    @Environment(AppNav.self) private var nav
    @Environment(\.dismiss) private var dismiss
    @State private var threads: [SocialStore.Comment] = []
    @State private var loaded = false
    @State private var open: Set<String> = []
    @State private var draft = ""
    @State private var replyingTo: SocialStore.Comment?
    @State private var error: String?
    @State private var busy = false
    @State private var showTerms = false
    @FocusState private var composing: Bool

    private let limit = 1000
    static let quickEmoji = ["❤️", "🙌", "🔥", "👏", "😢", "😍", "😮", "😂"]

    var body: some View {
        VStack(spacing: 0) {
            Text("Comments").font(.headline).padding(.top, 18).padding(.bottom, 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if loaded && threads.isEmpty {
                        Text("No comments yet. Be the first to say what you think.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 30)
                    }
                    ForEach(CommentsSection.ranked(threads)) { thread in
                        threadView(thread)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 14)
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .task { await reload(); if startWriting && social.signedIn { composing = true } }
        .sheet(isPresented: $showTerms) {
            CommunityTermsSheet {
                Task {
                    try? await social.agreeToTerms()
                    showTerms = false
                    await submit()
                }
            }
        }
        .accessibilityIdentifier("commentsSheet")
    }

    @ViewBuilder
    private func threadView(_ thread: SocialStore.Comment) -> some View {
        let replies = thread.replies ?? []
        VStack(alignment: .leading, spacing: 12) {
            CommentLine(comment: thread, onLike: { await like(thread) }, onReply: { reply(to: thread) }, onChange: reload)
            if !replies.isEmpty {
                if open.contains(thread.id) {
                    ForEach(replies) { r in
                        CommentLine(comment: r, small: true, onLike: { await like(r) }, onReply: { reply(to: thread) }, onChange: reload)
                    }
                    .padding(.leading, 42)
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if open.contains(thread.id) { open.remove(thread.id) } else { open.insert(thread.id) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Rectangle().frame(width: 22, height: 1)
                        Text(open.contains(thread.id) ? String(localized: "Hide replies", comment: "Folds a comment's replies away")
                             : (replies.count == 1 ? String(localized: "View 1 reply", comment: "Unfolds a comment's one reply")
                                : String(localized: "View \(replies.count) replies", comment: "Unfolds a comment's replies; the argument is how many")))
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 42)
                .accessibilityIdentifier("commentReplies")
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            Divider()
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.top, 6)
                    .accessibilityIdentifier("commentError")
            }
            if social.signedIn {
                if let r = replyingTo {
                    HStack {
                        Text("Replying to \(r.author?.name ?? String(localized: "comment", comment: "Fallback in: Replying to comment"))")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { replyingTo = nil } label: { Image(systemName: "xmark").font(.caption.bold()) }
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Cancel reply")
                    }
                    .padding(.horizontal, 16).padding(.top, 8)
                }
                HStack(spacing: 0) {
                    ForEach(Self.quickEmoji, id: \.self) { e in
                        Button { draft += e } label: { Text(e).font(.title3).frame(maxWidth: .infinity, minHeight: 40) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .accessibilityIdentifier("quickEmoji")
                HStack(spacing: 10) {
                    Avatar(name: social.me?.profile.name ?? "", size: 32)
                    TextField(replyingTo == nil ? String(localized: "Add a comment…", comment: "Comment box placeholder")
                              : String(localized: "Write a reply…", comment: "Comment box placeholder when replying"),
                              text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($composing)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Capsule().fill(Theme.field))
                        .onChange(of: draft) { if draft.count > limit { draft = String(draft.prefix(limit)) } }
                        .accessibilityIdentifier("commentField")
                    if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button(replyingTo == nil ? String(localized: "Post", comment: "Posts a comment") : String(localized: "Reply", comment: "Posts a reply")) {
                            Task { await submit() }
                        }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.link)
                        .disabled(busy)
                        .accessibilityIdentifier("commentPost")
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 10)
            } else {
                Button { dismiss(); nav.tab = .you } label: {
                    Label("Sign in to comment", systemImage: "person.crop.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .accessibilityIdentifier("commentSignIn")
            }
        }
        .background(Theme.surface)
    }

    private func reply(to thread: SocialStore.Comment) {
        guard social.signedIn else { dismiss(); nav.tab = .you; return }
        replyingTo = thread
        open.insert(thread.id)
        composing = true
    }

    private func like(_ c: SocialStore.Comment) async {
        guard social.signedIn else { dismiss(); nav.tab = .you; return }
        threads = CommentLikes.toggled(threads, c.id)
        if let state = try? await social.setLike(c, !c.isLiked) {
            threads = CommentLikes.set(threads, c.id, state)
        } else {
            threads = CommentLikes.toggled(threads, c.id)
        }
    }

    private func reload() async {
        guard let t = try? await social.comments(for: productID) else { loaded = true; return }
        threads = t.comments; loaded = true
    }

    private func submit() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let parent = replyingTo?.id
            try await social.post(body, on: productID, replyingTo: parent)
            Analytics.shared.track("comment_post", ["product": .string(productID)])
            draft = ""; replyingTo = nil; composing = false
            if let parent { open.insert(parent) }
            await reload()
        } catch let refused as SocialStore.Refused where refused.needsTerms {
            showTerms = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A round initial for someone with no photo, its colour fixed by the name.
struct Avatar: View {
    let name: String
    var size: CGFloat = 32
    private static let palette: [Color] = [Theme.gold, .pink, .orange, .teal, .indigo, .purple, .green, .cyan]

    var body: some View {
        let initial = name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "•"
        let index = Int(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }) % Self.palette.count
        Circle().fill(Self.palette[index].gradient)
            .frame(width: size, height: size)
            .overlay(Text(initial).font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(.white))
            .accessibilityHidden(true)
    }
}

/// One comment, Instagram's way: initial, name and age, the text, Reply, and
/// a heart with its count on the right. `compact` is the product page's
/// version: two lines of text and no Reply.
private struct CommentLine: View {
    let comment: SocialStore.Comment
    var compact = false
    var small = false
    let onLike: () async -> Void
    var onReply: () -> Void = {}
    var onChange: () async -> Void = {}
    @Environment(SocialStore.self) private var social
    @State private var confirmReport = false
    @State private var confirmBlock = false
    @State private var message: String?

    /// "now", "5m", "3h", "2d", "4w": Instagram's ages.
    static func age(_ date: Date, now: Date = .now) -> String {
        let s = max(0, now.timeIntervalSince(date))
        switch s {
        case ..<60: return String(localized: "now", comment: "A comment's age: under a minute")
        case ..<3600: return String(localized: "\(Int(s / 60))m", comment: "A comment's age in minutes, short")
        case ..<86400: return String(localized: "\(Int(s / 3600))h", comment: "A comment's age in hours, short")
        case ..<(86400 * 7): return String(localized: "\(Int(s / 86400))d", comment: "A comment's age in days, short")
        default: return String(localized: "\(Int(s / (86400 * 7)))w", comment: "A comment's age in weeks, short")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: comment.author?.name ?? "", size: small ? 26 : 32)
                .opacity(comment.deleted ? 0.3 : 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(comment.author?.name ?? (comment.deleted ? String(localized: "Removed", comment: "In place of a removed comment's author")
                                                  : String(localized: "Marracat shopper", comment: "A commenter with no profile name")))
                        .font(.caption.weight(.semibold))
                    Text(Self.age(comment.date)).font(.caption).foregroundStyle(.secondary)
                }
                if comment.deleted {
                    Text("This comment was removed.").font(.subheadline).italic().foregroundStyle(.secondary)
                } else {
                    Text(comment.body).font(.subheadline)
                        .lineLimit(compact ? 2 : nil)
                        .textSelection(.enabled)
                    if comment.under_review {
                        Label("Under review", systemImage: "eye.slash").font(.caption2).foregroundStyle(.secondary)
                    }
                    if !compact {
                        HStack(spacing: 16) {
                            Button("Reply", action: onReply).accessibilityIdentifier("commentReply")
                            if social.signedIn { menu }
                        }
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 4)
            if !comment.deleted { heart }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("comment")
        .confirmationDialog("Report this comment?", isPresented: $confirmReport, titleVisibility: .visible) {
            ForEach(["Harassment or hate", "Spam", "Sexual content", "Something else"], id: \.self) { reason in
                Button(reportReasonLabel(reason)) { Task { await act { try await social.report(comment, reason: reason) }; message = String(localized: "Thanks. It's hidden while we review it.", comment: "Confirmation after reporting a comment") } }
            }
        } message: { Text("It's hidden right away and reviewed by Marracat within 24 hours.") }
        .confirmationDialog("Block \(comment.author?.name ?? String(localized: "this person", comment: "Fallback when a commenter has no name, used in: Block this person?"))?", isPresented: $confirmBlock, titleVisibility: .visible) {
            Button("Block", role: .destructive) { Task { await act { try await social.blockAuthor(of: comment) } } }
        } message: { Text("You won't see each other's comments, profiles or shares, and any friendship ends. You can unblock them from the You tab.") }
    }

    private var heart: some View {
        Button { Task { await onLike() } } label: {
            VStack(spacing: 2) {
                Image(systemName: comment.isLiked ? "heart.fill" : "heart")
                    .font(.system(size: small ? 13 : 15))
                    .foregroundStyle(comment.isLiked ? Color.red : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                if comment.likeCount > 0 {
                    Text("\(comment.likeCount)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .frame(minWidth: 36, minHeight: 36, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: comment.isLiked)
        .accessibilityLabel(comment.isLiked ? String(localized: "Unlike", comment: "Removes your like from a comment") : String(localized: "Like", comment: "Likes a comment"))
        .accessibilityValue(comment.likeCount == 1 ? String(localized: "1 like", comment: "A comment's like count")
                            : String(localized: "\(comment.likeCount) likes", comment: "A comment's like count"))
        .accessibilityIdentifier("commentLike")
    }

    private var menu: some View {
        Menu {
            if comment.mine {
                Button("Delete", role: .destructive) { Task { await act { try await social.delete(comment) } } }
            } else {
                Button { confirmReport = true } label: { Label("Report", systemImage: "flag") }
                if comment.author != nil {
                    Button(role: .destructive) { confirmBlock = true } label: { Label("Block", systemImage: "hand.raised") }
                }
            }
        } label: {
            Image(systemName: "ellipsis").frame(width: 28, height: 20)
        }
        .accessibilityLabel("Comment options")
    }

    private func act(_ work: () async throws -> Void) async {
        do { try await work(); await onChange() } catch { message = error.localizedDescription }
    }
}

/// Agreed once, before someone first posts or sends a note (App Store 1.2).
struct CommunityTermsSheet: View {
    let onAgree: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Keep Marracat kind").font(.title2.bold())
                    Text("Comments and shares are for talking about products and the brands behind them.")
                    ForEach([
                        String(localized: "No harassment, hate speech or slurs.", comment: "Community rule"),
                        String(localized: "No sexual content or threats.", comment: "Community rule"),
                        String(localized: "No spam, scams or links.", comment: "Community rule"),
                        String(localized: "Report anything that breaks these rules. Reported posts are hidden right away and reviewed within 24 hours.", comment: "Community rule"),
                        String(localized: "Posts that break them are removed, and accounts that keep breaking them are banned.", comment: "Community rule"),
                    ], id: \.self) { rule in
                        Label(rule, systemImage: "checkmark.circle").font(.subheadline)
                    }
                    Text("Messages you send to friends are end-to-end encrypted. If someone reports one, their phone shares that message with Marracat so it can be reviewed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom) {
                Button("I agree") { onAgree() }
                    .buttonStyle(PillButtonStyle(color: Theme.gold)).padding(16)
                    .accessibilityIdentifier("agreeTerms")
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Not now") { dismiss() } } }
        }
    }
}

// MARK: - Sharing

/// "Share" goes anywhere through the system share sheet. ("Send to friends",
/// to Marracat friends end-to-end encrypted, was removed 2026-10-06 at the
/// owner's ask.)
struct ShareActions: View {
    let product: Product

    static func link(for product: Product) -> URL { URL(string: "https://marracat.com/p/\(product.id)")! }

    var body: some View {
        Group {
            // The link alone (owner, 2026-10-03): a message alongside it
            // arrived as a second line under iMessage's preview card, which
            // already shows the photo and the title. The subject is only
            // used by Mail.
            ShareLink(item: Self.link(for: product), subject: Text(product.title)) {
                ActionChipLabel(title: String(localized: "Share", comment: "Button: share the product with friends"), symbol: "square.and.arrow.up", tint: .cyan)
            }
            .simultaneousGesture(TapGesture().onEnded {
                Analytics.shared.track("share", ["kind": .string("product"), "target": .string(product.id)])
            })
            .accessibilityIdentifier("shareProduct")
        }
    }
}

// MARK: - You tab

/// Profile, friends, shares received and blocked people.
struct SocialPanel: View {
    @Environment(SocialStore.self) private var social
    @State private var editing = false

    var body: some View {
        if social.signedIn, let me = social.me {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(me.profile.name).font(.title3.bold())
                        Text("@\(me.profile.handle)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit profile") { editing = true }.font(.subheadline).accessibilityIdentifier("editProfile")
                }
                row(String(localized: "Friends", comment: "Row in the Connect screen"), systemImage: "person.2", badge: me.counts.incoming, route: .friends)
                row(String(localized: "Shared with you", comment: "Row in the Connect screen: products friends shared"), systemImage: "tray", badge: me.counts.unseen_shares, route: .inbox)
                row(String(localized: "Blocked", comment: "Row in the Connect screen: blocked people"), systemImage: "hand.raised", badge: 0, route: .blocked)
                if me.owner {
                    // Reports need action within 24 hours. The queue lives on
                    // the website, where there's room to review them.
                    Link(destination: URL(string: "https://marracat.com/#/moderation")!) {
                        HStack {
                            Label("Review reports", systemImage: "flag")
                            Spacer()
                            if let n = me.counts.reports, n > 0 {
                                Text("\(n)").font(.caption.bold()).foregroundStyle(.white)
                                    .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(.red))
                            }
                            Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
            .padding(.horizontal, 12)
            .sheet(isPresented: $editing) { EditProfileSheet(profile: me.profile) }
        }
    }

    private func row(_ title: String, systemImage: String, badge: Int, route: Route) -> some View {
        NavigationLink(value: route) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if badge > 0 {
                    Text("\(badge)").font(.caption.bold()).foregroundStyle(.black)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Theme.gold))
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct EditProfileSheet: View {
    let profile: SocialStore.Profile
    @Environment(SocialStore.self) private var social
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var handle = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("Your name", text: $name).textContentType(.name) }
                Section {
                    TextField("handle", text: $handle).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Handle") } footer: { Text("3 to 20 letters, numbers or underscores. Friends find you by it.") }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            do {
                                try await social.updateProfile(name: name == profile.name ? nil : name,
                                                               handle: handle == profile.handle ? nil : handle)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }
            .onAppear { name = profile.name; handle = profile.handle }
        }
    }
}

// MARK: - People

struct ProfileScreen: View {
    let handle: String
    @Environment(SocialStore.self) private var social
    @State private var reply: SocialStore.ProfileReply?
    @State private var missing = false
    @State private var confirmBlock = false
    @State private var confirmReport = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let reply {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 64)).foregroundStyle(.secondary)
                    Text(reply.profile.name).font(.title2.bold())
                    Text("@\(reply.profile.handle)").foregroundStyle(.secondary)
                    if social.signedIn && reply.relationship != "self" { actions(reply.relationship) }
                    if let message { Text(message).font(.subheadline).foregroundStyle(.secondary) }
                } else if missing {
                    ContentUnavailableView("No one by that name", systemImage: "person.slash")
                } else {
                    ProgressView()
                }
            }
            .padding(20)
            .readableWidth()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
        .task { await load() }
        .marracatChrome()
    }

    @ViewBuilder
    private func actions(_ relationship: String) -> some View {
        switch relationship {
        case "friends":
            Button("Remove friend") { Task { await act { try await social.unfriend(handle) } } }
        case "requested":
            Button("Cancel request") { Task { await act { try await social.unfriend(handle) } } }
        case "incoming":
            HStack {
                Button("Accept") { Task { await act { try await social.befriend(handle) } } }.buttonStyle(PillButtonStyle(color: Theme.gold))
                Button("Decline") { Task { await act { try await social.unfriend(handle) } } }
            }
        case "blocked":
            Button("Unblock") { Task { await act { try await social.unblock(handle) } } }
        default:
            Button("Add friend") { Task { await act { try await social.befriend(handle) } } }
                .buttonStyle(PillButtonStyle(color: Theme.gold)).accessibilityIdentifier("addFriend")
        }
        if relationship != "blocked" {
            HStack(spacing: 20) {
                Button("Block", role: .destructive) { confirmBlock = true }
                Button("Report") { confirmReport = true }
            }
            .font(.subheadline)
            .confirmationDialog("Block @\(handle)?", isPresented: $confirmBlock, titleVisibility: .visible) {
                Button("Block", role: .destructive) { Task { await act { try await social.block(handle) } } }
            } message: { Text("You won't see each other's comments, profiles or shares, and any friendship ends.") }
            .confirmationDialog("Report @\(handle)?", isPresented: $confirmReport, titleVisibility: .visible) {
                ForEach(["Harassment or hate", "Spam or scam", "Impersonation", "Something else"], id: \.self) { reason in
                    Button(reportReasonLabel(reason)) { Task { await act { try await social.reportUser(handle, reason: reason) }; message = String(localized: "Thanks. Marracat will review this within 24 hours.", comment: "Confirmation after reporting a person") } }
                }
            }
        }
    }

    private func load() async {
        do { reply = try await social.profile(handle) } catch { missing = true }
    }
    private func act(_ work: () async throws -> Void) async {
        do { try await work(); await load() } catch { message = error.localizedDescription }
    }
}

struct FriendsScreen: View {
    @Environment(SocialStore.self) private var social
    @State private var query = ""
    @State private var results: [SocialStore.Person] = []

    var body: some View {
        List {
            Section {
                TextField("Find people by name or @handle", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("peopleSearch")
                ForEach(results) { p in
                    HStack {
                        NavigationLink(value: Route.profile(p.handle)) { person(p.name, p.handle) }
                        if p.relationship == "none" || p.relationship == "incoming" {
                            Button(p.relationship == "incoming" ? "Accept" : "Add") { Task { try? await social.befriend(p.handle); await search() } }
                                .buttonStyle(.borderless)
                        } else if p.relationship == "requested" {
                            Text("Requested").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !social.friends.incoming.isEmpty {
                Section("Requests") {
                    ForEach(social.friends.incoming, id: \.handle) { p in
                        HStack {
                            person(p.name, p.handle)
                            Button("Accept") { Task { try? await social.befriend(p.handle) } }.buttonStyle(.borderless)
                            Button("Decline") { Task { try? await social.unfriend(p.handle) } }.buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section(String(localized: "Friends", comment: "Row in the Connect screen")) {
                if social.friends.friends.isEmpty { Text("No friends yet. Search above to add some.").foregroundStyle(.secondary) }
                ForEach(social.friends.friends, id: \.handle) { p in
                    NavigationLink(value: Route.profile(p.handle)) { person(p.name, p.handle) }
                }
            }
            if !social.friends.outgoing.isEmpty {
                Section("Sent requests") {
                    ForEach(social.friends.outgoing, id: \.handle) { p in
                        HStack {
                            person(p.name, p.handle)
                            Button("Cancel") { Task { try? await social.unfriend(p.handle) } }.buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Friends", comment: "Row in the Connect screen"))
        .task { await social.reloadFriends() }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(300))
            await search()
        }
        .markRefreshable { await social.reloadFriends() }
    }

    private func search() async {
        results = query.count >= 2 ? ((try? await social.search(query)) ?? []) : []
    }
    private func person(_ name: String, _ handle: String) -> some View {
        VStack(alignment: .leading) { Text(name); Text("@\(handle)").font(.caption).foregroundStyle(.secondary) }
    }
}

struct InboxScreen: View {
    @Environment(SocialStore.self) private var social
    @Environment(CatalogStore.self) private var catalog
    @State private var reporting: SocialStore.Received?
    @State private var loaded = false

    var body: some View {
        List {
            if loaded && social.inbox.isEmpty {
                Text("When friends send you products, they'll show up here.").foregroundStyle(.secondary)
            }
            ForEach(social.inbox) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(item.share.from.name).font(.subheadline.weight(.semibold))
                        Text("· \(Date(timeIntervalSince1970: item.share.created_at / 1000).formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Menu {
                            Button { reporting = item } label: { Label("Report", systemImage: "flag") }
                        } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary) }
                    }
                    if let m = item.message {
                        if !m.note.isEmpty { Text(m.note).font(.subheadline) }
                        if let p = catalog.product(m.product_id) {
                            NavigationLink(value: Route.product(p.id)) {
                                HStack {
                                    RemoteImage(url: p.images.first, width: 120).frame(width: 56, height: 56)
                                        .background(Theme.tile).clipShape(RoundedRectangle(cornerRadius: 6))
                                    Text(p.title).font(.subheadline).lineLimit(2)
                                }
                            }
                        } else {
                            Text("That product is no longer available.").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Label("Sent before you used Marracat on this phone, so it can't be opened here.", systemImage: "lock")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle(String(localized: "Shared with you", comment: "Row in the Connect screen: products friends shared"))
        .task { await social.loadInbox(); loaded = true }
        .markRefreshable { await social.loadInbox() }
        .confirmationDialog("Report this message?", isPresented: .init(get: { reporting != nil }, set: { if !$0 { reporting = nil } }),
                            titleVisibility: .visible) {
            Button("Report", role: .destructive) {
                if let r = reporting { Task { try? await social.report(r) } }
            }
        } message: {
            Text("Messages are end-to-end encrypted. Reporting sends this one message from your phone to Marracat so it can be reviewed.")
        }
    }
}

struct BlockedScreen: View {
    @Environment(SocialStore.self) private var social

    var body: some View {
        List {
            if social.blocked.isEmpty { Text("You haven't blocked anyone.").foregroundStyle(.secondary) }
            ForEach(social.blocked, id: \.handle) { p in
                HStack {
                    VStack(alignment: .leading) { Text(p.name); Text("@\(p.handle)").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Unblock") { Task { try? await social.unblock(p.handle) } }.buttonStyle(.borderless)
                }
            }
        }
        .navigationTitle(String(localized: "Blocked", comment: "Row in the Connect screen: blocked people"))
        .task { await social.loadBlocked() }
    }
}

/// The report reasons go to the server in English (moderation reads them);
/// the shopper sees them in their language.
func reportReasonLabel(_ reason: String) -> String {
    switch reason {
    case "Harassment or hate": String(localized: "Harassment or hate", comment: "Reason for reporting a comment or person")
    case "Spam": String(localized: "Spam", comment: "Reason for reporting a comment")
    case "Sexual content": String(localized: "Sexual content", comment: "Reason for reporting a comment")
    case "Spam or scam": String(localized: "Spam or scam", comment: "Reason for reporting a person")
    case "Impersonation": String(localized: "Impersonation", comment: "Reason for reporting a person")
    case "Something else": String(localized: "Something else", comment: "Reason for reporting a comment or person")
    default: reason
    }
}
