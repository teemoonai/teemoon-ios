//
//  DisplayLinkPacer.swift
//  teemoon
//
//  Frame-rate-limits streaming text for rendering. A display-link tick
//  samples a source string at ~24 fps so Textual re-layouts don't run on
//  every token. Rendering cadence is a view concern — the model layer
//  (ChatGeneration) publishes tokens unthrottled.
//

import QuartzCore
import SwiftUI

/// Forwards CADisplayLink callbacks without retaining the owner.
private final class DisplayLinkProxy: NSObject {
    var tick: () -> Void = {}
    @objc func step(_: CADisplayLink) { tick() }
}

@Observable
@MainActor
final class DisplayLinkPacer {
    /// The paced text to render. Trails the source by at most one frame.
    private(set) var text = ""

    private var displayLink: CADisplayLink?
    private let proxy = DisplayLinkProxy()
    private var source: () -> String = { "" }

    /// Starts sampling `source` on a display link.
    func attach(to source: @escaping () -> String) {
        self.source = source
        text = source()
        guard displayLink == nil else { return }
        proxy.tick = { [weak self] in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                let latest = self.source()
                if self.text != latest { self.text = latest }
            }
        }
        #if os(macOS)
        let link = NSScreen.main!.displayLink(target: proxy,
                                              selector: #selector(DisplayLinkProxy.step(_:)))
        #else
        let link = CADisplayLink(target: proxy,
                                 selector: #selector(DisplayLinkProxy.step(_:)))
        #endif
        // WAS (15, 24, 24), and that ceiling — not markdown rendering — was what
        // made streaming look chunky. Measured on device (iPhone 16 Pro) against
        // a 17.5k-character fixture, sampling the pacer's own tick intervals:
        //
        //     range          updates/sec   p50      p95      p99
        //     15–24 fps          15.8     54.3ms   87.5ms   91.4ms
        //     60–120 fps        107.7      8.3ms   16.7ms   19.5ms
        //
        // A p95 of 87ms means one update in twenty landed a twelfth of a second
        // after the last. Textual keeps up fine — the renderer was never the
        // thing holding the frame rate down.
        //
        // 120 needs `CADisableMinimumFrameDurationOnPhone` in Info.plist; without
        // it iOS clamps the link to 60 on a ProMotion phone. Time Profiler put
        // the cost of 120 over 60 at 8414 vs 8402 samples — nothing, because a
        // tick that finds no new text does no work (see the != check above). The
        // link only exists while generating, so this doesn't run at idle.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Stops the display link after a final sync with the source.
    func detach() {
        text = source()
        displayLink?.invalidate()
        displayLink = nil
    }
}
