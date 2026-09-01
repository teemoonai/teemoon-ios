//
//  TitleBlockTruncationSpikeTests.swift
//  teemoonTests
//
//  Spike: does "option A" (provider ·
//  model folded into the existing status line) actually survive the principal's
//  width, or does the thing the feature exists to show get truncated away?
//
//  This renders the REAL E2EETitleBlock inside a REAL UINavigationBar, flanked
//  by the same leading/trailing buttons ChatView uses, so the width the title
//  gets is the width it gets in the app — not a guess.
//

import XCTest
import SwiftUI
@testable import teemoon

#if os(iOS)

@MainActor
final class TitleBlockTruncationSpikeTests: XCTestCase {

    /// Where the composites land, for eyeballing.
    private static let outDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("titleblock-spike", isDirectory: true)

    private struct Scenario {
        let label: String
        let title: String
        let provider: Provider?
        let state: AttestationState
        var hardFailure = false
        var mismatch = 0
    }

    private func provider(_ name: String, _ model: String) -> Provider {
        Provider(name: name, endpoint: "https://example.com/v1", model: model)
    }

    private var scenarios: [Scenario] {
        let near = provider("near.ai", "zai-org/GLM-5.1-FP8")
        let ollama = provider("ollama", "unsloth/gemma-4-E4B-it-qat-GGUF:UD-Q4_K_XL")
        let short = provider("ollama", "gemma4:e2b")
        return [
            .init(label: "near.ai + e2ee ok (THE default case)",
                  title: "gold and bitcoin", provider: near, state: .ok),
            .init(label: "near.ai + verifying",
                  title: "gold and bitcoin", provider: near, state: .verifying),
            .init(label: "near.ai + soft degrade",
                  title: "gold and bitcoin", provider: near, state: .degraded),
            .init(label: "near.ai + HARD BLOCK (red must survive)",
                  title: "gold and bitcoin", provider: near, state: .degraded, hardFailure: true),
            .init(label: "near.ai + reply mismatch (red)",
                  title: "gold and bitcoin", provider: near, state: .ok, mismatch: 1),
            .init(label: "local ollama, long slug, no e2ee",
                  title: "gold and bitcoin", provider: ollama, state: .none),
            .init(label: "local ollama, short slug, no e2ee",
                  title: "gold and bitcoin", provider: short, state: .none),
            .init(label: "long title + near.ai + e2ee",
                  title: "Whats the best order to watch dragonball z for a newcomer",
                  provider: near, state: .ok),
            .init(label: "no provider (today's behaviour)",
                  title: "chat", provider: nil, state: .ok),
        ]
    }

    // MARK: - Rendering

    /// Renders the block at a fixed principal width.
    ///
    /// Note on method: the first cut of this spike tried to host the block in a
    /// real `UINavigationBar` (both bare and under a `UINavigationController`) so
    /// the width would be measured rather than computed. On iOS 26 that does not
    /// work offscreen — the bar's `NavigationBarPlatterContainer` never populates
    /// without a live screen, and the hosted title collapses to its 34pt lock +
    /// chevron. So the principal width here is **computed**, per `principalWidth`
    /// below, and the block is laid out against it directly. The truncation
    /// behaviour is real; the width it is truncating against is an estimate.
    private func render(_ s: Scenario, principal: CGFloat, dark: Bool) -> UIImage {
        let block = E2EETitleBlock(title: s.title,
                                   state: s.state,
                                   provider: s.provider,
                                   isHardFailure: s.hardFailure,
                                   mismatchCount: s.mismatch)
            .frame(width: principal)
            .padding(.vertical, 2)
            .background(dark ? Color.black : Color.white)
            .environment(\.colorScheme, dark ? .dark : .light)
            .tint(.orange)

        let renderer = ImageRenderer(content: block)
        renderer.scale = 3
        return renderer.uiImage ?? UIImage()
    }

    /// What the principal actually gets on a phone: the bar's width minus, on
    /// each side, the 16pt layout margin, the ~44pt Liquid Glass bar button, and
    /// the ~8pt gap before the title. Symmetric, because UIKit centres the title
    /// view between the two item groups.
    private func principalWidth(forScreen w: CGFloat) -> CGFloat {
        w - 2 * (16 + 44 + 8)
    }

    // MARK: - The spike

    func testRenderTruncationSpike() throws {
        try? FileManager.default.createDirectory(at: Self.outDir,
                                                 withIntermediateDirectories: true)
        // iPhone 17 Pro is 402pt; 375 is the small phone still in support. If
        // option A breaks, it breaks first at 375.
        let screens: [CGFloat] = [402, 375]

        for dark in [true, false] {
            for screen in screens {
                let principal = principalWidth(forScreen: screen)
                print("[spike] screen=\(Int(screen)) → principal=\(Int(principal))pt")
                let tiles = scenarios.map { (s: Scenario) -> (String, UIImage) in
                    (s.label, render(s, principal: principal, dark: dark))
                }
                let img = compose(tiles, width: principal, dark: dark)
                let url = Self.outDir.appendingPathComponent(
                    "spike-\(Int(screen))-\(dark ? "dark" : "light").png")
                try img.pngData()?.write(to: url)
                print("[spike] wrote \(url.path)")
            }
        }
    }

    /// Stacks the strips with a caption above each, into one reviewable sheet.
    private func compose(_ tiles: [(String, UIImage)], width: CGFloat, dark: Bool) -> UIImage {
        let captionH: CGFloat = 16
        let gap: CGFloat = 12
        let inset: CGFloat = 12
        let rowH = (tiles.first?.1.size.height ?? 44) + captionH + gap
        // Wide enough for the captions; the block itself is drawn at exactly
        // `width`, with a hairline marking where the principal ends so any
        // truncation is unmistakable.
        let canvasW = max(width + inset * 2, 460)
        let total = CGSize(width: canvasW, height: rowH * CGFloat(tiles.count) + gap)

        return UIGraphicsImageRenderer(size: total).image { ctx in
            (dark ? UIColor.black : UIColor.white).setFill()
            ctx.fill(CGRect(origin: .zero, size: total))
            var y: CGFloat = gap
            for (label, image) in tiles {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 9, weight: .semibold),
                    .foregroundColor: dark ? UIColor.systemTeal : UIColor.systemBlue,
                ]
                label.draw(at: CGPoint(x: inset, y: y), withAttributes: attrs)
                image.draw(at: CGPoint(x: inset, y: y + captionH))
                // principal boundary markers
                (dark ? UIColor.darkGray : UIColor.lightGray).setFill()
                ctx.fill(CGRect(x: inset - 1, y: y + captionH, width: 1, height: image.size.height))
                ctx.fill(CGRect(x: inset + width, y: y + captionH, width: 1, height: image.size.height))
                y += rowH
            }
        }
    }
}

#endif
