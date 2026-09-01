//
//  SourceSelectionTests.swift
//  teemoonTests
//
//  The question `ModelTierGroundingTests` could not answer.
//
//  That harness settled "do local models USE a tool result?" — yes, 3/3, at
//  every size. But it scored *did the reply state a figure from the payload*,
//  and given ten contradictory weather pages, `gemma4:e2b` said 42°F for a
//  late-July New York afternoon while `glm-5.2` said 84°F and named
//  AccuWeather. Both scored a clean pass. Both "used the grounding". Only one
//  was right, and the scorer is structurally blind to the difference — it
//  compares the reply to the PAYLOAD, and a stale source is in the payload too.
//
//  So the real tier difference isn't grounding USE, it's source SELECTION, and
//  measuring it needs a third party: an authority that is neither Brave nor the
//  model. That is the whole design here. Ground truth is fetched LIVE from a
//  keyless public API at test time, so the expected answer can never go stale
//  in the repo — the failure mode of every hardcoded-fact test ever written.
//
//  ── The hypothesis under test ───────────────────────────────────────────────
//  teemoon used to hand self-hosted providers 3 sources instead of 10
//  (`GroundingBudget.compact`), justified on tokens and local prefill cost. The
//  question was whether fewer, higher-ranked sources ALSO made a small model
//  land on the right number — which would have given it a correctness
//  justification, a far stronger reason to keep it.
//
//  It did the opposite (see FIRST RESULT below), and combined with a separate
//  finding that prefill is effectively free on GPU, the compact budget was
//  retired — `fec4207` for the policy, and the follow-up that deleted the type.
//  This experiment outlived it on purpose: it is what would catch the decision
//  being wrong, and it now compares literal payload sizes rather than whatever
//  enum cases production happens to ship.
//
//  Design: one Brave fetch per (shape, budget); that exact payload handed to
//  every model. Only the budget and the model vary.
//
//  ── Query shapes ────────────────────────────────────────────────────────────
//  `weather 10001` overfits — it is a near-worst case, and its replies are
//  number-DENSE (temp, feels-like, humidity, wind, dew point, a date), so a
//  tolerance band can be hit by luck. The brief asked for queries with a
//  SINGLE verifiable answer, so the primary shapes are a crypto price and an FX
//  rate: one crisp number each, no time series, and a wide gulf between a live
//  source and a stale one. Weather stays as the known-hard control, with its
//  collision risk named rather than hidden — every cell reports how many
//  distinctive figures the reply contained, so a lucky hit is visible.
//
//  ── FIRST RESULT (2026-07-26, n=3/cell) ─────────────────────────────────────
//  The hypothesis is REFUTED, and in the opposite direction: `full` beat
//  `compact` on median error in 6 of 6 cells across the two reliable shapes, and
//  `compact` won none. gemma4:e2b on usd→jpy was 2/3 correct compact vs 3/3
//  full. Fewer, higher-ranked sources do NOT help a small model choose; the
//  compact budget buys tokens and latency at a measurable cost in accuracy.
//
//  n=3 per cell is thin — but the direction is consistent across independent
//  cells, which is worth more here than any single one. Confirm at n≥12 on
//  gemma4:e2b before changing `ChatGeneration.swift`; the ±nudge study went
//  3/5-vs-5/5 at n=5 and 18/20-vs-17/20 at n=20, i.e. a clean reversal.
//
//  ── The weather shape's numbers are VOID, and why ────────────────────────────
//  Kept in the file, excluded from the conclusion. Nearest-figure scoring failed
//  exactly where the header predicts it can: in a number-dense reply it matched
//  30.19 (barometric PRESSURE) against 28 °C and scored it correct, and matched
//  93 (HUMIDITY) against 82.4 °F to report a 10.6-degree error. Neither figure
//  was a temperature at all.
//
//  Reading the transcript instead of the table shows something the score missed
//  in both directions: on the compact payload gemma4:e2b stated no temperature
//  whatsoever in 2 of 3 trials, and in the third reported the stale 42 °F. Worse
//  behaviour than the row claims, arrived at by luck rather than measurement.
//
//  To make this shape scorable, a Reading needs to say whether its figure must
//  be UNIT-ANCHORED, and temperature matching must then require an adjacent
//  °/degree/F/C — LaTeX forms included, since scorer bug #4 was a unit-anchored
//  regex blind to `$48^\circ\text{F}$`. Until then, trust btc and usd→jpy only.
//
//  ── Cost ────────────────────────────────────────────────────────────────────
//  Six Brave grounding queries (3 shapes × 2 budgets) at ~$0.005 = ~3¢, plus
//  ~$0.001/turn for the cloud arm. Local inference is free. Ground-truth APIs
//  are keyless and free.
//
//  Run with SWEEP_GROUNDING_BUDGET=1 and the Brave / cloud keys exported from
//  the shell profile (TEST_RUNNER_-prefixed for xcodebuild).
//

