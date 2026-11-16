//
//  ShareViewController.swift
//  teemoonShare
//
//  "teemoon" in the share sheet (docs/SHARE_IN.md, option B). No composer: it copies into the App Group inbox and
//  jumps to teemoon. Policy is ShareJump's; this file only reads providers and draws a line. Never decode an image
//  here: the extension has about 120 MB.
//

import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let line = UILabel()
    private let note = UILabel()
    private let bar = UINavigationBar()
    private let item = UINavigationItem()
    private lazy var done = UIBarButtonItem(title: ShareJump.Line.done, style: .done, target: self,
                                            action: #selector(doneTapped))

    override func viewDidLoad() {
        super.viewDidLoad()
        // The app is dark-only with its orange accent; the extension must not render as a light system sheet.
        overrideUserInterfaceStyle = .dark
        view.tintColor = UIColor(named: "AccentColor")
        view.backgroundColor = .systemBackground
        for label in [line, note] {
            label.numberOfLines = 0
            label.textAlignment = .natural
            label.adjustsFontForContentSizeCategory = true
        }
        line.font = .preferredFont(forTextStyle: .body)
        note.font = .preferredFont(forTextStyle: .footnote)
        note.textColor = .secondaryLabel
        line.accessibilityIdentifier = "share.line"
        note.accessibilityIdentifier = "share.note"
        done.accessibilityIdentifier = "share.done"
        bar.items = [item]
        bar.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [line, note])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Scrolls so nothing clips at AX5 on a small phone.
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        view.addSubview(scroll)
        view.addSubview(bar)
        let content = scroll.contentLayoutGuide, frame = scroll.frameLayoutGuide
        let fillsFrame = content.heightAnchor.constraint(equalTo: frame.heightAnchor)
        fillsFrame.priority = .defaultLow
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.widthAnchor.constraint(equalTo: frame.widthAnchor),
            content.heightAnchor.constraint(greaterThanOrEqualTo: frame.heightAnchor),
            fillsFrame,
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
        ])
        Task { await run() }
    }

    @objc private func doneTapped() { finish() }

    private func run() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let reads = providers.compactMap { provider in
            ShareJump.kind(of: provider.registeredTypeIdentifiers).map { (provider, $0) }
        }
        if let refusal = ShareJump.precheck(reads.map(\.1)) { return show(refusal, finished: true) }

        let progress = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(ShareJump.progressDelay))
            if !Task.isCancelled { self?.show(ShareJump.Line.opening) }
        }
        let scratch = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var items: [ShareInbox.Item] = [], unreadable = 0
        for (provider, kind) in reads {
            switch kind {
            case .image(let type):
                switch await Self.copy(provider, type: type, into: scratch) {
                case .file(let url): items.append(.image(url))
                case .tooLarge:
                    progress.cancel()
                    return show(ShareJump.Line.overCap, finished: true)
                case .failed: unreadable += 1
                }
            case .link:
                if let url = await Self.url(from: provider) { items.append(.link(url)) }
            case .text:
                if let text = await Self.text(from: provider) { items.append(.text(text)) }
            }
        }
        let inbox = ShareInbox.inExtension()
        let result = inbox?.write(items, unreadable: unreadable) ?? .failure(.unreadable)
        progress.cancel()

        let jumps = ShareJump.shouldJump(flag: Bundle.main.object(forInfoDictionaryKey: "SHARE_OPENS_APP"))
        switch ShareJump.step(after: result, unreadable: unreadable, jumps: jumps) {
        case .refuse(let refusal):
            show(refusal, finished: true)
        case .fallback(_, let unread):
            show(ShareJump.Line.fallback, note: unread, finished: true)
        case .open(let id, let unread):
            if unread != nil { show(ShareJump.Line.opening, note: unread) }
            let opened = await open(id)
            let taken = opened ? await Self.taken(id, from: inbox) : false
            if ShareJump.outcome(jumps: jumps, openReturned: opened, appBecameActive: taken) == .opened {
                finish()
            } else {
                show(ShareJump.Line.fallback, note: unread, finished: true)
            }
        }
    }

    private func show(_ text: String, note: String? = nil, finished: Bool = false) {
        let changed = line.text != text || self.note.text != note
        line.text = text
        self.note.text = note
        self.note.isHidden = note == nil
        item.rightBarButtonItem = finished ? done : nil
        if changed {
            UIAccessibility.post(notification: .announcement, argument: [text, note].compactMap { $0 }.joined(separator: " "))
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    // MARK: - The jump

    /// The responder-chain open (docs/SHARE_IN.md step 2): unsupported, so a false or a hang falls back.
    private func open(_ id: UUID) async -> Bool {
        guard let appID = Bundle.main.bundleIdentifier.flatMap({ ShareInbox.appBundleID(extensionBundleID: $0) }),
              let url = ShareInbox.link(for: id, bundleID: appID) else { return false }
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                return await withCheckedContinuation { done in
                    application.open(url, options: [:]) { done.resume(returning: $0) }
                }
            }
            responder = current.next
        }
        return false
    }

    /// teemoon took the entry (it deletes the folder) within `ShareJump.openWait`.
    private static func taken(_ id: UUID, from inbox: ShareInbox?) async -> Bool {
        guard let inbox else { return false }
        let deadline = Date().addingTimeInterval(ShareJump.openWait)
        while Date() < deadline {
            if !inbox.contains(id) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return !inbox.contains(id)
    }

    // MARK: - Reading what was shared

    private enum Copy { case file(URL), tooLarge, failed }

    /// The provider's file, copied before its handler returns (the system deletes it after). Size is checked first.
    private static func copy(_ provider: NSItemProvider, type: String, into dir: URL) async -> Copy {
        await withCheckedContinuation { done in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                    return done.resume(returning: .failed)
                }
                guard size <= ShareInbox.maxImageBytes else { return done.resume(returning: .tooLarge) }
                let ext = url.pathExtension.isEmpty ? (UTType(type)?.preferredFilenameExtension ?? "img") : url.pathExtension
                let target = dir.appending(path: UUID().uuidString + "." + ext)
                do {
                    try FileManager.default.copyItem(at: url, to: target)
                    done.resume(returning: .file(target))
                } catch {
                    done.resume(returning: .failed)
                }
            }
        }
    }

    private static func url(from provider: NSItemProvider) async -> URL? {
        guard let item = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) else { return nil }
        switch item {
        case let url as URL: return url.isFileURL ? nil : url
        case let data as Data: return URL(dataRepresentation: data, relativeTo: nil)
        case let string as String: return URL(string: string)
        default: return nil
        }
    }

    private static func text(from provider: NSItemProvider) async -> String? {
        guard let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) else { return nil }
        switch item {
        case let text as String: return text
        case let text as NSAttributedString: return text.string
        case let data as Data: return String(data: data, encoding: .utf8)
        default: return nil
        }
    }
}
