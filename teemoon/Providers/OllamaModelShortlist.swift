//
//  OllamaModelShortlist.swift
//  teemoon
//
//  The "pick by the memory you can spare" shortlist for a server-side Ollama pull.
//
//  A user staring at an empty text field has to already know what to type. The
//  shortlist answers the one question they can actually answer about their own
//  machine — how much GPU memory it has — and turns it into a model name.
//
//  STATIC on purpose. The sizes could be read live from
//  `registry.ollama.ai/v2/library/{model}/manifests/{tag}` (verified working, no
//  auth), and the cloud catalogues do exactly that. This doesn't, because what
//  this list encodes is not a size: it is a RECOMMENDATION, and recommendations
//  are a judgement teemoon ships rather than a fact it fetches. A deliberate choice.
//
//  Related: OllamaModelDownloadView (renders it), OllamaAdapter (runs the pull).
//

import Foundation

/// One recommended pull: an Ollama tag, what it costs to fetch, and the GPU memory
/// it wants once it's there.
struct OllamaShortlistModel: Identifiable, Equatable, Sendable {
    /// The exact ref passed to `/api/pull` — and a real Ollama library tag.
    let tag: String
    var id: String { tag }

    /// Download size of the Q4 weights, as the registry reports them.
    let downloadGB: Double

    /// Recommended GPU memory at Q4, in GB: `low` is tight, `high` is comfortable.
    /// Equal when the source gives one figure rather than two.
    let vramLowGB: Int
    let vramHighGB: Int

    /// Mixture-of-experts, which is worth saying on the row: `gemma4:26b` is really
    /// `26b-a4b` — 26B of weights that must all be resident, 4B active per token —
    /// so it costs 26B of memory at the speed of something much smaller. Without
    /// the badge the row reads as a straightforwardly worse deal than 31B.
    let isMixtureOfExperts: Bool

    /// "9.6 gb" / "18 gb" — whole numbers stay whole, so a row doesn't read "18.0".
    var downloadLabel: String {
        downloadGB == downloadGB.rounded()
            ? "\(Int(downloadGB)) gb"
            : String(format: "%.1f gb", downloadGB)
    }

    /// "6–8 gb vram" / "32 gb vram". An en dash, matching the source table.
    var vramLabel: String {
        vramLowGB == vramHighGB
            ? "\(vramHighGB) gb vram"
            : "\(vramLowGB)–\(vramHighGB) gb vram"
    }
}

enum OllamaModelShortlist {

    /// Gemma 4, the family the shortlist is built from.
    ///
    /// **Recommended VRAM comes from the Q4 lines of the rule-of-thumb table the developer
    /// supplied (2026-07-30, 28 sources), and nothing else:**
    ///
    ///   - "6–8 GB VRAM: E4B at Q4 comfortably"           → e4b, 6–8
    ///   - "16 GB VRAM: 26B MoE at Q4 (tight)" and
    ///     "24 GB VRAM: 26B MoE at Q4/Q5"                 → 26b, 16 tight → 24
    ///   - "24 GB VRAM: 31B at Q4 (very limited context)"
    ///     and "32 GB VRAM: 31B at Q4 comfortable"        → 31b, 24 tight → 32
    ///
    /// The Q8 / FP16 / Q2-Q3 lines are deliberately dropped: every tag here pulls a
    /// Q4 build, so quoting another quant's requirement would describe a download
    /// the user isn't making.
    ///
    /// **`e2b` and `12b` are absent for the same reason** — that table has no Q4
    /// line for either, and this list is not the place to invent one. Both exist and
    /// are cheaper to fetch (7.2 GB and 7.6 GB), so they are worth adding the moment
    /// there is a sourced figure. `12b` in particular is a smaller download than
    /// `e4b`.
    ///
    /// Download sizes are the sum of the model layers in each tag's registry
    /// manifest, read 2026-07-30: e4b 9.61 → 9.6, 26b 17.99 → 18, 31b 19.87 → 20.
    /// `gemma4:latest` is byte-identical to `e4b`, so naming the tag says more.
    ///
    /// NOT here: `gemma4:cloud` and `gemma4:31b-cloud`. They are hosted by Ollama
    /// rather than pulled, so offering them in a download sheet would start a pull
    /// of something that was never going to arrive.
    static let gemma4: [OllamaShortlistModel] = [
        OllamaShortlistModel(tag: "gemma4:e4b", downloadGB: 9.6,
                             vramLowGB: 6, vramHighGB: 8, isMixtureOfExperts: false),
        OllamaShortlistModel(tag: "gemma4:26b", downloadGB: 18,
                             vramLowGB: 16, vramHighGB: 24, isMixtureOfExperts: true),
        OllamaShortlistModel(tag: "gemma4:31b", downloadGB: 20,
                             vramLowGB: 24, vramHighGB: 32, isMixtureOfExperts: false),
    ]

    /// What the sheet shows, smallest first — the order someone reads a "what fits?"
    /// list in, and the order that puts the row most machines can run at the top.
    static var recommended: [OllamaShortlistModel] { gemma4 }
}