import Foundation
import Testing
import ModelBackend
@testable import teemoon

@Suite("Source selection vs budget (live)", .serialized)
struct SourceSelectionTests {

    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    private static var braveKey: String? {
        guard env["SWEEP_GROUNDING_BUDGET"] == "1" else { return nil }
        let k = env["BRAVE_API_KEY"] ?? ""
        return k.isEmpty ? nil : k
    }

    // MARK: - Ground truth

    /// One acceptable reading of the truth. A shape can have several because the
    /// model chooses the UNIT: 27 °C and 80.6 °F are the same correct answer,
    /// and scoring only one of them would fail a right answer for its units.
    struct Reading {
        let value: Double
        let plusMinus: Double
        let unit: String
    }

    /// Where the truth comes from — deliberately NOT Brave and NOT the model.
    enum Authority {
        case coinbaseSpot(String)              // e.g. "BTC-USD"
        case ecbReferenceRate(base: String, quote: String)
        case nwsObservation(lat: Double, lon: Double)

        var name: String {
            switch self {
            case .coinbaseSpot: return "api.coinbase.com spot"
            case .ecbReferenceRate: return "frankfurter.dev (ECB reference rate)"
            case .nwsObservation: return "api.weather.gov station observation"
            }
        }

        func fetch() async throws -> [Reading] {
            switch self {
            case .coinbaseSpot(let pair):
                let url = URL(string: "https://api.coinbase.com/v2/prices/\(pair)/spot")!
                let (data, _) = try await URLSession.shared.data(from: url)
                let decoded = try JSONDecoder().decode(CoinbaseSpot.self, from: data)
                guard let amount = Double(decoded.data.amount) else {
                    throw ReferenceError.unreadable(self.name)
                }
                // ±3%: web pages lag a live spot by minutes to hours, and crypto
                // moves. Wide enough to accept an honestly-fresh source, far too
                // tight to accept a source from last month.
                return [Reading(value: amount, plusMinus: amount * 0.03, unit: "USD")]

            case .ecbReferenceRate(let base, let quote):
                var c = URLComponents(string: "https://api.frankfurter.dev/v1/latest")!
                c.queryItems = [URLQueryItem(name: "base", value: base),
                                URLQueryItem(name: "symbols", value: quote)]
                let (data, _) = try await URLSession.shared.data(from: c.url!)
                let decoded = try JSONDecoder().decode(FrankfurterLatest.self, from: data)
                guard let rate = decoded.rates[quote] else { throw ReferenceError.unreadable(self.name) }
                // ECB publishes once a business day, so this can trail the live
                // market by a weekend. ±2% swallows that comfortably while still
                // catching a genuinely stale page.
                return [Reading(value: rate, plusMinus: rate * 0.02, unit: quote)]

            case .nwsObservation(let lat, let lon):
                let celsius = try await Self.latestObservedCelsius(lat: lat, lon: lon)
                let fahrenheit = celsius * 9 / 5 + 32
                // Both units, because the model picks. ±5 °F is roughly the
                // spread between a nearby station and the town itself.
                return [Reading(value: fahrenheit, plusMinus: 5, unit: "°F"),
                        Reading(value: celsius, plusMinus: 5 * 5 / 9, unit: "°C")]
            }
        }

