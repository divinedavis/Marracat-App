import SwiftUI
import PhotosUI

/// The Saved tab, wishlist-style: folders in a two-column grid, each fronted
/// by a photo. "All saved" and "Recently viewed" are made by the app; the
/// rest are the shopper's own, with a cover they choose.
struct SavedView: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(ShopperStore.self) private var shopper
    @Environment(AppNav.self) private var nav
    @State private var editing = false
    @State private var creating = false
    @State private var renaming: SavedList?
    @State private var deleting: SavedList?
    /// The floating bar's search: only what's saved and the lists' names.
    @State private var query = ""

    var body: some View {
        let saved = shopper.saved.compactMap(catalog.product)
        let recent = shopper.recentlyViewed.compactMap(catalog.product)
        if saved.isEmpty && recent.isEmpty && shopper.lists.isEmpty {
            empty
        } else {
            ScrollView {
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    results
                } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Saved").brandFont(.largeTitle.bold())
                        Spacer()
                        Button(editing ? "Done" : "Edit") { withAnimation { editing.toggle() } }
                            .brandFont(.subheadline.bold())
                            .accessibilityIdentifier("savedEdit")
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14, alignment: .top)], spacing: 22) {
                        if !saved.isEmpty {
                            NavigationLink(value: Route.saved) {
                                FolderCard(name: String(localized: "All saved", comment: "Folder of every saved product"), count: saved.count, images: [saved.first?.images.first])
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("savedFolderAll")
                        }
                        if !recent.isEmpty {
                            NavigationLink(value: Route.recentlyViewed) {
                                FolderCard(name: String(localized: "Recently viewed", comment: "Folder of recently viewed products"), count: nil, subtitle: String(localized: "Where you've been", comment: "Subtitle of the Recently viewed folder"),
                                           images: recent.prefix(4).map { $0.images.first })
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("savedFolderRecent")
                        }
                        ForEach(shopper.lists) { list in
                            ZStack(alignment: .topTrailing) {
                                NavigationLink(value: Route.savedFolder(list.id)) {
                                    FolderCard(name: list.name, count: list.items.count,
                                               images: [FolderCover.imageURL(list, catalog: catalog)],
                                               localPhoto: list.cover == "photo" ? CoverPhotos.image(list.id) : nil)
                                }
                                .buttonStyle(.plain)
                                .disabled(editing)
                                .accessibilityIdentifier("savedFolder")
                                if editing {
                                    Menu {
                                        Button("Rename") { renaming = list }
                                        Button("Delete", role: .destructive) { deleting = list }
                                    } label: {
                                        Image(systemName: "ellipsis.circle.fill")
                                            .brandFont(.title2).foregroundStyle(.white, Color.black.opacity(0.6))
                                            .padding(8)
                                    }
                                    .accessibilityIdentifier("savedFolderMenu")
                                }
                            }
                        }
                        Button { creating = true } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                RoundedRectangle(cornerRadius: 16)
                                    .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay { Image(systemName: "plus").brandFont(.title).foregroundStyle(Theme.secondary) }
                                Text("New list").brandFont(.subheadline.bold())
                                Text("Group what you save").brandFont(.caption).foregroundStyle(Theme.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("newList")
                    }
                }
                .padding(16)
                .padding(.bottom, 20)
                }
            }
            .background(Theme.canvas)
            .sheet(isPresented: $creating) { NewListSheet() }
            .sheet(item: $renaming) { list in NewListSheet(renaming: list) }
            .alert("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Delete list", role: .destructive) { if let d = deleting { shopper.deleteList(d.id) }; deleting = nil }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: { Text("The items stay in All saved.") }
            .marracatChrome(localSearch: LocalSearch(text: $query,
                                                     prompt: String(localized: "Search saved", comment: "Search field placeholder on the Saved tab"),
                                                     identifier: "savedSearch"), hidesBar: true)
        }
    }

    /// While searching: the lists whose names match, then the saved items
    /// (in All saved or any list) whose name or brand does.
    private var results: some View {
        let found = SavedSearch.matches(query, lists: shopper.lists, saved: shopper.saved, catalog: catalog)
        return VStack(alignment: .leading, spacing: 14) {
            if found.lists.isEmpty && found.products.isEmpty {
                Text("Nothing saved matches “\(query)”.", comment: "Saved search found nothing; the argument is what the shopper typed")
                    .brandFont(.subheadline).foregroundStyle(Theme.secondary)
                    .padding(16)
                    .accessibilityIdentifier("savedSearchEmpty")
            }
            if !found.lists.isEmpty {
                Text("Lists", comment: "Saved search results heading").brandFont(.headline).padding(.horizontal, 16)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14, alignment: .top)], spacing: 22) {
                    ForEach(found.lists) { list in
                        NavigationLink(value: Route.savedFolder(list.id)) {
                            FolderCard(name: list.name, count: list.items.count,
                                       images: [FolderCover.imageURL(list, catalog: catalog)],
                                       localPhoto: list.cover == "photo" ? CoverPhotos.image(list.id) : nil)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("savedFolder")
                    }
                }
                .padding(.horizontal, 16)
            }
            if !found.products.isEmpty {
                Text("Items", comment: "Saved search results heading").brandFont(.headline).padding(.horizontal, 16)
                ProductGrid(products: found.products)
            }
        }
        .padding(.top, 16)
    }

    private var empty: some View {
        ScrollView {
            VStack(spacing: 14) {
                ArtIcon(name: "lists", symbol: ListsIcon.name, size: 64, tint: Theme.amber).brandFont(.system(size: 44))
                Text("Don't lose your finds").brandFont(.title3.bold()).accessibilityIdentifier("savedEmpty")
                Text("Tap “Add to List” on any item to save it here, so it's easy to come back to.")
                    .brandFont(.subheadline).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                Button("Start shopping") { nav.tab = .home }
                    .buttonStyle(PillButtonStyle(color: Theme.gold)).frame(maxWidth: 260).padding(.top, 6)
            }
            .padding(32).frame(maxWidth: .infinity).padding(.top, 60)
        }
        .background(Theme.canvas)
        .marracatChromeHidden()
    }
}

