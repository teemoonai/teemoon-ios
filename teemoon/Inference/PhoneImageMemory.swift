//
//  PhoneImageMemory.swift
//  teemoon
//
//  Whether a phone model may read images, decided at run time from memory (docs/IMAGES.md §4b,
//  conformance/wherefilter.json phoneImages, which Android runs too). Never a phone list or a RAM floor.
//

import Foundation
#if os(iOS)
import Darwin
#endif

enum PhoneImageMemory {

    /// The memory an image turn needs, MB, measured on the iPhone 16 Pro (§4b). A model not here never reads images.
    static let figures: [String: Int] = [
        "litert-community/gemma-4-E2B-it-litert-lm": 2980,
        "litert-community/gemma-4-E4B-it-litert-lm": 3510,
    ]

    static func needMB(modelID: String) -> Int? { figures[modelID] }

    /// Images per message as measured: E2B answered 10, E4B was measured to 4.
    static func maxImages(modelID: String) -> Int {
        modelID == "litert-community/gemma-4-E2B-it-litert-lm" ? 10 : 4
    }

    enum Turn: Equatable {
        case run, now(needMB: Int, availableMB: Int), permanent

        var kind: String {
            switch self {
            case .run: return "run"
            case .now: return "now"
            case .permanent: return "permanent"
            }
        }

        /// DRAFT strings (§4b). nil for a turn that runs.
        func text(model: String) -> String? {
            switch self {
            case .run: return nil
            case let .now(need, available):
                return "\(model) needs about \(PhoneImageMemory.gb(need)) GB free for images; this phone has "
                    + "\(PhoneImageMemory.gb(available)) GB free right now. close some apps and try again."
            case .permanent: return PhoneImageMemory.permanentLine(model: model)
            }
        }
    }

    static func permanentLine(model: String) -> String {
        "this phone doesn't have enough memory for images with \(model)."
    }

    /// The fixture's order: killed here or never fits is permanent, even when free memory is also short.
    static func turn(needMB: Int, ceilingMB: Int, availableMB: Int, killedBefore: Bool) -> Turn {
        if killedBefore || ceilingMB < needMB { return .permanent }
        if availableMB < needMB { return .now(needMB: needMB, availableMB: availableMB) }
        return .run
    }

    static func gb(_ mb: Int) -> String {
        let tenths = (mb * 10 + 512) / 1024
        return "\(tenths / 10).\(tenths % 10)"
    }

    static func reads(modelID: String, ceilingMB: Int, killed: Set<String>) -> Bool {
        guard let need = needMB(modelID: modelID) else { return false }
        return need <= ceilingMB && !killed.contains(modelID)
    }

    /// A phone model that has a figure but can never read images here: listed under "reads images" with the caption.
    static func refused(modelID: String, ceilingMB: Int, killed: Set<String>) -> Bool {
        needMB(modelID: modelID) != nil && !reads(modelID: modelID, ceilingMB: ceilingMB, killed: killed)
    }

    /// The "use <smaller model>" offer: a phone model ahead of this one in the catalog (smaller) that fits.
    static func smallerModel(than modelID: String, ceilingMB: Int, killed: Set<String>) -> String? {
        let ids = LocalModelCatalog.all.map(\.id)
        guard let index = ids.firstIndex(of: modelID) else { return nil }
        return ids[..<index].last { reads(modelID: $0, ceilingMB: ceilingMB, killed: killed) }
    }

    // MARK: - This phone

    /// The most memory the app could ever have, read once at launch. Unreadable (the simulator) is no limit, as
    /// `LocalMemory.check` does not block on a number it couldn't read.
    static let ceilingMB: Int = {
        let available = LocalMemory.availableMB()
        guard available > 0 else { return .max }
        return available + footprintMB()
    }()

    static func footprintMB() -> Int {
        #if os(iOS)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / (1024 * 1024)) : 0
        #else
        return 0
        #endif
    }

    static func reads(modelID: String) -> Bool {
        reads(modelID: modelID, ceilingMB: ceilingMB, killed: KillStore.shared.killed)
    }

    static func refused(modelID: String) -> Bool {
        refused(modelID: modelID, ceilingMB: ceilingMB, killed: KillStore.shared.killed)
    }

    static func smallerModel(than modelID: String) -> String? {
        smallerModel(than: modelID, ceilingMB: ceilingMB, killed: KillStore.shared.killed)
    }

    static func turn(modelID: String) -> Turn {
        guard let need = needMB(modelID: modelID) else { return .permanent }
        let available = LocalMemory.availableMB()
        return turn(needMB: need, ceilingMB: ceilingMB, availableMB: available > 0 ? available : .max,
                    killedBefore: KillStore.shared.killed.contains(modelID))
    }

    /// Image turns the OS killed on this phone. A mark is set before the turn and cleared after; a mark still there
    /// at the next launch was a kill. Never an automatic retry.
    final class KillStore {
        static let shared = KillStore(defaults: .standard)

        private let defaults: UserDefaults
        private let killedKey = "phoneImages.killed"
        private let inFlightKey = "phoneImages.inFlight"

        init(defaults: UserDefaults) { self.defaults = defaults }

        var killed: Set<String> { Set(defaults.stringArray(forKey: killedKey) ?? []) }

        func began(_ modelID: String) { defaults.set(modelID, forKey: inFlightKey) }
        func ended() { defaults.removeObject(forKey: inFlightKey) }

        /// Call once at launch, before any image turn.
        func settleAfterLaunch() {
            guard let model = defaults.string(forKey: inFlightKey) else { return }
            defaults.set(Array(killed.union([model])).sorted(), forKey: killedKey)
            defaults.removeObject(forKey: inFlightKey)
        }
    }
}
