//
//  BackgroundWork.swift
//  teemoon
//
//  UIKit background-task bracketing so Inference does not import UIKit.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum BackgroundWork {
    #if canImport(UIKit) && !os(watchOS)
    typealias Token = UIBackgroundTaskIdentifier
    #else
    typealias Token = UInt
    #endif

    static func begin(_ name: String, onExpire: @escaping @Sendable () -> Void) -> Token? {
        #if os(iOS)
        return UIApplication.shared.beginBackgroundTask(withName: name) {
            onExpire()
        }
        #else
        return nil
        #endif
    }

    static func end(_ token: Token?) {
        #if os(iOS)
        if let token { UIApplication.shared.endBackgroundTask(token) }
        #endif
    }
}
