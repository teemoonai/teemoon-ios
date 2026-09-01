//
//  WhereSheetView+FirstRun.swift
//  teemoon
//

import SwiftUI

extension WhereSheetView {
    // MARK: - First run

    /// Empty `all` with a recommended download. Decode failure and offline win.
    /// See WhereGetPolicyTests.
    var showsFirstRun: Bool {
        getPolicy.showsFirstRun(
            loadFailed: providerStore.loadFailure != nil,
            recommended: recommendedPhoneModel
        )
    }

    var recommendedPhoneModel: LocalModel? {
        WhereGetPolicy.recommendedPhoneModel(availableMB: LocalMemory.availableMB())
    }

    @ViewBuilder
    var firstRunSections: some View {
        if let model = recommendedPhoneModel {
            Section {
                firstRunHero(model)
                    .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            } header: {
                Text("start here")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
                    .padding(.bottom, 6)
            }

            Section {
                // The two alternatives, as rows rather than heroes. Nobody
                // picks Fireworks on their first screen, so the four cloud
                // vendors collapse into one destination.
                // `AddTarget` already distinguishes these two destinations —
                // the same one the `get` list uses — so first run lands on the
                // identical screen rather than a parallel entry point.
                // `.plain`, so only the ICON carries the tint. A Button inside a
                // List tints its whole label by default, which turned the
                // subtitles blue — and a caption in accent colour reads as a
                // second link rather than as description. The `get` rows above
                // have always done it this way.
                firstRunPlaceRow(
                    title: "connect a computer",
                    subtitle: "ollama, lmstudio, llama.cpp or any llm engine",
                    glyph: WhereLocality.home.systemImage
                ) { addTarget = .selfHosted }

                firstRunPlaceRow(
                    title: "use a cloud api",
                    subtitle: "your key · near.ai, grok, fireworks, custom",
                    glyph: WhereLocality.cloud.systemImage
                ) { addTarget = .cloudKey }
            } header: {
                Text("other places")
                    .textCase(.lowercase)
            } footer: {
                Text("whichever you pick, you can switch per message afterwards.")
                    .textCase(.lowercase)
            }
        }
    }

