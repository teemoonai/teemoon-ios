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
    @Environment(ChatGeneration.self) private var llm

    let platformBackgroundColor = PlatformColors.secondaryBackground

    private var chatInputField: some View {
        HStack(alignment: .bottom, spacing: 0) {
            TextField("message", text: $viewModel.prompt, axis: .vertical)
                .focused($isPromptFocused)
                .textFieldStyle(.plain)
                // Stable handle for UI tests. Looking the composer up by its
                // PLACEHOLDER worked on an empty thread and then failed on the
                // second turn — the placeholder is not an identity, it is
                // content that comes and goes.
                .accessibilityIdentifier("chat.composer")
            #if os(iOS) || os(visionOS)
                .padding(.horizontal, 16)
            #elseif os(macOS)
                .padding(.horizontal, 12)
                .onSubmit { handleShiftReturn() }
                .submitLabel(.send)
            #endif
                .padding(.vertical, 8)
            #if os(iOS) || os(visionOS)
                .frame(minHeight: 48)
            #elseif os(macOS)
                .frame(minHeight: 32)
            #endif
            #if os(iOS)
            .onSubmit {
                isPromptFocused = true
                onSend()
            }
            #endif

            if llm.running {
                stopButton
            } else {
                generateButton
            }
        }
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
        if #available(iOS 26.0, *) {
            // Liquid Glass, over a plate that actually occludes. `.regular` alone is
            // transparent enough to READ the transcript through — body text was
            // legible straight through the capsule — which then forced the bottom
            // fade to be deep enough to hide everything the capsule couldn't.
            // Claude's iOS composer is the reference: its fill blocks outright, so
            // text above it stays perfectly crisp and only the sliver below it needs
            // any treatment at all. The plate goes behind the glass so the material
            // still refracts and stays interactive.
            chatInputField
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color(.systemBackground))
                )
        } else {
            chatInputField
                .background(RoundedRectangle(cornerRadius: 24).fill(platformBackgroundColor))
        }
        #elseif os(visionOS)
        chatInputField
            .background(RoundedRectangle(cornerRadius: 24).fill(platformBackgroundColor))
        #elseif os(macOS)
        chatInputField
            .background(RoundedRectangle(cornerRadius: 16).fill(platformBackgroundColor))
        #endif
    }

    var generateButton: some View {
        Button { onSend() } label: {
            Image(systemName: "arrow.up.circle.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
            #if os(iOS) || os(visionOS)
                .frame(width: 24, height: 24)
            #else
                .frame(width: 16, height: 16)
            #endif
        }
        // NOT disabled while weights arrive. A dead button is indistinguishable
        // from a broken one: the user presses it, nothing happens, and the app
        // has declined to say why. It stays live and answers on tap, the same way
        // the no-provider and degraded-E2EE cases do.
        .disabled(viewModel.isPromptEmpty)
        .accessibilityLabel("send")
        .accessibilityIdentifier("chat.send")
        #if os(iOS) || os(visionOS)
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

    var stopButton: some View {
        Button { llm.stop() } label: {
            Image(systemName: "stop.circle.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
            #if os(iOS) || os(visionOS)
                .frame(width: 24, height: 24)
            #else
                .frame(width: 16, height: 16)
            #endif
        }
        .disabled(llm.cancelled)
        // Present exactly while a generation is running, so it is the honest
        // "is it still going?" signal for UI tests — unlike the debug card,
        // which is hidden by developer mode and by errors.
        .accessibilityIdentifier("chat.stop")
        #if os(iOS) || os(visionOS)
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
