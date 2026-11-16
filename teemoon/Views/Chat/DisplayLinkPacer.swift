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
    /// The text to render: the source through StreamRevealFeed ("whole if quick").
    private(set) var text = ""
    /// Where in `text` a paragraph that appeared whole is fading in.
    private(set) var fadeFrom: Int?
    /// Bumps once per frame in which the source changed. The stall rule reads this, not `text`.
    private(set) var arrivals = 0

    private var feed = StreamRevealFeed()

    private var displayLink: CADisplayLink?
    private let proxy = DisplayLinkProxy()
    private var source: () -> String = { "" }
    private var onDevice: () -> Bool = { false }

    /// Starts sampling `source` on a display link. `onDevice` is read when the answer's first character arrives.
    func attach(onDevice: @escaping () -> Bool = { false }, to source: @escaping () -> String) {
        self.source = source
        self.onDevice = onDevice
        step()
        guard displayLink == nil else { return }
        proxy.tick = { [weak self] in
            MainActor.assumeIsolated { [weak self] in self?.step() }
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

    private func step() {
        let shown = feed.frame(source: source(), origin: onDevice() ? .onDevice : .cloud, at: CACurrentMediaTime() * 1000)
        if text != shown.text { text = shown.text }
        if fadeFrom != shown.fadeFrom { fadeFrom = shown.fadeFrom }
        if arrivals != feed.arrivals { arrivals = feed.arrivals }
    }

    /// Stops the display link after a final sync with the source: everything that arrived shows.
    func detach() {
        text = source()
        fadeFrom = nil
        displayLink?.invalidate()
        displayLink = nil
    }
}