        /// NWS is a two-hop API: coordinates → grid → stations → latest
        /// observation. Worth the hops: it is the authority the weather sites
        /// are themselves reporting, so it is upstream of the disagreement.
        private static func latestObservedCelsius(lat: Double, lon: Double) async throws -> Double {
            func get<T: Decodable>(_ url: URL, as: T.Type) async throws -> T {
                var req = URLRequest(url: url)
                // NWS rejects requests without a User-Agent.
                req.setValue("teemoon-tests (github.com/teemoonai/teemoon-ios)",
                             forHTTPHeaderField: "User-Agent")
                let (data, _) = try await URLSession.shared.data(for: req)
                return try JSONDecoder().decode(T.self, from: data)
            }
            let points = try await get(
                URL(string: "https://api.weather.gov/points/\(lat),\(lon)")!, as: NWSPoints.self)
            let stations = try await get(
                URL(string: points.properties.observationStations)!, as: NWSStations.self)
            guard let station = stations.features.first?.properties.stationIdentifier else {
                throw ReferenceError.unreadable("api.weather.gov stations")
            }
            let obs = try await get(
                URL(string: "https://api.weather.gov/stations/\(station)/observations/latest")!,
                as: NWSObservation.self)
            guard let c = obs.properties.temperature.value else {
                throw ReferenceError.unreadable("api.weather.gov observation")
            }
            return c
        }
    }

    enum ReferenceError: Error { case unreadable(String) }

    struct CoinbaseSpot: Decodable { struct Payload: Decodable { let amount: String }; let data: Payload }
    struct FrankfurterLatest: Decodable { let base: String; let date: String; let rates: [String: Double] }
    struct NWSPoints: Decodable {
        struct Properties: Decodable { let observationStations: String }
        let properties: Properties
    }
    struct NWSStations: Decodable {
        struct Feature: Decodable {
            struct Properties: Decodable { let stationIdentifier: String }
            let properties: Properties
        }
        let features: [Feature]
    }
    struct NWSObservation: Decodable {
        struct Properties: Decodable {
            struct Measurement: Decodable { let value: Double? }
            let timestamp: String
            let temperature: Measurement
        }
        let properties: Properties
    }

    // MARK: - Shapes

    struct Shape {
        let label, braveQuery, prompt: String
        let authority: Authority
        /// Whether replies to this shape are number-dense enough that a
        /// tolerance band can be hit by coincidence. Reported, not hidden.
        let numberDense: Bool
    }

    static let shapes: [Shape] = [
        .init(label: "btc price", braveQuery: "bitcoin price usd",
              prompt: "What is the current price of bitcoin in USD?",
              authority: .coinbaseSpot("BTC-USD"), numberDense: false),
        .init(label: "usd→jpy", braveQuery: "usd to jpy exchange rate",
              prompt: "What is the current USD to Japanese Yen exchange rate?",
              authority: .ecbReferenceRate(base: "USD", quote: "JPY"), numberDense: false),
        // The control: the query the whole disagreement started on.
        .init(label: "weather", braveQuery: "weather 10001",
              prompt: "What is the weather in New York NY 10001 right now?",
              authority: .nwsObservation(lat: 40.4757, lon: -74.6249), numberDense: true),
    ]

    // MARK: - Payload sizes under test

    /// The payload sizes to compare, as literal `(maxTokens, maxURLs)` rather
    /// than as `GroundingBudget` cases.
    ///
    /// It used to read the two enum cases, which tied the experiment to whatever
    /// production happened to ship — so when `.compact` was retired on this
    /// experiment's own evidence, the experiment lost the ability to re-check its
    /// own finding. An instrument that can only measure the status quo can never
    /// tell you the status quo is wrong.
    ///
    /// Literals also make the axis continuous. The original question was binary
    /// ("3 sources or 10?"), but the answer — bigger was better everywhere —
    /// invites the obvious follow-up of whether it keeps improving past 10, which
    /// is now one line to ask. The first entry stays at the retired compact
    /// numbers so the historical comparison remains reproducible.
    static let payloadSizes: [(label: String, maxTokens: Int, maxURLs: Int)] = [
        ("compact (3 src)", 1024, 3),      // the retired GroundingBudget.compact
        ("full (10 src)", 4096, 10),       // what every provider now gets
    ]

    // MARK: - Scoring

