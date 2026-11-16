//
//  PhotoPickerGatherTests.swift
//  teemoonTests
//
//  The picker's loaders finish on concurrent queues; every one's result must come back, in order.
//

#if os(iOS)
import Foundation
import Testing
@testable import teemoon

@Suite("Photo picker — gathering results")
struct PhotoPickerGatherTests {

    @Test func concurrentCompletionsAreNeitherLostNorReordered() async {
        let count = 400
        let expected: [Result<ImageIntake.Image, ImageIntake.Failure>] =
            (0..<count).map { .failure($0.isMultiple(of: 2) ? .corrupt : .unsupportedFormat) }
        for _ in 0..<20 {
            let got = await withCheckedContinuation { cont in
                PhotoPicker.Coordinator.gather(expected.map { result in
                    { done in DispatchQueue.global(qos: .userInitiated).async { done(result) } }
                }, onMain: { cont.resume(returning: $0) })
            }
            #expect(got == expected)
            if got != expected { break }
        }
    }
}
#endif