/// The Saved tab's search (owner, 2026-10-20): only what the shopper saved.
enum SavedSearch {
    @MainActor
    static func matches(_ query: String, lists: [SavedList], saved: [String],
                        catalog: CatalogStore) -> (lists: [SavedList], products: [Product]) {
        let words = SearchWords.fold(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return ([], []) }
        func hit(_ text: String) -> Bool {
            let t = SearchWords.fold(text)
            return words.allSatisfy { t.contains($0) }
        }
        var seen = Set<String>()
        let ids = (saved + lists.flatMap(\.items)).filter { seen.insert($0).inserted }
        let products = ids.compactMap(catalog.product).filter { p in
            hit(p.title + " " + (catalog.brand(p.brand)?.name ?? ""))
        }
        return (lists.filter { hit($0.name) }, products)
    }
}

/// A folder in the grid: a square photo (or a 2×2 collage, or a heart when
/// empty), the name, and how many are in it.
struct FolderCard: View {
    let name: String
    let count: Int?
    var subtitle: String? = nil
    var images: [String?] = []
    var localPhoto: UIImage? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(Theme.tile)
                if let localPhoto {
                    Image(uiImage: localPhoto).resizable().scaledToFill()
                } else {
                    let urls = images.compactMap { $0 }
                    if urls.count >= 4 {
                        VStack(spacing: 2) {
                            HStack(spacing: 2) { tile(urls[0]); tile(urls[1]) }
                            HStack(spacing: 2) { tile(urls[2]); tile(urls[3]) }
                        }
                    } else if let first = urls.first {
                        RemoteImage(url: first, width: 400).padding(10)
                    } else {
                        Image(systemName: ListsIcon.name).brandFont(.system(size: 40)).foregroundStyle(Color.black.opacity(0.35)).accessibilityHidden(true)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.hairline, lineWidth: 0.5))
            Text(name).brandFont(.subheadline.bold()).lineLimit(1)
            if let subtitle {
                Text(subtitle).brandFont(.caption).foregroundStyle(Theme.secondary)
            } else if let count {
                Text(count == 0 ? "Nothing saved yet" : "\(count) saved").brandFont(.caption).foregroundStyle(Theme.secondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name)\(count.map { ", \($0) saved" } ?? "")")
    }

