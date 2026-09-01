//
//  TrustLadderView+None.swift
//  teemoon
//

import SwiftUI

extension TrustLadderView {
    // MARK: on device (nothing to attest, because nothing is sent)

    var isOnDevice: Bool {
        providerStore.activeProvider?.isLocal == true
    }

    /// Shown when the model runs on this phone.
    ///
    /// The generic not-attestable copy was rendering here, and every line of it
    /// was false — not merely unhelpful:
    ///
    ///   - "standard HTTPS protects your messages on the way to Gemma 4 E2B" —
    ///     there is no way to it and no HTTPS. Nothing leaves the device.
    ///   - "Gemma 4 E2B can read your messages" — the model is a file in this
    ///     app's container. There is no operator behind it to read anything.
    ///   - "teemoon can't prove where this runs" — it runs here, which is the one
    ///     claim on this screen that needs no proof at all.
    ///
    /// And it offered "choose an end-to-end encrypted model", which would move
    /// the user OFF the most private option teemoon has and onto someone else's
    /// hardware. Same argument as `selfHostedView`, one step stronger: there
    /// isn't even a network hop to describe.
    ///
    /// Deliberately the same SHAPE as `selfHostedView` — hero, one evidence card,
    /// no rung picker. These are the two "nothing to attest because there is
    /// nobody to attest to" states and they should read as siblings; the ladder
    /// adds technical depth to a PROOF, and neither of these has one to descend
    /// into.
    ///
    /// Like home, it closes on one honest limit rather than a wall of green. The
    /// limit is the attestation one, not an at-rest-encryption lecture: this
    /// screen answers "who else can read this", the answer is nobody remote, and
    /// what's missing is a proof you could show a third party.
    var onDeviceView: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "lock.iphone")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(teeVerified)
                Text("nothing leaves this phone")
                    .font(.title.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("attestation.onDevice.hero")
                Text("\(modelName) runs on this device. your messages are answered here, so there is no server to trust and no network to protect them on.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            EvidenceCard(title: "what this means",
                         subtitle: "the whole picture — nothing hidden.") {
                noneRow("checkmark.circle.fill", teeVerified,
                        "your messages never leave the phone",
                        "the model is a file on this device and teemoon runs it here. nothing about this chat is transmitted, so there is nothing in transit to intercept.")
                noneRow("checkmark.circle.fill", teeVerified,
                        "no operator to trust",
                        "there is no company on the other end of this chat, because there is no other end. nobody is metering it and nobody could be asked to hand it over.")
                noneRow("checkmark.circle.fill", teeVerified,
                        "works with the network off",
                        "airplane mode changes nothing here — which is the plainest proof that nothing is leaving.")
                // No "not cryptographically attested" row, unlike home. Attestation
                // exists to answer "can I trust a machine I don't control", and
                // there is no such machine here — so listing its absence invents a
                // shortfall against a bar this state doesn't need to clear. Home
                // keeps the row because there IS a remote host there, even if it's
                // yours.
            }
        }
    }


    // MARK: self-hosted (nothing to attest, because there is no one to attest to)

    /// True when the active provider points at a machine on the user's own
    /// network — loopback, LAN, link-local, or a Tailscale/`.local` name.
    var isSelfHosted: Bool {
        providerStore.activeProvider?.isSelfHosted == true
    }

    /// Whether the hop to that machine is itself encrypted. Tailscale serve gives
    /// https; a plain LAN box is usually http, and saying "encrypted in transit"
    /// there would be a lie.
    var selfHostedUsesTLS: Bool {
        providerStore.activeProvider?.openAIBaseURL?.scheme?.lowercased() == "https"
    }

    /// Shown when the model runs on hardware the user controls. The generic
    /// not-attestable copy is actively WRONG here: it says "<provider> can read
    /// your messages" (the provider is your own computer), and "teemoon can't
    /// prove where this runs" (you started it). Framing the most private option
    /// teemoon supports with the warning built for the least private one is
    /// backwards, so this states what is actually true.
    ///
    /// No rung picker: the ladder exists to add technical depth to a proof, and
    /// there is no proof here to go deeper into.
    ///
    /// The machine's name is deliberately never printed — it is a personal
    /// hostname and this screen gets screenshotted.
    var selfHostedView: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "lock.laptopcomputer")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(teeVerified)
                Text("on your own machine")
                    .font(.title.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("attestation.selfHosted.hero")
                Text("this model runs on hardware you control. teemoon talks to it directly — no company sits in the middle.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            EvidenceCard(title: "what this means",
                         subtitle: "the whole picture — nothing hidden.") {
                noneRow("checkmark.circle.fill", teeVerified,
                        "your messages don't leave your network",
                        "teemoon sends them straight to your own server, over your local network or tailnet. no third party receives them.")
                noneRow("checkmark.circle.fill", teeVerified,
                        "no operator to trust",
                        "there is no provider here who could read your chats. the only party with access is you, on the machine serving the model.")
                if selfHostedUsesTLS {
                    noneRow("checkmark.circle.fill", teeVerified,
                            "encrypted in transit",
                            "the connection to your server uses https, so the hop across your network is protected too.")
                } else {
                    noneRow("minus.circle", .secondary,
                            "not encrypted in transit",
                            "the connection to your server is plain http. that is usually fine on a network you own, but anyone else on it could read the traffic.")
                }
                noneRow("minus.circle", .secondary,
                        "not cryptographically attested",
                        "teemoon can't prove which binary is running, the way it can inside a sealed enclave. you control the machine, so you may not need that — but there is no proof here you could show someone else.")
            }
        }
    }


    // MARK: not attestable (honest .none — never a fabricated chain)

    /// Shown when there's nothing to attest: a non-attestation provider, or a
    /// near.ai model with no confidential endpoint (e.g. a retired model). It
    /// states the truth — not end-to-end encrypted, the provider can read it —
    /// instead of the ladder, which would imply a proof that doesn't exist.
    var notAttestableView: some View {
        VStack(alignment: .leading, spacing: 22) {
            // Hero — calm and honest. An open lock, never a shield: there is no
            // protection here to imply.
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "lock.open")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("not end-to-end encrypted")
                    .font(.title.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(notAttestableLead)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsRungPicker { RungPicker(rung: $rung) }

            // The honest split: the one real guarantee (transit) with a green
            // check, and what's absent with a neutral grey minus — never a red
            // alarm. This is a limitation of the chosen model, not a breach.
            EvidenceCard(title: "what this means",
                         subtitle: "the whole picture — nothing hidden.") {
                noneRow("checkmark.circle.fill", teeVerified,
                        "still encrypted in transit",
                        "standard HTTPS protects your messages on the way to \(providerDisplayName) — like any secure site.")
                noneRow("minus.circle", .secondary,
                        "not end-to-end to a sealed model",
                        "\(providerDisplayName) can read your messages — nothing seals them so that only the model can open them.")
                noneRow("minus.circle", .secondary,
                        "nothing to cryptographically verify",
                        "there's no hardware attestation, so teemoon can't prove where this runs or who can see it.")
            }

            // near.ai-specific: make clear this isn't teemoon failing — the model
            // simply isn't offered confidentially.
            if session.noConfidentialEndpoint {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle").font(.footnote)
                        .foregroundStyle(.tertiary).frame(width: 18)
                    Text("near.ai runs many models inside sealed hardware — \(modelName) just isn't one of them. It's served as an ordinary model, not a confidential one.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Expert: the technical reason there's nothing to attest.
            if rung == .expert {
                EvidenceCard(title: "why there's nothing to attest",
                             subtitle: "the technical reason, for the record.") {
                    trustRow("network", "no confidential endpoint — this model has no entry in near.ai's `/endpoints` directory, so there's no sealed host to reach.")
                    trustRow("cpu", "no enclave quote — without a direct host there's no Intel TDX / NVIDIA GPU quote to verify.")
                    trustRow("lock.open", "transport only — the connection is TLS to the gateway/proxy, not end-to-end encrypted to a model key.")
                }
            }

            // Constructive, low-key path forward: opens the model browser
            // filtered to attestable (confidential) models; picking one switches
            // the session onto it and re-verifies. Hidden when no near.ai
            // provider is configured — there'd be nothing actionable to offer.
            if nearAIProvider != nil {
                Button { showEncryptedModelPicker = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.shield.fill")
                        Text("choose an end-to-end encrypted model")
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.right")
                    }
                    .font(.callout.weight(.medium))
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(teeVerifiedSoft, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(teeVerified)
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showEncryptedModelPicker) {
                    ModelBrowserView(selectedModel: $pickedEncryptedModel,
                                     models: encryptedModelChoices,
                                     onSelect: selectEncryptedModel,
                                     showsConfidentialityTags: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The near.ai provider the "choose an encrypted model" pick applies to:
    /// the active one if it's near.ai, else the first configured near.ai
    /// provider. nil when none exists (CTA hidden — nothing actionable).
    var nearAIProvider: Provider? {
        if let p = providerStore.activeProvider, p.endpoint.contains("near.ai") { return p }
        return providerStore.providers.first { $0.endpoint.contains("near.ai") }
    }

    /// E2EE-capable choices only. `isAttestable` is NOT sufficient here:
    /// near.ai's `attested 3p` tier (Chutes hardware — deepseek-v3.2, kimi,
    /// minimax…) passes it, but near.ai exposes no confidential endpoint for
    /// them — no E2EE path via near.ai — so offering them under "choose an end-to-end encrypted
    /// model" would be the exact overclaim this screen exists to avoid. The
    /// hard requirement is a direct TEE host (`directBaseURL`) — that host is
    /// where the Ed25519 key binding comes from, so it is precisely "E2EE
    /// works." Anonymous-proxy and attested-3p tiers can never satisfy it.
    var encryptedModelChoices: [KnownModel] {
        KnownModel.nearAIModels.filter {
            $0.directBaseURL != nil
                && NearAIModelCatalog.isAttestable($0.id)
                && !NearAIModelCatalog.isNonChat($0.id)
        }
    }

    /// Applies the pick: point the near.ai provider at the chosen model,
    /// make it active, and re-verify — the sheet re-renders into the live
    /// verifying → verified chain for the new model.
    func selectEncryptedModel(_ model: KnownModel) {
        guard var p = nearAIProvider else { return }
        p.model = model.id
        providerStore.updateProvider(p)
        providerStore.currentProviderID = p.id.uuidString
        session.refreshAttestation()
    }

    var notAttestableLead: String {
        if session.noConfidentialEndpoint {
            return "\(modelName) isn't served inside a sealed enclave, so this chat can't be end-to-end encrypted."
        }
        return "\(providerDisplayName) doesn't offer hardware attestation, so this chat can't be end-to-end encrypted to a sealed model."
    }

    func noneRow(_ icon: String, _ tint: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.body).foregroundStyle(tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout).fontWeight(.medium)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }


}
