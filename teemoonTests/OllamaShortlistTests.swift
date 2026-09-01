//
//  OllamaShortlistTests.swift
//  teemoonTests
//
//  The "pick by the memory you can spare" list. Static data, so these tests are
//  about the two things static data gets wrong: numbers that don't come from
//  anywhere, and labels that read badly on a row.
//

import Foundation
import Testing
@testable import teemoon

@Suite("Ollama shortlist")
struct OllamaShortlistTests {

    /// Exactly the tags the source table has a Q4 line for, and no others.
    ///
    /// This is the test that stops the list growing by guesswork. The source
    /// rule-of-thumb table (2026-07-30) covers E4B, 26B MoE and 31B at Q4;
    /// `gemma4:e2b` and `gemma4:12b` are real, pullable and CHEAPER (7.2 GB and
    /// 7.6 GB), and they are still not here, because a recommendation needs a
    /// recommended figure and that table gives them none. Adding a row means
    /// bringing a source for its number.
    @Test func onlyTagsWithASourcedQ4FigureAreListed() {
        #expect(OllamaModelShortlist.recommended.map(\.tag)
                == ["gemma4:e4b", "gemma4:26b", "gemma4:31b"])
    }

    /// The Q4 figures, exactly as the table states them: 6–8 for E4B, 26B tight at
    /// 16 and comfortable at 24, 31B tight at 24 and comfortable at 32.
    @Test func vramFiguresMatchTheSourceTable() {
        let byTag = Dictionary(uniqueKeysWithValues:
            OllamaModelShortlist.recommended.map { ($0.tag, $0) })

        #expect(byTag["gemma4:e4b"]?.vramLowGB == 6)
        #expect(byTag["gemma4:e4b"]?.vramHighGB == 8)
        #expect(byTag["gemma4:26b"]?.vramLowGB == 16)
        #expect(byTag["gemma4:26b"]?.vramHighGB == 24)
        #expect(byTag["gemma4:31b"]?.vramLowGB == 24)
        #expect(byTag["gemma4:31b"]?.vramHighGB == 32)

        // The MoE badge belongs to 26b alone: the tag resolves to `26b-a4b`, so all
        // 26B of weights sit in memory while 4B are active per token. That is why it
        // wants more VRAM than 31B's download would suggest, and the badge is what
        // stops the row reading as a strictly worse deal.
        #expect(byTag["gemma4:26b"]?.isMixtureOfExperts == true)
        #expect(byTag["gemma4:e4b"]?.isMixtureOfExperts == false)
        #expect(byTag["gemma4:31b"]?.isMixtureOfExperts == false)
    }

    /// Download sizes as the registry manifests report them (2026-07-30): the sum of
    /// each tag's model layers.
    ///
    /// The two figures are independent, and this test originally asserted they were
    /// ordered — "running needs more room than storing" — which failed on `e4b`:
    /// 9.6 GB of weights, recommended 6–8 GB of VRAM. That is not a bad number, it
    /// is the E-series' whole point. Gemma's E2B/E4B keep per-layer embeddings that
    /// do not all have to be resident on the GPU, so the effective footprint is
    /// smaller than the file — which is exactly why the source table can say "E4B at
    /// Q4 comfortably" for a 6 GB card. The dense rows do behave the other way (26B
    /// wants 24 for an 18 GB download), so the ordering is asserted per-family
    /// rather than as a law.
    @Test func downloadSizesComeFromTheManifestsAndAreNotTheVRAMFigure() {
        for model in OllamaModelShortlist.recommended {
            #expect(model.downloadGB > 0)
        }
        let byTag = Dictionary(uniqueKeysWithValues:
            OllamaModelShortlist.recommended.map { ($0.tag, $0) })
        // Dense: comfortable VRAM exceeds the download.
        for tag in ["gemma4:26b", "gemma4:31b"] {
            guard let m = byTag[tag] else { continue }
            #expect(Double(m.vramHighGB) > m.downloadGB, "\(tag)")
        }
        // E-series: the download is LARGER than the recommended VRAM, on purpose.
        #expect((byTag["gemma4:e4b"]?.downloadGB ?? 0) > Double(byTag["gemma4:e4b"]?.vramHighGB ?? 0))
        #expect(byTag["gemma4:e4b"]?.downloadGB == 9.6)     // manifest: 9.61 GB
        #expect(byTag["gemma4:26b"]?.downloadGB == 18)      // 17.99
        #expect(byTag["gemma4:31b"]?.downloadGB == 20)      // 19.87
    }

    /// Smallest first — the order a "what fits?" list is read in, so the row most
    /// machines can run leads.
    @Test func rowsRunSmallestFirst() {
        let sizes = OllamaModelShortlist.recommended.map(\.downloadGB)
        #expect(sizes == sizes.sorted())
        let vram = OllamaModelShortlist.recommended.map(\.vramHighGB)
        #expect(vram == vram.sorted())
    }

    /// Every tag must be pullable. `gemma4:cloud` and `gemma4:31b-cloud` exist in the
    /// library and are hosted by Ollama rather than downloaded, so listing one would
    /// start a pull of something that never arrives.
    @Test func noHostedTagsAreOffered() {
        for model in OllamaModelShortlist.recommended {
            #expect(!model.tag.contains("cloud"))
            #expect(model.tag.contains(":"), "a bare name pulls whatever :latest is today")
        }
    }

    /// Row labels. Whole numbers stay whole — "18.0 gb" beside "9.6 gb" reads as a
    /// precision the figure doesn't have.
    @Test func labelsReadAsRowsNotAsData() {
        let byTag = Dictionary(uniqueKeysWithValues:
            OllamaModelShortlist.recommended.map { ($0.tag, $0) })
        #expect(byTag["gemma4:e4b"]?.downloadLabel == "9.6 gb")
        #expect(byTag["gemma4:26b"]?.downloadLabel == "18 gb")
        #expect(byTag["gemma4:e4b"]?.vramLabel == "6–8 gb vram")     // en dash
        #expect(byTag["gemma4:31b"]?.vramLabel == "24–32 gb vram")

        // One figure rather than two collapses, instead of printing "8–8".
        let single = OllamaShortlistModel(tag: "x:1b", downloadGB: 1,
                                          vramLowGB: 8, vramHighGB: 8,
                                          isMixtureOfExperts: false)
        #expect(single.vramLabel == "8 gb vram")
        #expect(single.downloadLabel == "1 gb")
    }

    /// Tapping a row must produce a ref the pull path accepts unchanged — the sheet
    /// puts the tag straight into the field, and `normalizePullRef` is what runs on
    /// it. A tag that normalization rewrites would pull something else.
    @Test func tagsSurviveNormalizationUntouched() {
        for model in OllamaModelShortlist.recommended {
            #expect(OllamaAdapter.normalizePullRef(model.tag) == model.tag)
        }
    }
}