    private func tile(_ url: String) -> some View {
        Theme.tile.overlay { RemoteImage(url: url, width: 200).padding(4) }.clipped()
    }
}

enum FolderCover {
    /// The photo that fronts a folder: its chosen product, else its newest item.
    static func imageURL(_ list: SavedList, catalog: CatalogStore) -> String? {
        if let cover = list.cover, cover != "photo", let p = catalog.product(cover) { return p.images.first }
        return list.items.lazy.compactMap { catalog.product($0)?.images.first }.first
    }
}

/// One folder: its items, and the cover to change.
struct FolderView: View {
    let listID: String
    @Environment(CatalogStore.self) private var catalog
    @Environment(ShopperStore.self) private var shopper
    @Environment(\.dismiss) private var dismiss
    @State private var choosingCover = false
    @State private var renaming = false
    @State private var confirmDelete = false

    var body: some View {
        if let list = shopper.list(listID) {
            let products = list.items.compactMap(catalog.product)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12).fill(Theme.tile)
                            if list.cover == "photo", let img = CoverPhotos.image(list.id) {
                                Image(uiImage: img).resizable().scaledToFill()
                            } else if let url = FolderCover.imageURL(list, catalog: catalog) {
                                RemoteImage(url: url, width: 240).padding(6)
                            } else {
                                Image(systemName: ListsIcon.name).foregroundStyle(Color.black.opacity(0.35)).accessibilityHidden(true)
                            }
                        }
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(list.name).brandFont(.title2.bold()).lineLimit(2)
                            Text(products.isEmpty ? "Nothing saved yet" : "\(products.count) saved").brandFont(.subheadline).foregroundStyle(Theme.secondary)
                            Button("Change cover") { choosingCover = true }
                                .brandFont(.subheadline.bold())
                                .disabled(products.isEmpty)
                                .accessibilityIdentifier("changeCover")
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    if products.isEmpty {
                        Text("Save something to this list from any product page: “Save to a list”.")
                            .brandFont(.subheadline).foregroundStyle(Theme.secondary).padding(.horizontal, 12)
                    } else {
                        ProductGrid(products: products)
                    }
                }
                .padding(.bottom, 20)
            }
            .background(Theme.canvas)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Rename") { renaming = true }
                        Button("Change cover") { choosingCover = true }.disabled(products.isEmpty)
                        Button("Delete list", role: .destructive) { confirmDelete = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityIdentifier("folderMenu")
                }
            }
            .sheet(isPresented: $choosingCover) { CoverPickerSheet(list: list) }
            .sheet(isPresented: $renaming) { NewListSheet(renaming: list) }
            .alert("Delete “\(list.name)”?", isPresented: $confirmDelete) {
                Button("Delete list", role: .destructive) { shopper.deleteList(list.id); dismiss() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("The items stay in All saved.") }
            .marracatChrome()
        } else {
            ContentUnavailableView("This list is gone", systemImage: ListsIcon.name).marracatChrome()
        }
    }
}

