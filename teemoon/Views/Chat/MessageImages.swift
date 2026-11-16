//
//  MessageImages.swift
//  teemoon
//
//  A message's images: a row of thumbnails in the bubble, and a full-screen viewer (IMAGES.md §5).
//  Everything shown here is teemoon's own re-encoded bytes.
//

import SwiftUI

struct MessageImagesRow: View {
    let images: [ImageAttachment]
    @State private var viewing: Int?
    @State private var saveDenied = false

    private var tileSize: CGSize { MessageImageGrid.tileSize(count: images.count) }

    private var rows: [[(Int, ImageAttachment)]] {
        MessageImageGrid.rows(count: images.count).map { $0.map { ($0, images[$0]) } }
    }

    #if os(iOS)
    @Namespace private var zoom
    @State private var zoomPage: Int?
    #endif

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    ForEach(row, id: \.0) { n, image in tile(n, image) }
                }
            }
        }
        .alert(ImageActions.deniedMessage, isPresented: $saveDenied) {}
        #if os(iOS)
        .onChange(of: viewing) { _, now in if now != nil { zoomPage = nil } }
        .fullScreenCover(item: Binding(get: { viewing.map(ViewerStart.init) }, set: { viewing = $0?.index })) { start in
            // Zooms from its thumbnail and back, as Photos and Messages (motion audit #7); the system fades instead
            // under Reduce Motion.
            ImageViewer(images: images.map(\.data), start: start.index) { zoomPage = $0 }
                .navigationTransition(.zoom(sourceID: MessageImageGrid.zoomTile(page: zoomPage ?? start.index), in: zoom))
        }
        #else
        .sheet(item: Binding(get: { viewing.map(ViewerStart.init) }, set: { viewing = $0?.index })) { start in
            ImageViewer(images: images.map(\.data), start: start.index)
                .frame(minWidth: 600, minHeight: 500)
        }
        #endif
    }

    @ViewBuilder
    private func tile(_ n: Int, _ image: ImageAttachment) -> some View {
        #if os(iOS)
        // The transcript's UIKit cells never show SwiftUI's context menu, and a Button fires on release after
        // a long press: the reply's menu hears both the tap and the press.
        thumbnail(n, image)
            .matchedTransitionSource(id: n, in: zoom)
            .accessibilityElement(children: .ignore)
            .contentShape(Rectangle())
            .modifier(ReplyActionsMenu(actions: ImageActions.menu(image.data) { saveDenied = true },
                                       onTap: { viewing = n }))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { viewing = n }
            .accessibilityLabel(MessageImageGrid.label(tile: n, count: images.count))
            .accessibilityIdentifier("chat.messageImage")
        #else
        Button { viewing = n } label: { thumbnail(n, image) }
            .buttonStyle(.plain)
            .imageActions(image.data)
            .accessibilityLabel(MessageImageGrid.label(tile: n, count: images.count))
            .accessibilityIdentifier("chat.messageImage")
        #endif
    }

    private func thumbnail(_ n: Int, _ image: ImageAttachment) -> some View {
        // One or two tiles are bigger than the stored 256 px thumbnail: draw those from the image itself.
        ThumbnailImage(data: images.count <= 2 ? image.data : image.thumbnail,
                       maxPixels: images.count <= 2 ? Int(max(tileSize.width, tileSize.height) * 3) : nil)
            .frame(width: tileSize.width, height: tileSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                if n == MessageImageGrid.shown - 1, let more = MessageImageGrid.more(count: images.count) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.black.opacity(0.45))
                    Text("+\(more)").font(.headline).foregroundStyle(.white)
                }
            }
    }

    private struct ViewerStart: Identifiable {
        let index: Int
        var id: Int { index }
    }
}

/// Full screen, swipe between the message's images, pinch to zoom, share.
struct ImageViewer: View {
    let images: [Data]
    @State var selection: Int
    /// The page showing, so the zoom closes into its own thumbnail.
    var onPage: (Int) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    init(images: [Data], start: Int, onPage: @escaping (Int) -> Void = { _ in }) {
        self.images = images
        _selection = State(initialValue: start)
        self.onPage = onPage
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $selection.onSet(onPage)) {
                ForEach(Array(images.enumerated()), id: \.offset) { n, data in
                    ZoomableImage(data: data)
                        .imageActions(data)
                        .accessibilityIdentifier("chat.viewerImage")
                        .tag(n)
                }
            }
            #if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
            #endif
            .background(Color.black)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let image = ThumbnailImage.image(images.indices.contains(selection) ? images[selection] : Data()) {
                        ShareLink(item: image, preview: SharePreview("image", image: image)) {
                            Label("share", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
    }
}

private struct ZoomableImage: View {
    let data: Data
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        Group {
            if let image = ThumbnailImage.image(data) {
                image.resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .scaleEffect(min(max(scale * pinch, 1), 6))
        .gesture(MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in scale = min(max(scale * value.magnification, 1), 6) })
        .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2.5 } }
    }
}

private extension View {
    func imageActions(_ data: Data) -> some View { modifier(ImageActionsMenu(data: data)) }
}

/// Messages' long press on an image: copy, save to Photos, share. The menu acts on the stored bytes.
private struct ImageActionsMenu: ViewModifier {
    let data: Data
    @State private var denied = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button { ImageActions.copy(data) } label: { Label("copy", systemImage: "doc.on.doc") }
                Button {
                    Task { denied = await ImageActions.save(data) == .denied }
                } label: { Label("save", systemImage: "square.and.arrow.down") }
                if let image = ThumbnailImage.image(data) {
                    ShareLink(item: image, preview: SharePreview("image", image: image)) {
                        Label("share", systemImage: "square.and.arrow.up")
                    }
                }
            } preview: {
                if let image = ThumbnailImage.image(data) {
                    image.resizable().scaledToFit()
                }
            }
            .alert(ImageActions.deniedMessage, isPresented: $denied) {}
    }
}

private extension Binding {
    /// The same binding, telling `action` each value it is set to.
    func onSet(_ action: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0; action($0) })
    }
}