/// What the sheet says when a pull fails — the question was whether unknown names and bad
/// urls are handled cleanly, and the honest answer was "structurally yes, in copy
/// no": Ollama's raw message reached the user because only TERSE errors were being
/// rewritten. These pin the mapping against the strings a live server actually
/// emitted (measured 2026-07-30 against Ollama on :11434).
@Suite("Ollama pull failures")
struct OllamaPullFailureTests {

    /// A misspelled name and a pasted junk url produce the SAME Ollama error, and it
    /// explains nothing: "pull model manifest: file does not exist".
    @Test func aMisspelledNameSaysSoInsteadOfQuotingAManifest() {
        let raw = "pull model manifest: file does not exist"
        let failure = OllamaDownloadCenter.classifyPullError(raw)
        #expect(failure == .noSuchModel)
        #expect(!failure.message.contains("manifest"))
        #expect(failure.message.contains("copy the link"))
        // The hint must NOT be the quant advice: nothing about `:Q4_K_M` helps a ref
        // that doesn't exist, and it sends the user to edit the wrong half.
        #expect(failure.hint?.contains("Q4_K_M") != true)
        // And it points at the model's OWN page, which is the mistake behind most
        // of these: a search or listing url is the thing in the clipboard.
        #expect(failure.hint?.contains("own page") == true)

        // The whole screen speaks in LINKS now. A bare ollama name still pulls —
        // the shortlist rows are names — but nothing instructs the user to type one,
        // so no failure copy may send them looking for one either.
        #expect(!failure.message.contains("qwen3.5"))
        #expect(failure.hint?.contains("qwen3.5") != true)
    }

    /// The worst one. Ollama answers a missing hugging face repo with a realm-host
    /// mismatch, which reads as teemoon getting a hostname wrong.
    @Test func theRealmHostMessageBecomesSomethingTrue() {
        let raw = "pull model manifest: realm host \"huggingface.co\" does not match original host \"hf.co\""
        let failure = OllamaDownloadCenter.classifyPullError(raw)
        #expect(failure == .huggingFaceRepoUnavailable)
        #expect(!failure.message.contains("realm"))
        #expect(failure.message.contains("gguf"))
        // Here the quant advice IS advice — the repo may exist with other files.
        #expect(failure.hint?.contains("Q4_K_M") == true)
    }