    /// The closest distinctive figure in the reply to any acceptable reading,
    /// as an absolute error and as a multiple of that reading's tolerance.
    ///
    /// Deliberately NOT prose parsing. "Which number is the model's actual
    /// answer?" needs grammar, and every prose-shaped scorer in this
    /// investigation has been wrong at least once. Nearest-figure is blunt but
    /// it cannot be fooled by phrasing — and its one weakness, a number-dense
    /// reply hitting the band by luck, is measured and reported alongside
    /// (`figures`) rather than argued away.
    static func score(reply: String, question: String, against readings: [Reading])
        -> (correct: Bool, error: Double, matched: Reading, figures: Int)? {
        let figures = GroundingTestSupport.distinctiveFigures(in: reply, excluding: question)
            .compactMap(Double.init)
        guard !figures.isEmpty else { return nil }
        var best: (Double, Reading)?
        for reading in readings {
            for f in figures {
                let err = abs(f - reading.value)
                // Compared in units of tolerance, so a 0.4-yen miss on a 163-yen
                // rate ranks ahead of a 2-degree miss on an 80-degree reading.
                if best == nil || err / reading.plusMinus < best!.0 / best!.1.plusMinus {
                    best = (err, reading)
                }
            }
        }
        guard let (error, matched) = best else { return nil }
        return (error <= matched.plusMinus, error, matched, figures.count)
    }

    // MARK: - The experiment

    @Test @MainActor func doesTheCompactBudgetImproveSourceSelection() async throws {
        guard let brave = Self.braveKey else { return }
        let trials = Int(Self.env["SWEEP_BUDGET_TRIALS"] ?? "3") ?? 3

        var arms: [(String, Provider, String)] = []
        if await GroundingTestSupport.ollamaIsUp() {
            arms.append(("gemma4:e2b (local 2B)", GroundingTestSupport.ollama(model: "gemma4:e2b-it-qat"), ""))
            arms.append(("qwen3.5:4b (local 4B)", GroundingTestSupport.ollama(model: "qwen3.5:4b"), ""))
        }
        if let nearKey = Self.env["NEAR_AI_API_KEY"], !nearKey.isEmpty {
            arms.append(("\(Provider.nearAI.model) (cloud)", Provider.nearAI, nearKey))
        }
        guard !arms.isEmpty else { return }

        var summary: [Cell] = []
        var transcript: [String] = []
        var truthNotes: [String] = []

        // ── Phase 1: every ground truth and every payload, up front ───────────
        //
        // Fetched before ANY generation so that phase 2 can put the model in the
        // outermost loop. That ordering is not cosmetic: Ollama keeps one model
        // resident by default (`OLLAMA_MAX_LOADED_MODELS` unset), so loading the
        // 4B evicts the 2B and vice versa — measured at ~19s per reload. With the
        // model innermost, this experiment paid that on every arm switch inside
        // every (shape, budget) block: ~12 reloads, 3-4 minutes of a run spent
        // loading weights rather than measuring anything.
        //
        // Prefetching also preserves the property that makes the experiment
        // valid — ONE Brave fetch per (shape, budget), that exact payload given
        // to every model — which a naive reorder would have broken by refetching
        // per arm and letting the web move under the comparison.
        struct Cache { let shape: Shape; let budgetLabel: String; let payload: String
                       let readings: [Reading]; let sources: Int }
        var cached: [Cache] = []
        for shape in Self.shapes {
            // Truth FIRST, and the run for this shape is abandoned if the
            // authority is unreachable. A missing reference doesn't degrade the
            // experiment into a weaker one — it invalidates it, and quietly
            // falling back to "did it cite the payload" is exactly the substitution
            // that produced the wrong answer the first time.
            let readings: [Reading]
            do {
                readings = try await shape.authority.fetch()
            } catch {
                truthNotes.append("- **\(shape.label)** — SKIPPED: \(shape.authority.name) unreachable (\(error))")
                continue
            }
            truthNotes.append("- **\(shape.label)** — \(shape.authority.name): "
                + readings.map { "\(Self.fmt($0.value)) \($0.unit) ±\(Self.fmt($0.plusMinus))" }
                    .joined(separator: " / "))

            for (budgetLabel, maxTokens, maxURLs) in Self.payloadSizes {
                let response = try await GroundingTestSupport.fetchGrounding(
                    query: shape.braveQuery, key: brave,
                    maxTokens: maxTokens, maxURLs: maxURLs)
                cached.append(Cache(shape: shape, budgetLabel: budgetLabel,
                                    payload: BraveWebSearchTool.contextXML(from: response),
                                    readings: readings,
                                    sources: response.grounding.generic.count))
            }
        }

        // ── Phase 2: model outermost, so each one loads exactly once ──────────
        for (armLabel, provider, key) in arms {
            for c in cached {
                transcript.append("\n### \(c.shape.label) · \(c.budgetLabel) · \(armLabel) — \(c.sources) sources\n")
                var correct = 0, answered = 0
                var errors: [Double] = [], figureCounts: [Int] = []
                for i in 1...trials {
                    let reply = await GroundingTestSupport.ask(
                        provider: provider, apiKey: key, payload: c.payload, prompt: c.shape.prompt)
                    let scored = Self.score(reply: reply, question: c.shape.prompt, against: c.readings)
                    if let s = scored {
                        answered += 1
                        if s.correct { correct += 1 }
                        errors.append(s.error)
                        figureCounts.append(s.figures)
                    }
                    transcript.append(
                        "- **\(armLabel) \(i)** · "
                        + (scored.map { "correct=\($0.correct) closest=\(Self.fmt($0.error)) off \(Self.fmt($0.matched.value))\($0.matched.unit) · \($0.figures) figures" }
                           ?? "no figures in reply")
                        + "\n  > " + reply.replacingOccurrences(of: "\n", with: " ").prefix(220))
                }
                summary.append(Cell(
                    shape: c.shape.label, budget: c.budgetLabel, arm: armLabel,
                    correct: correct, answered: answered, trials: trials,
                    medianError: Self.median(errors),
                    medianFigures: Self.median(figureCounts.map(Double.init)),
                    numberDense: c.shape.numberDense))
            }
        }

        Self.writeReport(trials: trials, summary: summary,
                         truthNotes: truthNotes, transcript: transcript)

        // No pass/fail verdict on the hypothesis: "compact 2/3 vs full 1/3" IS
        // the finding, and collapsing a measurement into an assertion is how a
        // harness starts lying to you. The only real failure is an experiment
        // that measured nothing at all.
        #expect(!summary.isEmpty, "no cells measured — every ground-truth authority was unreachable")
    }

