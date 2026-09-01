//
//  FollowGlide.swift
//  teemoon
//

#if os(iOS) || os(visionOS)

import UIKit

/// Linear follow interpolation. Extracted so the wrap-glide can be
/// asserted without standing up a collection view: a 22pt wrap at t=0
/// must still be mid-travel at 60ms and landed at 120ms.
struct FollowGlide: Equatable {
    var from: CGFloat
    var to: CGFloat
    var start: CFTimeInterval
    var duration: CFTimeInterval
    /// Ease the travel instead of running at constant velocity.
    ///
    /// A wrap-glide is the transcript moving on its OWN account, and linear
    /// is right there. A resize-glide is the transcript matching something
    /// else's animation, and the keyboard is eased — so a linear ride of the
    /// same duration drifts apart from it in the middle and snaps back at
    /// the end. Device trace: uniform 11.0/11.3pt steps against a keyboard
    /// that accelerates and decelerates. Reported as "not super smooth".
    var eased: Bool = false

    /// A wrap is ~22pt. Smaller than this is sub-pixel / kerning noise.
    static let startThreshold: CGFloat = 8
    /// Mid-glide growth under this is finished by the in-flight lerp
    /// plus the layout that runs when it ends. Above it we have fallen
    /// behind a burst and must retarget.
    static let retargetThreshold: CGFloat = 28

    static func shouldStart(delta: CGFloat, mode: PinningCollectionView.PinMode) -> Bool {
        mode == .throttled && delta > startThreshold
    }

    static func shouldRetarget(delta: CGFloat) -> Bool {
        delta > retargetThreshold
    }

    func progress(at now: CFTimeInterval) -> CGFloat {
        guard duration > 0 else { return 1 }
        return min(1, max(0, CGFloat((now - start) / duration)))
    }

    func offset(at now: CFTimeInterval) -> CGFloat {
        let t = progress(at: now)
        // Smoothstep: eases in and out, and is two multiplies rather than a
        // bezier solver. It is not UIKit's private keyboard curve to the
        // last decimal, but it is the same SHAPE, where linear is not.
        let shaped = eased ? t * t * (3 - 2 * t) : t
        return from + (to - from) * shaped
    }

    func isFinished(at now: CFTimeInterval) -> Bool { progress(at: now) >= 1 }
}

#endif