    @Test func gatedAndTerseAndUnknownKeepTheirOwnMeanings() {
        #expect(OllamaDownloadCenter.classifyPullError("unauthorized: access denied") == .gated)
        #expect(OllamaDownloadCenter.classifyPullError("400:") == .sourceRefused(code: "400"))
        #expect(OllamaDownloadCenter.classifyPullError("") == .sourceRefused(code: nil))
        // An unrecognised message is passed through rather than explained away — a
        // wording change upstream must degrade to the raw text, never to a confident
        // wrong story.
        let weird = "something nobody has seen before"
        #expect(OllamaDownloadCenter.classifyPullError(weird) == .other(weird))
        #expect(OllamaDownloadCenter.friendlyPullError(weird) == weird)
    }

    /// The paste this screen invites, because its own browse buttons open these two
    /// pages: a search url and a listing url, neither of which names a model.
    @Test func listingAndSearchPagesAreRefusedBeforeAPullStarts() {
        #expect(OllamaAdapter.refProblem("https://ollama.com/search?q=gemma")?
            .contains("search page") == true)
        #expect(OllamaAdapter.refProblem("https://ollama.com/library") != nil)
        #expect(OllamaAdapter.refProblem(
            "https://huggingface.co/models?library=gguf&sort=trending")?.contains("model list") == true)
        #expect(OllamaAdapter.refProblem("https://huggingface.co/datasets/foo") != nil)
        #expect(OllamaAdapter.refProblem("https://huggingface.co/bartowski") != nil)  // no repo
    }

    /// And it must object to nothing else. Ollama pulls from ANY registry host, so a
    /// check that rejected unfamiliar hosts would block private registries to catch
    /// typos — the trade this deliberately doesn't make.
    @Test func everythingPullableIsLeftAlone() {
        for good in [
            "qwen3.5",
            "gemma4:26b",
            "https://ollama.com/library/qwen3.5",
            "https://ollama.com/library/gemma4/tags",
            "ollama.com/some-user/their-model",
            "https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF",
            "hf.co/bartowski/repo:Q4_K_M",
            "registry.internal.example/team/model",      // a private registry
        ] {
            #expect(OllamaAdapter.refProblem(good) == nil, "objected to \(good)")
        }
        // Empty is not a problem to report — the download button is already disabled.
        #expect(OllamaAdapter.refProblem("   ") == nil)
    }
}

/// Validation of the download field, which is now a LINK field.
///
/// The question was whether a badly formed url or text could get something executed, and
/// then — once the copy said "paste the link" — whether plain url validation would do
/// instead of character allowlists. Both answers point the same way: there is no
/// injection path (the ref is a JSON string field, and every request is built with
/// `appendingPathComponent` on a fixed path, so the text never reaches a url, header,
/// query or shell), so the validator's only job is catching a paste that isn't a model
/// page. `URLComponents`-grade checks do that; the allowlist was theatre with false
/// rejections attached, and it is gone.
@Suite("Ollama link validation")
struct OllamaRefValidationTests {

    @Test func modelPagesAndBareRefsAreAccepted() {
        for good in [
            // Links, which is what the screen asks for.
            "https://ollama.com/library/qwen3.5",
            "https://ollama.com/library/gemma4:26b",
            "https://ollama.com/library/gemma4/tags",
            "https://ollama.com/some-user/their-model",
            "https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF",
            "https://huggingface.co/bartowski/repo/tree/main",
            "hf.co/bartowski/repo:Q4_K_M",          // scheme dropped by a share sheet
            // NOT links, and not judged as any: the shortlist rows write a tag here,
            // and a private registry ref is a name too. Unadvertised, still working.
            "qwen3.5", "gemma4:26b", "gemma4:e4b",
            "registry.internal.example/team/model",
            "192.168.1.50:5000/team/model",
            "library/gemma4@sha256:0123456789abcdef",
            "  ollama pull qwen3.5  ",
        ] {
            #expect(OllamaAdapter.refProblem(good) == nil, "rejected \(good)")
        }
    }

    /// `gemma4:26b` parses as a URL with the scheme "gemma4". Judged as a link it
    /// would be rejected for a bad scheme — and it is what tapping a shortlist row
    /// puts in the field, so this is the case that decides `asLink`.
    @Test func aTagIsNotMistakenForALink() {
        #expect(OllamaAdapter.refProblem("gemma4:26b") == nil)
        #expect(OllamaAdapter.refProblem("qwen3.5:4b") == nil)
    }

