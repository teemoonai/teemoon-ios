//
//  WhereSheetView+Status.swift
//  teemoon
//

import SwiftUI

extension WhereSheetView {
    // MARK: - Airplane

    var airplaneBanner: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("you're offline")
                        .font(.body.weight(.medium))
                        .textCase(.lowercase)
                    // "(when available)" was a hedge from a base where they
                    // weren't. It sat directly above a working on-device row.
                    Text("cloud and home need a network. models on this phone still answer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.lowercase)
                }
            } icon: {
                Image(systemName: "airplane")
            }
            .foregroundStyle(.primary)
        }
    }


    // MARK: - Merged duplicates

    /// Says once that this launch folded duplicate records together.
    ///
    /// The merges delete records. Without this the only evidence is a row that
    /// stopped being there, which reads as data loss rather than as the fix it
    /// is — so it names what happened and, more importantly, that nothing
    /// runnable went with it. Dismissible, and gone next launch either way.
    @ViewBuilder
    var mergeNoticeBanner: some View {
        if let notice = providerStore.mergeNotice {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("tidied up")
                            .font(.body.weight(.medium))
                            .textCase(.lowercase)
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(.lowercase)
                        Button("ok") { providerStore.dismissMergeNotice() }
                            .font(.caption.weight(.medium))
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                            .padding(.top, 2)
                    }
                } icon: {
                    Image(systemName: "rectangle.stack.badge.minus")
                }
                .foregroundStyle(.primary)
            }
        }
    }


    // MARK: - Filter

    var localityPicker: some View {
        Section {
            Picker("where", selection: $filter) {
                Text("all").tag(Optional<WhereLocality>.none)
                // Every tier, always, empty or not.
                //
                // `phone` used to be conditional on already owning a local
                // model, which was correct on a base where a local provider
                // could not exist — an always-empty segment would have been a
                // lie. On this base it inverts: the tier is real, it is the
                // only one that works offline, and hiding it made Where
                // circular. Where is the screen that explains that running on
                // the phone is possible; you had to have already discovered it
                // to be told about it.
                //
                // It was also the ONLY conditional segment — home and cloud
                // show with nothing configured — so the rule was never "hide
                // empty tiers", it was "hide this one". Empty tiers are the
                // point of a picker: `emptyDescription` and `get` below each
                // name the way to fill the one you're looking at.
                ForEach(WhereLocality.allCases) { locality in
                    Text(locality.shortLabel).tag(Optional(locality))
                }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 10, trailing: 16))
            .listRowBackground(Color.clear)
        } footer: {
            if let filterFooter {
                Text(filterFooter)
                    .textCase(.lowercase)
            }
        }
    }

    var filterFooter: String? {
        if !pathObserver.isSatisfied {
            return "offline — only on-device setups can answer until you're back on a network."
        }
        // The prototype's wording, kept nearly verbatim. Each line states the
        // GUARANTEE for that tier — what does and doesn't leave the phone —
        // where the copy this replaces described the mechanics ("one row per
        // saved key/setup"). The mechanics are visible in the rows; the
        // guarantee is the only thing the user can't see for themselves.
        switch filter {
        case .none:
            // Nothing. The three tier footers each state a GUARANTEE — what does
            // and doesn't leave the phone — which is the one thing about a tier
            // the user can't see for themselves. `all` had no guarantee to state,
            // so it said something true about the product instead: a positioning
            // line, in the slot where every other segment answers a question.
            // It also pushed the first row down by two lines on the segment most
            // people open first.
            return nil
        case .phone:
            return "runs entirely on this device. no key, nothing leaves the phone."
        case .home:
            return "stays on your machines — laptop, desktop, or home server."
        case .cloud:
            // Was "your setups are each provider's current model. browse changes
            // which one" — describing the provider-shaped list this replaced,
            // where browse REPLACED a model instead of equipping another. Now it
            // states the tier's guarantee, like the three above it: the one
            // thing about a cloud row the user can't see for themselves is
            // whether anyone in the middle can read it.
            return "runs on someone else's hardware. each row says whether it's end-to-end encrypted."
        }
    }


}