    func firstRunPlaceRow(
        title: String, subtitle: String, glyph: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: glyph)
                    .font(.body)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .textCase(.lowercase)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func firstRunHero(_ model: LocalModel) -> some View {
        // Weights on disk with nothing configured — the state a phone reaches
        // by emptying its provider list, or by installing over an existing
        // container. Offering a 2.4 GB download for a file already present is
        // the kind of wrong that costs the user three minutes to discover.
        let alreadyHere = isInstalled(model)
        return VStack(alignment: .leading, spacing: 0) {
            Text("free · nothing leaves \(DeviceNoun.boundary)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .textCase(.lowercase)
            Text(model.displayName.lowercased())
                .font(.title3.weight(.bold))
                .padding(.top, 8)
            Text(model.blurb.lowercased())
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            // `startAndSelect`, not `downloader.start`. The first draft called
            // the downloader alone, which created no provider and activated
            // nothing — the bytes would land and the user would still have an
            // empty setup, having pressed the one button on the screen.
            //
            // It is also the right call when the bundle is ALREADY on disk: a
            // phone that has downloaded gemma but has no provider configured
            // (an emptied provider list, or a reinstall over an existing
            // container) must be offered the model, not offered to fetch it
            // again. `startAndSelect` equips first and the download is a no-op.
            // Contrast is explicit, NOT `.borderedProminent`.
            //
            // That style fills with the app tint and picks a label colour
            // itself — and teemoon lets the user choose the tint
            // (`settings.appTintColor`, applied app-wide in ContentView). On a
            // fresh install the default resolved to white, so the button
            // rendered as a white capsule with a white label: a blank pill, the
            // primary control on the first screen, invisible. The Xcode preview
            // uses the stock blue accent and showed nothing wrong.
            //
            // `systemBackground` as the foreground inverts against whatever the
            // tint is, so the label stays legible for all thirteen choices.
            Button {
                startAndSelect(model)
            } label: {
                Label(alreadyHere
                      ? "use \(model.displayName.lowercased())"
                      : "download · \(model.sizeMB / 1000).\((model.sizeMB % 1000) / 100) gb",
                      systemImage: alreadyHere ? "checkmark.circle" : "arrow.down.circle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(PlatformColors.background)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .textCase(.lowercase)
                    .background(Capsule(style: .continuous).fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .padding(.top, 16)
            .accessibilityIdentifier("where.firstRun.download")

            Text(alreadyHere ? "already downloaded · runs offline" : downloadEstimate(model))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .textCase(.lowercase)
        }
    }

    /// A rough wall-clock figure for the download, derived rather than written
    /// down, so it follows the catalogue if the recommended bundle changes.
    ///
    /// Assumes ~100 Mbit/s — an ordinary home wi-fi link, and the figure the
    /// design's "about 3 minutes" implies for a 2.4 GB bundle. It is stated as
    /// "about", on wi-fi, because the honest error bars are large: the same
    /// bundle is ~25 minutes on a 15 Mbit/s connection. Deliberately NOT
    /// measured from the live link — a number that moved while the user read it
    /// would be worse than one that is openly approximate.
    func downloadEstimate(_ model: LocalModel) -> String {
        let megabitsPerSecond = 100.0
        let seconds = Double(model.sizeMB) * 8.0 / megabitsPerSecond
        let minutes = max(1, Int((seconds / 60).rounded()))
        return minutes == 1
            ? "about a minute on wi-fi"
            : "about \(minutes) minutes on wi-fi"
    }

    var emptyTitle: String { getPolicy.emptyTitle }

    var emptyGlyph: String { getPolicy.emptyGlyph }

    var emptyDescription: String { getPolicy.emptyDescription(openToGet: openToGet) }

    /// "ready now", in every tier.
    ///
    /// Cloud used to say "your setups" to avoid implying the whole catalog was
    /// listed. That worry belonged to the provider-shaped sheet: now that rows
    /// are models, a cloud row is as ready to run as a downloaded one, and two
    /// names for one list only asks the reader to work out whether the
    /// difference means something.
    var readyHeader: String { "ready now" }

    @ViewBuilder
    var readySection: some View {
        let rows = equippedRows
        if rows.isEmpty {
            Section {
                // A DECODE FAILURE MUST NOT PRESENT AS "NO SETUPS".
                //
                // If the stored
                // config can't be read, the list is empty for a reason that has
                // nothing to do with what the user configured — and the empty
                // state below would tell someone with four keys saved to go add
                // one, which is both wrong and the worst possible advice: adding
                // is what overwrites the file we failed to read.
                //
                // Says the data is still on the device, because it is: the v1
                // blob is frozen and the unreadable file is quarantined beside
                // it rather than deleted.
                //
                // An earlier draft told the user "don't re-add them yet; that
                // would overwrite it". Both halves were wrong. The bad file is
                // already moved aside by the time this renders, so adding
                // destroys nothing — and `get` sits directly below this text
                // offering exactly the thing it forbade.
                if let failure = providerStore.loadFailure {
                    ContentUnavailableView {
                        Label("couldn't read your setups", systemImage: "exclamationmark.triangle")
                    } description: {
                        VStack(spacing: 8) {
                            Text("your setups are still on this device — teemoon couldn't open the file that lists them, and has kept a copy of it. reopening the app may be enough.")
                                .textCase(.lowercase)
                            Text(failure)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if !pathObserver.isSatisfied {
                    ContentUnavailableView {
                        Label("nothing available offline", systemImage: "iphone")
                    } description: {
                        // NOT "when that path ships" — it shipped. Offline with
                        // no local model is the one dead end in this sheet, and
                        // the way out is a download, which needs the network
                        // the user doesn't have. So it says both things.
                        Text("no on-device model is installed. reconnect to use cloud or home — or to download one to this phone, which then works offline.")
                            .textCase(.lowercase)
                    }
                } else {
                    ContentUnavailableView {
                        Label(emptyTitle, systemImage: emptyGlyph)
                    } description: {
                        Text(emptyDescription)
                            .textCase(.lowercase)
                    }
                }
            }
        } else {
            Section {
                ForEach(rows) { row in
                    readyRow(row)
                        .listRowInsets(Self.rowInsets)
                }
            } header: {
                sectionHeader(readyHeader)
            }
            // No footer. "one row per model, browse to equip another, swipe to
            // remove" described the list's mechanics to someone already looking
            // at the list — and every one of those three facts is discoverable
            // by doing it once.
        }
    }

    func readyRow(_ row: Equipped) -> some View {
        // Selected means BOTH: this provider is current AND this is the model
        // it currently runs. Testing the provider alone put a checkmark on
        // every model equipped on the active key.
        let provider = row.asActive
        let selected = row.provider.id.uuidString == providerStore.currentProviderID
            && row.provider.model == row.modelID
        // Arriving weights. A model tapped in `get` is added and selected
        // immediately, so it sits here — in every segment, `all` included —
        // showing its own progress rather than living in a different list until
        // the bytes finish.
        // Weights arriving, from either side of the wire: our own download for a
        // phone model, or the server's pull for a home one. Same wait, same row
        // treatment, so the user learns one thing instead of two.
        let arriving = arrivingFraction(for: row.provider) ?? pullFraction(for: row)
        let missing = missingWeights(for: row.provider)
        let pullFailed = failedPull(for: row)
        return Button {
            // An interrupted download resumes instead of selecting: the row is
            // already selected, and tapping something that can't answer should
            // do the thing that makes it able to. A failed server pull is the same
            // shape one tier over — retry it rather than select a model the machine
            // hasn't got.
            if let missing {
                startAndSelect(missing)
            } else if pullFailed, let base = row.provider.openAIBaseURL {
                pullCenter?.start(ref: row.modelID, baseURL: base)
                Haptics.play()
            } else {
                select(row)
            }
        } label: {
            WhereRow(
                glyph: WhereProviderPresentation.systemImage(for: provider),
                // Tinted, matching settings, where every row icon carries the
                // accent. The design used secondary here to separate
                // information from action — but settings is the sheet next
                // door, and a user moving between them reads the difference as
                // inconsistency long before they read it as a system.
                glyphTint: Color.accentColor,
                title: WhereProviderPresentation.modelLabel(for: provider),
                // "downloading 24%", not a bare "24%". The bar occupies the
                // caption's slot, so if the word isn't on the title line it
                // appears nowhere: a percentage beside a progress bar tells you
                // how far along something is without ever saying what.
                //
                // A percentage is now the ONLY thing this slot carries. Warmth
                // used to share it with the tick, which is why the tick moved.
                trailingText: arriving.map { "downloading \(Int($0 * 100))%" },
                trailingMonospaced: arriving != nil,
                caption: missing != nil ? "not downloaded — \(PointerVerb.act) to resume"
                    : pullFailed ? "download failed — \(PointerVerb.act) to retry"
                    : readyCaption(for: provider),
                captionTint: (missing != nil || pullFailed) ? .orange : captionColor(for: provider),
                progress: arriving,
                // Phone: cancelling REMOVES the setup, since a local provider
                // whose weights never landed can't answer. Home: cancel the
                // server's pull and leave the provider alone — the machine and
                // its other models are still there.
                onCancel: {
                    if row.provider.isLocal {
                        cancelArriving(row.provider)
                    } else {
                        pullCenter?.cancel(ref: row.modelID)
                    }
                },
                isSelected: arriving == nil && selected,
                // Suppressed while weights are arriving, and after a pull FAILS:
                // the caption's slot is showing a progress bar or the reason there
                // isn't one, and "cold" is answering a question nobody is asking
                // until the bytes land. "download failed — tap to retry · cold" reads
                // as two problems where there is one.
                warmth: (arriving == nil && !pullFailed) ? warmthLabel(row) : nil
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(rowAccessibility(provider, selected: selected))
        // Stable handle for capture rigs. Tapping by matched TEXT proved
        // fragile — a label query resolved to an occluded twin and the tap
        // opened "connect a computer" instead of resuming a download. Ids are
        // the contract; the interrupted-download row is the one rigs need.
        .accessibilityIdentifier(missing != nil ? "where.row.resume" : "where.row")
        // No leading swipe. It was "equip", opening the model browser for this
        // row's provider — but you don't change what an equipped row runs, you
        // equip another model and get another row. Three paths reached that
        // browser (this swipe, the context menu, and `browse <place>` in `get`);
        // the swipe was the one that read as "edit this row", which is not a
        // thing you can do.
        .swipeActions(edge: .trailing) { rowDestructiveActions(row) }
        .contextMenu {
            // "MODEL INFO" REPLACES "equip another model", which was the wrong
            // verb for a long press on a model: the row names one model, and the
            // menu offered to go find a different one. Equipping still has its
            // own row in `get` — "browse near.ai" — which is where looking for
            // another model belongs.
            Button {
                detailTarget = ModelDetailTarget(provider: row.provider,
                                                 model: knownModel(for: row))
            } label: {
                Label("model info", systemImage: "info.circle")
            }
            Button {
                select(row)
            } label: {
                Label("use for chat", systemImage: "checkmark.circle")
            }
            // The same destructive action the swipe offers — see
            // `rowDestructiveActions`. It acts on THE MODEL, which is the only
            // thing this row names.
            //
            // NO SETUP-LEVEL ACTION HERE, in any segment. "delete this setup"
            // used to sit below this line, and it was the last place in the sheet
            // where a gesture on one model could take a whole endpoint and its
            // Keychain entry with it. Every row in Where is a model row — the
            // sheet has no server row at all — so a setup delete had nothing to
            // attach itself to and simply borrowed whichever model happened to be
            // listed under that key. Two models on one key meant two identical
            // buttons that destroyed the same thing, and the row you long-pressed
            // was not the thing you deleted.
            //
            // Removing a setup lives in settings › places & keys, on a row that
            // IS the setup. Where is for choosing what answers the next message;
            // administration is somewhere else.
            rowDestructiveActions(row)
        }
    }

    /// Inside the phone segment the place is already established by the segment
    /// itself, so every row reading "on this device" was one identical string
    /// repeated down the list. The catalog's one-liner is the thing that
    /// actually distinguishes two downloaded models from each other.
    /// Download progress for a local provider, nil for everything else.
    ///
    /// Requires a live JOB, not merely a missing file. "Not on disk" also
    /// describes a download that was interrupted by the app being killed, and
    /// reporting that as 0% shows a bar that will never move. `start` creates
    /// the job synchronously at fraction 0, so the bar still appears on tap.
    func arrivingFraction(for provider: Provider) -> Double? {
        guard let localID = provider.localModelID else { return nil }
        return downloader.progress(localID)
    }

    /// Selected, local, and the weights aren't there — an interrupted download.
    /// The row says so and tapping restarts it, rather than looking ready and
    /// failing at send time.
    func missingWeights(for provider: Provider) -> LocalModel? {
        guard let localID = provider.localModelID,
              downloader.progress(localID) == nil,
              let model = LocalModelCatalog.model(id: localID),
              !isInstalled(model) else { return nil }
        return model
    }

    func readyCaption(for provider: Provider) -> String? {
        getPolicy.readyCaption(for: provider)
    }

    func warmthLabel(_ row: Equipped) -> String? {
        isWarm(row).map { $0 ? "warm" : "cold" }
    }

    /// Home: server `/api/ps`. Phone: resident weights. Cloud: nil. See WhereGetPolicyTests.
    func isWarm(_ row: Equipped) -> Bool? {
        switch WhereLocality.of(row.provider) {
        case .home:
            return getPolicy.isWarm(provider: row.provider, modelID: row.modelID)
        case .phone:
            guard let localID = row.provider.localModelID,
                  let model = LocalModelCatalog.model(id: localID) else { return nil }
            return residency.isResident(LocalModelStorage.file(for: model))
        case .cloud:
            return nil
        }
    }

    /// Server-side pull progress for a home model, from `OllamaDownloadCenter`.
    /// A model added on an Ollama box is being fetched by the SERVER, so the
    /// bytes aren't ours — but the wait is the user's, and it belongs on the row
    /// they just chose rather than on the screen they came from.
    func pullFraction(for row: Equipped) -> Double? {
        guard WhereLocality.of(row.provider) == .home,
              let download = pullCenter?.download(for: row.modelID),
              !download.isFinished else { return nil }
        // nil fraction = the server hasn't reported bytes yet ("pulling
        // manifest"). Shown as an indeterminate 0 rather than hidden, because
        // the row still cannot answer.
        return download.fraction ?? 0
    }

    /// A home pull that FAILED, so the row can say so.
    ///
    /// Needed the moment the download sheet started dismissing itself on start: the
    /// failure card lives in that sheet, and a sheet that is gone shows nothing. The
    /// row equipped by `equipArriving` would otherwise sit in `ready now` looking
    /// installed, and the first sign of trouble would be a 404 on send.
    func failedPull(for row: Equipped) -> Bool {
        guard WhereLocality.of(row.provider) == .home,
              let download = pullCenter?.download(for: row.modelID),
              case .failed = download.phase else { return false }
        return true
    }

    func captionColor(for provider: Provider) -> Color {
        getPolicy.warnsUnencryptedNear(provider) ? .orange : .secondary
    }

    func rowAccessibility(_ provider: Provider, selected: Bool) -> String {
        var parts = [
            WhereProviderPresentation.modelLabel(for: provider),
            WhereProviderPresentation.placeCaption(for: provider),
        ]
        if selected { parts.append("selected") }
        return parts.joined(separator: ", ")
    }


}
