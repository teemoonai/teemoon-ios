//
//  ChatScrollEdge.swift
//  teemoon
//

import SwiftUI

extension View {
    /// iOS chrome is not this modifier. SwiftUI still walks a representable
    /// and would attach an edge effect to the collection view; both edges
    /// are viewport-fixed overlays on `ChatChrome`.
    @ViewBuilder func chatScrollEdgeEffects() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .top)
                .scrollEdgeEffectHidden(true, for: .bottom)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
