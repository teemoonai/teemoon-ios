//
//  ChatComposer.swift
//  teemoon
//

import SwiftUI

/// The chat input cluster — the text field plus the send/stop control — pulled
/// out of `ChatView`, which stays the chip/toolbar host. Layout only: the send
/// gate lives behind `onSend` (`ChatView.generate` → `ChatViewModel.prepareSend`),
/// and stop talks straight to the shared `ChatGeneration`.
struct ChatComposer: View {
    @Bindable var viewModel: ChatViewModel
    @FocusState.Binding var isPromptFocused: Bool
    /// Runs the host's send gate. The composer never decides whether a send is
    /// allowed — it only asks.
    let onSend: () -> Void
    /// "find a model that reads images": the host opens the model browser filtered to them.
    /// The where sheet with "reads images" on (§4e), from the attach sheet's "choose an image-capable model".
    var onChooseImageModel: () -> Void = {}
    /// iOS: the where and web chips, drawn in the panel's bottom row after "+" (docs/COMPOSER_PANEL.md).
    var rowChips: AnyView? = nil
    /// Lines the text grows to before it scrolls (`ComposerPanelPolicy.maxLines`).
    var maxLines = 6
    @Environment(ChatGeneration.self) private var llm
    @Environment(ProviderStore.self) private var providerStore: ProviderStore?
    @State private var choosingPhotos = false
    @State private var takingPhoto = false
    @State private var showingAttach = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    /// A thumbnail's x: it shrinks to 0.6 as it fades out, the arrival of §4d in reverse; Reduce Motion: fade only.
    private var arrival: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity)
    }
    /// Arrival and removal (§4d): the playful spring; Reduce Motion: no motion at all, as Android's "remove
    /// animations" (§4d: nothing scales or slides).
    private var thumbnailMotion: Animation? { Motion.playful(reduceMotion: reduceMotion) }
    #if os(iOS)
    /// What the attach sheet picked, run once it has gone.
    @State private var attachPick: AttachSheet.Pick?
    #endif
    @State private var cameraDenied = false
    @State private var selection: TextSelection?
    #if os(iOS)
    /// Whether the UIKit field has the keyboard (the app's FocusState only asks for it), and a counter that drops it.
    @State private var fieldFocused = false
    @Environment(ComposerFocus.self) private var composerFocus: ComposerFocus?
    @State private var resignToken = 0
    #endif

    let platformBackgroundColor = PlatformColors.secondaryBackground

    @ViewBuilder
    private var attachedImages: some View {
        if !viewModel.pendingImages.isEmpty || viewModel.imagesLoading > 0
            || (viewModel.imageNote ?? viewModel.overLimitNote) != nil {
            VStack(alignment: .leading, spacing: 6) {
                if !viewModel.pendingImages.isEmpty || viewModel.imagesLoading > 0 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            let ids = ComposerThumbnailIDs.ids(viewModel.pendingImages)
                            ForEach(Array(zip(ids, viewModel.pendingImages).enumerated()), id: \.element.0) { index, pair in
                                PendingImageThumbnail(image: pair.1) {
                                    // The arrival in reverse, the neighbours sliding over; interruptible like any.
                                    withAnimation(thumbnailMotion) { viewModel.removePendingImage(at: index) }
                                }
                                // A photo fades in over its loading tile (the maintainer 2026-11-14); its x still runs the arrival in
                                // reverse.
                                .transition(.asymmetric(insertion: AnyTransition.opacity.animation(Motion.fade),
                                                        removal: arrival))
                            }
                            // Where the loading photos will land: after the ready ones, in pick order.
                            ForEach(0..<viewModel.imagesLoading, id: \.self) { _ in
                                LoadingImageThumbnail().transition(viewModel.animatesImageArrival
                                    ? AnyTransition.opacity.animation(Motion.fade) : .identity)
                            }
                        }
                        // A share lands still (ChatViewModel.animatesImageArrival).
                        .animation(viewModel.animatesImageArrival ? thumbnailMotion : nil, value: viewModel.pendingImages.count)
                        .animation(viewModel.animatesImageArrival ? thumbnailMotion : nil, value: viewModel.imagesLoading)
                        // On the field's text inset, as Android (the maintainer 2026-11-12: the + left the field).
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        // 17 above (8 here + 9 on the stack); the text's own 17 inset is the gap below.
                        .padding(.bottom, 0)
                    }
                    .accessibilityIdentifier("chat.pendingImages")
                    // The last one gone (a send, or its x): the photos leave at once, as sent text does, and only the
                    // panel's height moves; a fade rode down with the panel (tools/measure_send_motion.py). The first
                    // one still fades in.
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
                }
                if let note = viewModel.imageNote ?? viewModel.overLimitNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        // Whole at the largest sizes, so the limit's number always shows.
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .accessibilityIdentifier("chat.imageNote")
                }
            }
            // Our own text is left-aligned (the maintainer, 2026-10-25); only system alerts centre.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 9)
            .transition(.asymmetric(insertion: .opacity, removal: .identity))
        }
    }

    #if os(iOS)
    private var imageLimit: Int {
        ChatViewModel.imagesPerSend(localModelID: providerStore?.activeProvider?.localModelID)
    }

    /// One thing on every model: the attach sheet (§4d). Tint always: a muted + read as disabled. First in the panel's
    /// bottom row (the maintainer 2026-11-12, "One panel").
    private var attachButton: some View {
        // Keyboard first, then the sheet: closing the sheet must not hand the keyboard back on the way to the where
        // sheet (the maintainer 2026-11-12; Android's order too).
        Button { ComposerTextView.dropKeyboard(); showingAttach = true } label: {
            Image(systemName: "plus").scaledFont(size: 18, weight: .semibold, relativeTo: .body)
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color(.tertiarySystemFill)))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .composerGlyph()
        .accessibilityLabel("attach images")
        .accessibilityIdentifier("chat.attach")
    }

    /// The attach sheet's line when the current model can't take images, nil when it can. A phone model that reads
    /// images but can never get the memory here says the phone can't, not the model (§4b).
    private var cantSeeLine: String? {
        guard let provider = providerStore?.activeProvider, !provider.modelSeesImages else { return nil }
        let name = WhereProviderPresentation.chipLabel(for: provider)
        if let id = provider.localModelID, PhoneImageMemory.refused(modelID: id) {
            return PhoneImageMemory.permanentLine(model: name.lowercased())
        }
        return AttachSheet.cantSee(name)
    }

    private func runAttachPick() {
        guard let pick = attachPick else { return }
        attachPick = nil
        switch pick {
        case .camera: takePhoto()
        case .photos: choosePhotos()
        case .imageModel: onChooseImageModel()
        }
    }

    private func choosePhotos() {
        if viewModel.pendingImages.count + viewModel.imagesLoading >= imageLimit {
            viewModel.imageNote = ChatViewModel.tooManyImagesMessage(limit: imageLimit)
        } else {
            choosingPhotos = true
        }
    }

    private func takePhoto() {
        guard viewModel.pendingImages.count + viewModel.imagesLoading < imageLimit else {
            viewModel.imageNote = ChatViewModel.tooManyImagesMessage(limit: imageLimit)
            return
        }
        CameraAccess.request { granted in
            if granted { takingPhoto = true } else { cameraDenied = true }
        }
    }
    #endif

    private var chatInputField: some View {
        VStack(spacing: 0) {
            attachedImages
            inputRow
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.composerCard")
        #if os(iOS)
        .sheet(isPresented: $showingAttach, onDismiss: runAttachPick) {
            AttachSheet(cantSeeLine: cantSeeLine,
                        fullNote: viewModel.pendingImages.count >= imageLimit
                            ? ChatViewModel.tooManyImagesMessage(limit: imageLimit) : nil,
                        cameraAvailable: CameraPicker.isAvailable) { pick in
                attachPick = pick
                showingAttach = false
            }
        }
        .sheet(isPresented: $choosingPhotos) {
            PhotoPicker(limit: imageLimit - viewModel.pendingImages.count - viewModel.imagesLoading) {
                viewModel.loadImages(count: $0, limit: imageLimit, $1)
            }
                .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { viewModel.loadImages(count: 1, limit: imageLimit, $0) }
                .ignoresSafeArea()
        }
        .alert(CameraAccess.deniedMessage, isPresented: $cameraDenied) {
            Button("settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("cancel", role: .cancel) {}
        }
        #endif
    }

    /// iOS: a UIKit text view, so the keyboard bar's photo, Paste and ⌘V reach paste(_:) (§4d). Elsewhere the TextField.
    @ViewBuilder
    private var field: some View {
        #if os(iOS)
        ComposerTextView(text: $viewModel.prompt,
                         focusRequest: isPromptFocused,
                         focusRequests: composerFocus?.requests ?? 0,
                         resignToken: resignToken,
                         onFocusChange: { fieldFocused = $0 },
                         caretToStart: viewModel.questionsReturned,
                         onPasteImages: { board in
                             viewModel.loadImages(count: PastedImage.imageItemCount(on: board), limit: imageLimit) {
                                 PastedImage.load(from: board, completion: $0)
                             }
                         },
                         maxLines: maxLines)
            // A send drops the keyboard, as the TextField's FocusState did: the reply starting, or the app asking.
            .onChange(of: llm.running) { _, running in if running { resignToken += 1 } }
            .onChange(of: isPromptFocused) { was, now in if was && !now { resignToken += 1 } }
        #else
        TextField("message", text: $viewModel.prompt, selection: $selection, axis: .vertical)
            .focused($isPromptFocused)
            .textFieldStyle(.plain)
            // Stable handle for UI tests. Looking the composer up by its
            // PLACEHOLDER worked on an empty thread and then failed on the
            // second turn — the placeholder is not an identity, it is
            // content that comes and goes.
            .accessibilityIdentifier("chat.composer")
        #endif
    }

    private var inputRow: some View {
        #if os(iOS)
        // The panel: the text above, one row below (+ · chips … send), the row pinned as the text grows.
        VStack(alignment: .leading, spacing: 0) {
            // 17 above the first line is the text view's own top inset (it scrolls with the text); 17 down to the row
            // is 12 here + the row items' 5 inside their hit areas.
            fieldWithBehaviour
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .frame(minHeight: 36, alignment: .bottom)
            // 34 tall items, 8 apart and 8 from the panel's edges; each in a 44 hit area that reaches 5 past it.
            HStack(spacing: -2) {
                attachButton
                if let rowChips { rowChips }
                Spacer(minLength: 0)
                // One container, so send and stop ride the row's motion; stop drew beside the photo on its own.
                // Stop takes send's place on the send frame, with no crossfade (tools/measure_send_motion.py).
                ZStack {
                    if llm.running { stopButton.transition(.identity) } else { generateButton.transition(.identity) }
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
        #else
        HStack(alignment: .bottom, spacing: 0) {
            fieldWithBehaviour
            #if os(visionOS)
                .padding(.horizontal, 16)
            #elseif os(macOS)
                .padding(.horizontal, 12)
                .onSubmit { handleShiftReturn() }
                .submitLabel(.send)
            #endif
                .padding(.vertical, 8)
            #if os(visionOS)
                .frame(minHeight: 48)
            #elseif os(macOS)
                .frame(minHeight: 32)
            #endif

            if llm.running {
                stopButton
            } else {
                generateButton
            }
        }
        #endif
    }

    @ViewBuilder
    private var fieldWithBehaviour: some View {
        field
        #if os(iOS)
            .onChange(of: viewModel.prompt) { old, _ in
                if viewModel.takeImageItemPaste(before: old, focused: fieldFocused, from: { .general },
                                                limit: imageLimit) == nil {
                    viewModel.takeDataURLPaste(before: old, limit: imageLimit)
                }
            }
            .onSubmit {
                isPromptFocused = true
                onSend()
            }
        #else
            // A returned question opens at its start: the caret at the end scrolled its first lines away at AX5.
            .onChange(of: viewModel.questionsReturned) {
                selection = TextSelection(insertionPoint: viewModel.prompt.startIndex)
            }
        #endif
    }

    // The single-turn caption used to live here, above the composer: "one
    // question at a time — this provider doesn't see the conversation above".
    //
    // It was the third telling of one fact. The Where row already says it before
    // the provider is picked, and the chip says it for as long as the provider is
    // selected — `WhereLocality` leads that caption with "single turn q&a" so the
    // chip's `.lineLimit(1)` truncates the benefit rather than the limit.
    //
    // It was also the only element in the bottom inset with no fill of its own,
    // and `ChatFadeBand.alpha` returns exactly 1 above the chip — so it printed a
    // `.secondary` caption over a transcript at FULL opacity, and the two read as
    // competing sentences. Deleting it removes the collision rather than tuning
    // the band around it, and the chrome above the chip is empty again, which is
    // what the band has always assumed.

    var body: some View {
        #if os(iOS)
        card
        #elseif os(visionOS)
        chatInputField
            .background(RoundedRectangle(cornerRadius: 24).fill(platformBackgroundColor))
        #elseif os(macOS)
        chatInputField
            .background(RoundedRectangle(cornerRadius: 16).fill(platformBackgroundColor))
        #endif
    }

    #if os(iOS)
    /// The panel's glass: photos, text and the bottom row, one surface.
    private var card: some View {
        chatInputField
            .modifier(ComposerSurface(shape: RoundedRectangle(cornerRadius: 30, style: .continuous),
                                      fallback: platformBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(PlatformColors.separator, lineWidth: 1 / displayScale))
    }
    #endif

    var generateButton: some View {
        Button { onSend() } label: {
            #if os(iOS)
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                // ML.accent, not the tint: a disabled button greys the tint, and the table says the accent at 30 %.
                .background(Circle().fill(ML.accent.opacity(sendDisabled ? 0.3 : 1)))
                // Dims on the send frame with the text, not over the send's motion (tools/measure_send_motion.py).
                .animation(nil, value: sendDisabled)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            #else
            Image(systemName: "arrow.up.circle.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
            #if os(visionOS)
                .glyphColumn(24, relativeTo: .body, square: true)
            #else
                .frame(width: 16, height: 16)
            #endif
            #endif
        }
        // NOT disabled while weights arrive. A dead button is indistinguishable
        // from a broken one: the user presses it, nothing happens, and the app
        // has declined to say why. It stays live and answers on tap, the same way
        // the no-provider and degraded-E2EE cases do.
        .disabled(sendDisabled)
        .accessibilityLabel("send")
        .accessibilityIdentifier("chat.send")
        .composerGlyph()
        #if os(iOS)
        .buttonStyle(.plain)
        #elseif os(visionOS)
            .padding(.trailing, 12)
            .padding(.bottom, 12)
        #else
            .padding(.trailing, 8)
            .padding(.bottom, 8)
        #endif
        #if os(macOS) || os(visionOS)
        .buttonStyle(.plain)
        #endif
    }

    private var sendDisabled: Bool { !viewModel.canSend }

    var stopButton: some View {
        Button { llm.stop() } label: {
            #if os(iOS)
            Image(systemName: "stop.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.primary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color(.tertiarySystemFill)))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            #else
            Image(systemName: "stop.circle.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
            #if os(visionOS)
                .glyphColumn(24, relativeTo: .body, square: true)
            #else
                .frame(width: 16, height: 16)
            #endif
            #endif
        }
        .disabled(llm.cancelled)
        .composerGlyph()
        // Present exactly while a generation is running, so it is the honest
        // "is it still going?" signal for UI tests — unlike the debug card,
        // which is hidden by developer mode and by errors.
        .accessibilityIdentifier("chat.stop")
        #if os(iOS)
        .buttonStyle(.plain)
        #elseif os(visionOS)
            .padding(.trailing, 12)
            .padding(.bottom, 12)
        #else
            .padding(.trailing, 8)
            .padding(.bottom, 8)
        #endif
        #if os(macOS) || os(visionOS)
        .buttonStyle(.plain)
        #endif
    }

    #if os(macOS)
    private func handleShiftReturn() {
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            viewModel.prompt.append("\n")
            isPromptFocused = true
        } else {
            onSend()
        }
    }
    #endif
}

/// One attached image in the composer, with its remove button. Shows teemoon's own thumbnail.
private struct PendingImageThumbnail: View {
    let image: ImageIntake.Image
    let remove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // The identifier sits on the 64 pt base: the filled image's own frame is its unclipped size (85 × 64 at 4:3).
            Color.clear
                .frame(width: 64, height: 64)
                .accessibilityElement()
                .accessibilityIdentifier("chat.pendingImage")
                .overlay { ThumbnailImage(data: image.thumbnail).accessibilityHidden(true) }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.black.opacity(0.85)))
                    .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                    .frame(width: 44, height: 44, alignment: .topTrailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The 44 pt target reaches into the thumbnail; the row's top padding keeps the circle unclipped.
            .offset(x: 8, y: -8)
            .accessibilityLabel("remove image")
        }
    }
}

/// A photo still loading, where its thumbnail will land; PendingImageThumbnail's size and shape.
private struct LoadingImageThumbnail: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.secondary.opacity(0.15))
            .frame(width: 64, height: 64)
            .overlay { ProgressView().controlSize(.small).tint(.secondary) }
            .accessibilityElement()
            .accessibilityLabel("loading image")
            .accessibilityIdentifier("chat.loadingImage")
    }
}

private extension View {
    /// The composer's glyph buttons grow with the text up to the chips' cap, then show large on a long press.
    func composerGlyph() -> some View {
        dynamicTypeSize(...ControlMetrics.pillLargestTextSize).accessibilityShowsLargeContentViewer()
    }



}

#if os(iOS)
/// The composer's surfaces (the field and the "+" circle): Liquid Glass over a plate that actually occludes. `.regular`
/// alone is transparent enough to read the transcript through. Not `.interactive()`: interactive glass takes every tap
/// inside its shape, so a tall composer's menus stopped working.
struct ComposerSurface<S: Shape>: ViewModifier {
    let shape: S
    let fallback: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // A tinted surface under the glass, so nothing reads through the panel; Reduce Transparency gets the opaque
            // plate (card ios-composer-glass).
            content
                .glassEffect(.regular, in: shape)
                .background(shape.fill(reduceTransparency ? Color(.systemBackground)
                                       : Color(.secondarySystemBackground).opacity(ChatGlassFade.panelFill)))
        } else {
            content.background(shape.fill(fallback))
        }
    }
}
#endif