    // MARK: - Reporting

    struct Cell {
        let shape, budget, arm: String
        let correct, answered, trials: Int
        let medianError, medianFigures: Double
        let numberDense: Bool
    }

    private static func fmt(_ d: Double) -> String {
        d == d.rounded() && abs(d) < 1e9 ? String(Int(d.rounded())) : String(format: "%.2f", d)
    }

    private static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return .nan }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    private static func writeReport(trials: Int, summary: [Cell],
                                    truthNotes: [String], transcript: [String]) {
        guard let dir = env["SWEEP_REPORT_DIR"], !dir.isEmpty else { return }
        var md = "# does the compact budget improve SOURCE SELECTION?\n\n"
        md += "\(trials) trials per cell · one Brave fetch per (shape, budget), that exact\n"
        md += "payload given to every model · same persona, same engine, same tool.\n\n"
        md += "Scored against a THIRD PARTY — neither Brave nor the model — fetched live at\n"
        md += "run time. \"correct\" = the reply's closest distinctive figure falls inside the\n"
        md += "authority's tolerance band. `figures` is how many distinctive numbers the reply\n"
        md += "contained: a high count on a number-dense shape means a hit could be luck, so\n"
        md += "it is reported instead of assumed away.\n\n"
        md += "## ground truth, this run\n\n" + truthNotes.joined(separator: "\n") + "\n\n"
        md += "| shape | budget | model | correct | scorable | median error | median figures |\n"
        md += "|---|---|---|---|---|---|---|\n"
        // Measured model-outermost (so each model loads once), but READ
        // shape-outermost — the comparison the table exists to support is
        // compact-vs-full within a shape, and scattering those rows across the
        // table to match execution order would hide it. Execution order is an
        // efficiency concern; presentation order is an honesty one.
        let shapeOrder = Dictionary(uniqueKeysWithValues: shapes.enumerated().map { ($1.label, $0) })
        let ordered = summary.enumerated().sorted {
            let (l, r) = ($0.element, $1.element)
            if l.shape != r.shape { return (shapeOrder[l.shape] ?? 0) < (shapeOrder[r.shape] ?? 0) }
            if l.budget != r.budget { return l.budget < r.budget }
            return $0.offset < $1.offset          // arms keep their declared order
        }.map(\.element)
        for c in ordered {
            let dense = c.numberDense ? " ⚠︎" : ""
            md += "| \(c.shape)\(dense) | \(c.budget) | \(c.arm) | \(c.correct)/\(c.trials) "
            md += "| \(c.answered)/\(c.trials) | \(fmt(c.medianError)) | \(fmt(c.medianFigures)) |\n"
        }
        md += "\n⚠︎ = number-dense shape; treat a hit with many figures as weak evidence.\n"
        md += "\n## every reply, verbatim\n" + transcript.joined(separator: "\n") + "\n"
        try? md.write(toFile: dir + "/source_selection.md", atomically: true, encoding: .utf8)
    }
}

