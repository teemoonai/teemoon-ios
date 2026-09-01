//
//  TranscriptHandoffSizing.swift
//  teemoon
//

#if os(iOS) || os(visionOS)

import CoreGraphics

/// First-paint floor for the persisted reply. See TranscriptHandoffSizingTests.
enum TranscriptHandoffSizing {
    /// Prefer the persisted measure when it is in the same ballpark as the
    /// stream (the reasoning fold). A first hosting measure of a few hundred
    /// points against a multi-thousand stream is unfitted — keep the seed.
    static func floor(seed: CGFloat, fitted: CGFloat) -> CGFloat {
        if fitted > 200 {
            // Unfitted first measures are hundreds against a multi-thousand
            // stream (device: 400 vs 6663). A real fold is within a few
            // percent (6447 vs 6663). A 2.4k stream vs 276pt fixture row
            // is the latter class.
            if seed > 2000, fitted < 1000 { return seed }
            return fitted
        }
        return seed
    }
}

#endif