    /// A link from somewhere else entirely — the paste this screen can actually be
    /// sure about, now that it only ever asks for two sites.
    @Test func linksFromOtherSitesAreRefused() {
        #expect(OllamaAdapter.refProblem("https://github.com/ggerganov/llama.cpp")?
            .contains("ollama.com or hugging face") == true)
        #expect(OllamaAdapter.refProblem("https://example.com/model.gguf") != nil)
    }

    /// Pages on the RIGHT site that still aren't a model — the browse buttons open
    /// exactly these, so they are the likeliest thing in the clipboard.
    @Test func searchAndListingPagesAreRefused() {
        #expect(OllamaAdapter.refProblem("https://ollama.com/search?q=gemma")?
            .contains("search page") == true)
        #expect(OllamaAdapter.refProblem("https://ollama.com/library") != nil)
        #expect(OllamaAdapter.refProblem(
            "https://huggingface.co/models?library=gguf&sort=trending")?
            .contains("model list") == true)
        #expect(OllamaAdapter.refProblem("https://huggingface.co/datasets/foo") != nil)
        #expect(OllamaAdapter.refProblem("https://huggingface.co/bartowski") != nil)  // no repo
    }

    @Test func onlyHTTPSchemesAreAccepted() {
        for bad in ["file:///etc/passwd", "javascript:alert(1)",
                    "data:text/plain;base64,AAAA", "ftp://example.com/model"] {
            #expect(OllamaAdapter.refProblem(bad)?.contains("http") == true, "allowed \(bad)")
        }
    }

    /// Empty stays silent — the download button is already disabled, and an error on
    /// an untouched field is a scolding.
    @Test func emptyIsNotAnError() {
        #expect(OllamaAdapter.refProblem("") == nil)
        #expect(OllamaAdapter.refProblem("   \n ") == nil)
    }
}

/// "Is this already on the machine?" — nothing asked before, so the shortlist
/// recommended models a server had had for weeks, and a re-pull looked exactly like a
/// first download.
@Suite("Ollama installed matching")
struct OllamaInstalledMatchTests {

    private let installed = [
        "gemma4:26b", "qwen3.5:4b", "gemma4:latest",
        "hf.co/bartowski/Repo-GGUF:Q4_K_M",
    ]

    @Test func exactTagsMatch() {
        #expect(OllamaAdapter.installedMatch("gemma4:26b", in: installed) == "gemma4:26b")
        #expect(OllamaAdapter.installedMatch("qwen3.5:4b", in: installed) == "qwen3.5:4b")
    }

    /// The case a plain string compare gets wrong, and the commonest way to name a
    /// model: a bare name means `:latest`, and `/api/tags` reports the tagged form.
    @Test func aBareNameMeansLatest() {
        #expect(OllamaAdapter.installedMatch("gemma4", in: installed) == "gemma4:latest")
        #expect(OllamaAdapter.installedMatch("gemma4:latest", in: installed) == "gemma4:latest")
        // And it must not match a DIFFERENT tag of the same model.
        #expect(OllamaAdapter.installedMatch("gemma4:31b", in: installed) == nil)
    }

    /// Links reduce to refs first, so pasting a model's page finds what you have.
    @Test func linksAreMatchedThroughNormalization() {
        #expect(OllamaAdapter.installedMatch("https://ollama.com/library/gemma4:26b",
                                             in: installed) == "gemma4:26b")
        #expect(OllamaAdapter.installedMatch("https://ollama.com/library/gemma4",
                                             in: installed) == "gemma4:latest")
        #expect(OllamaAdapter.installedMatch(
            "https://huggingface.co/bartowski/Repo-GGUF:Q4_K_M", in: installed)
            == "hf.co/bartowski/Repo-GGUF:Q4_K_M")
    }

    @Test func caseIsIgnoredBecauseServersDisagreeAboutIt() {
        #expect(OllamaAdapter.installedMatch("GEMMA4:26B", in: installed) == "gemma4:26b")
    }

    /// A PORT is not a tag. `registry:5000/team/model` has a colon in its host, and
    /// reading that as a tag would leave the ref untagged and match nothing — or,
    /// worse, match the wrong thing.
    @Test func aPortIsNotATag() {
        let withPort = ["registry:5000/team/model:latest"]
        #expect(OllamaAdapter.installedMatch("registry:5000/team/model", in: withPort)
                == "registry:5000/team/model:latest")
    }

    @Test func nothingInstalledMatchesNothing() {
        #expect(OllamaAdapter.installedMatch("gemma4:26b", in: []) == nil)
        #expect(OllamaAdapter.installedMatch("", in: installed) == nil)
        #expect(OllamaAdapter.installedMatch("something-else", in: installed) == nil)
    }
}