// MARK: - Scorer tests
//
// The tolerance-band scorer is new, so it gets the same treatment as the one it
// builds on: its own tests, because a grounding claim is only as good as the
// instrument behind it.

@Suite("Source-selection scorer")
struct SourceSelectionScorerTests {
    typealias Reading = SourceSelectionTests.Reading

    private static let btc = [Reading(value: 64714.225, plusMinus: 64714.225 * 0.03, unit: "USD")]

    @Test func acceptsAFreshPriceInsideTheBand() {
        let s = SourceSelectionTests.score(
            reply: "Bitcoin is currently trading at about $64,890 USD.",
            question: "What is the current price of bitcoin in USD?", against: Self.btc)
        #expect(s?.correct == true)
    }

    @Test func rejectsAStalePriceFromAnOldSource() {
        // The failure this whole harness exists to catch: the model grounded
        // itself, on the wrong page.
        let s = SourceSelectionTests.score(
            reply: "Bitcoin is currently trading at about $118,432 USD.",
            question: "What is the current price of bitcoin in USD?", against: Self.btc)
        #expect(s?.correct == false)
    }

    @Test func acceptsEitherTemperatureUnit() {
        let readings = [Reading(value: 80.6, plusMinus: 5, unit: "°F"),
                        Reading(value: 27, plusMinus: 2.78, unit: "°C")]
        let q = "What is the weather in New York NY 10001 right now?"
        for reply in ["It is currently 81°F.", "It is currently 27°C."] {
            #expect(SourceSelectionTests.score(reply: reply, question: q, against: readings)?.correct == true)
        }
    }

    @Test func latexFiguresAreScoredLikeAnyOther() {
        // gemma4 writes temperatures as LaTeX. The figure extractor is shared
        // with `GroundingTestSupport`, which was fixed for exactly this — this
        // pins that the tolerance layer didn't reintroduce a unit-anchored regex.
        let readings = [Reading(value: 80.6, plusMinus: 5, unit: "°F")]
        let s = SourceSelectionTests.score(
            reply: #"**Temperature:** $79^\circ\text{F}$"#,
            question: "weather?", against: readings)
        #expect(s?.correct == true)
    }

    @Test func figuresFromTheQuestionCannotScore() {
        // 10001 is in the prompt. A reply that only echoes it has answered
        // nothing, and must not be scorable at all.
        let readings = [Reading(value: 10001, plusMinus: 100, unit: "nonsense")]
        let s = SourceSelectionTests.score(
            reply: "I do not have current data for 10001.",
            question: "What is the weather in New York NY 10001 right now?", against: readings)
        #expect(s == nil)
    }

    @Test func aReplyWithNoFiguresIsUnscorable_notWrong() {
        // The distinction matters: "refused" and "answered wrongly" are
        // different findings, and folding them together would let a model that
        // never answers look identical to one that answers badly.
        #expect(SourceSelectionTests.score(
            reply: "I recommend checking a weather service.",
            question: "weather?", against: Self.btc) == nil)
    }

    @Test func nearestReadingWinsInUnitsOfTolerance() {
        // A reply naming both a right and a wrong number scores on the closest.
        // Stated plainly because it is the scorer's known soft spot: on a
        // number-dense reply this is generous, which is why the report carries
        // the figure count next to every hit.
        let readings = [Reading(value: 163.82, plusMinus: 3.28, unit: "JPY")]
        let s = SourceSelectionTests.score(
            reply: "The rate was 150.10 in 2024; today it is 163.90.",
            question: "usd to jpy?", against: readings)
        #expect(s?.correct == true)
    }
}