/// Pick the folder's cover: any item's photo, a picture from the library
/// (kept on this device), or the newest item's photo again.
struct CoverPickerSheet: View {
    let list: SavedList
    @Environment(CatalogStore.self) private var catalog
    @Environment(ShopperStore.self) private var shopper
    @Environment(\.dismiss) private var dismiss
    @State private var picked: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PhotosPicker(selection: $picked, matching: .images) {
                        Label("Choose from Photos", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle(color: Theme.gold))
                    .accessibilityIdentifier("coverFromPhotos")
                    Text("Or a photo from this list").brandFont(.subheadline.bold())
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                        ForEach(list.items.compactMap(catalog.product)) { p in
                            Button {
                                CoverPhotos.remove(list.id)
                                shopper.setCover(p.id, for: list.id)
                                dismiss()
                            } label: {
                                ZStack(alignment: .topTrailing) {
                                    Theme.tile.overlay { RemoteImage(url: p.images.first, width: 240).padding(6) }
                                        .aspectRatio(1, contentMode: .fit)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                    if list.cover == p.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.white, .black).padding(6)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(p.title)
                            .accessibilityIdentifier("coverOption")
                        }
                    }
                    if list.cover != nil {
                        Button("Use the newest item's photo") {
                            CoverPhotos.remove(list.id)
                            shopper.setCover(nil, for: list.id)
                            dismiss()
                        }
                        .brandFont(.subheadline)
                    }
                }
                .padding(16)
            }
            .background(Theme.canvas)
            .barTitle("Cover photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onChange(of: picked) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data), let jpeg = Self.downsized(image).jpegData(compressionQuality: 0.85) {
                        CoverPhotos.save(jpeg, for: list.id)
                        shopper.setCover("photo", for: list.id)
                    }
                    dismiss()
                }
            }
        }
        .accessibilityIdentifier("coverPicker")
    }

    /// A cover is shown small; a full-resolution library photo is wasted disk.
    private static func downsized(_ image: UIImage, max: CGFloat = 800) -> UIImage {
        let scale = min(1, max / Swift.max(image.size.width, image.size.height))
        guard scale < 1 else { return image }
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

/// Name a new list, or rename one.
struct NewListSheet: View {
    var renaming: SavedList? = nil
    /// Called with the new list's id, for "make a list and put this in it".
    var onCreated: ((String) -> Void)? = nil
    @Environment(ShopperStore.self) private var shopper
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("e.g. Gifts, Skincare, Summer"))
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .accessibilityIdentifier("listNameField")
                } footer: { Text("Up to 40 characters.").foregroundStyle(Theme.secondary) }
            }
            .barTitle(renaming == nil ? "New list" : "Rename list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(renaming == nil ? "Create" : "Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("listNameSave")
                }
            }
            .onAppear { name = renaming?.name ?? ""; focused = true }
        }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if let renaming { shopper.renameList(renaming.id, to: name) }
        else if let id = shopper.createList(named: name) { onCreated?(id) }
        dismiss()
    }
}

/// From a product page: tick the lists this item belongs in, or start one.
struct SaveToListSheet: View {
    let productID: String
    @Environment(ShopperStore.self) private var shopper
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { creating = true } label: {
                        Label("New list", systemImage: "plus.circle").brandFont(.subheadline.bold())
                    }
                    .accessibilityIdentifier("newListFromProduct")
                }
                if !shopper.lists.isEmpty {
                    TitledSection("Your lists") {
                        ForEach(shopper.lists) { list in
                            let inList = list.items.contains(productID)
                            Button {
                                if inList { shopper.remove(productID, from: list.id) } else { shopper.add(productID, to: list.id) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(list.name).foregroundStyle(.primary)
                                        Text(list.items.isEmpty ? "Nothing saved yet" : "\(list.items.count) saved").brandFont(.caption).foregroundStyle(Theme.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: inList ? "checkmark.circle.fill" : "circle").foregroundStyle(.primary)
                                }
                            }
                            .accessibilityIdentifier("listRow")
                            .accessibilityValue(inList ? "in list" : "not in list")
                        }
                    }
                }
            }
            .barTitle("Save to a list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("saveToListDone") } }
            .sheet(isPresented: $creating) {
                NewListSheet { id in shopper.add(productID, to: id) }
            }
        }
        .accessibilityIdentifier("saveToListSheet")
    }
}
