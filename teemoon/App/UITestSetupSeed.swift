//
//  UITestSetupSeed.swift
//  teemoon
//
//  A whole configuration in one launch variable, for capture rigs.
//
//  The other UITEST_SEED_* doors each seed ONE provider and remove the rest,
//  which is right for a test and wrong for a picture of the where sheet: its
//  whole point is several tiers side by side. The site's where frames were
//  therefore shot on a simulator set up by hand through the UI, and that state
//  rotted — a model retired, a device got erased, and nothing could rebuild it
//  except more tapping.
//
//  `UITEST_SEED_SETUP` is JSON:
//
//    { "active": "nearai",
//      "cloud":    [ { "preset": "nearai",    "model": "z-ai/glm-5.3-flash" },
//                    { "preset": "grok",      "model": "grok-4.7" } ],
//      "local":    [ { "name": "ollama", "endpoint": "https://…/v1/chat/completions",
//                      "model": "gemma4:e4b" } ],
//      "ondevice": [ "litert-community/gemma-4-E2B-it-litert-lm" ],
//      "warmOndevice": true }
//
//  Keys come from the host key files exactly as for the single-provider seeds
//  (UITestHostSecrets) — never from the environment. `active` is a cloud preset
//  name, a local name, or an on-device repo id. On-device entries only add the
//  row; the weights must already be on disk, as for UITEST_SEED_ONDEVICE_MODEL.
//
//  `warmOndevice` marks those models resident, so the phone row reads "warm" as
//  it does on a phone after its first answer. STAGED, like the 9:41 status bar:
//  the simulator cannot build a LiteRT engine, so it can never get there itself.
//  Same mechanism the previews use (LocalEngineResidency.previewing).
//
//  DEBUG + `--uitesting` only, and the provider store is in-memory under
//  --uitesting, so this cannot replace anyone's real configuration.
//

import Foundation
import os

#if DEBUG
struct UITestSetupSeed: Decodable {
    struct Cloud: Decodable { let preset: String; let model: String? }
    struct Local: Decodable { let name: String; let endpoint: String; let model: String }

    var active: String?
    var cloud: [Cloud] = []
    var local: [Local] = []
    var ondevice: [String] = []
    var warmOndevice = false

    private enum CodingKeys: String, CodingKey { case active, cloud, local, ondevice, warmOndevice }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        active = try c.decodeIfPresent(String.self, forKey: .active)
        cloud = try c.decodeIfPresent([Cloud].self, forKey: .cloud) ?? []
        local = try c.decodeIfPresent([Local].self, forKey: .local) ?? []
        ondevice = try c.decodeIfPresent([String].self, forKey: .ondevice) ?? []
        warmOndevice = try c.decodeIfPresent(Bool.self, forKey: .warmOndevice) ?? false
    }

    static func parse(_ json: String) -> UITestSetupSeed? {
        try? JSONDecoder().decode(UITestSetupSeed.self, from: Data(json.utf8))
    }

    /// Replaces the (in-memory) provider list with exactly this setup.
    /// Returns false when nothing in it could be seeded.
    @MainActor
    @discardableResult
    func apply(to store: ProviderStore,
               presetLookup: (String) -> Provider?) -> Bool {
        var seeded: [(key: String, provider: Provider)] = []

        for entry in cloud {
            guard var provider = presetLookup(entry.preset) else {
                os_log(.error, "[uitest] setup: unknown preset %{public}@", entry.preset)
                continue
            }
            if let model = entry.model, !provider.isFixedAnswerService { provider.model = model }
            seeded.append((entry.preset.lowercased(), provider))
        }
        for entry in local {
            seeded.append((entry.name.lowercased(),
                           Provider(name: entry.name, endpoint: entry.endpoint,
                                    model: entry.model, requiresAPIKey: false)))
        }
        for repoID in ondevice {
            guard let model = LocalModelCatalog.model(id: repoID) else {
                os_log(.error, "[uitest] setup: %{public}@ is not in the catalog", repoID)
                continue
            }
            seeded.append((repoID.lowercased(), Provider.local(model)))
        }
        guard !seeded.isEmpty else { return false }

        store.providers.removeAll()
        for (_, provider) in seeded { store.addProvider(provider) }

        for entry in cloud {
            guard let provider = presetLookup(entry.preset) else { continue }
            if let key = UITestHostSecrets.keyFromHostFile(preset: entry.preset) {
                try? store.setCredential(key, forEndpoint: provider.endpoint, legacyID: provider.id)
                os_log(.error, "[uitest] setup: %{public}@ key from host file", entry.preset)
            } else {
                os_log(.error, "[uitest] setup: no host-file key for %{public}@", entry.preset)
            }
        }

        if warmOndevice {
            let files = ondevice.compactMap(LocalModelCatalog.model(id:)).map(LocalModelStorage.file(for:))
            LocalEngineResidency.shared.update(resident: Set(files))
            os_log(.error, "[uitest] setup: %d on-device model(s) staged resident", files.count)
        }

        let activeKey = (active ?? seeded[0].key).lowercased()
        let pick = seeded.first(where: { $0.key == activeKey }) ?? seeded[0]
        store.currentProviderID = pick.provider.id.uuidString
        os_log(.error, "[uitest] setup: seeded %d provider(s), active %{public}@",
               seeded.count, pick.key)
        return true
    }
}
#endif
