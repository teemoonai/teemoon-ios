//
//  ImagePickers.swift
//  teemoon
//
//  The system photo picker and camera, as thin bridges (docs/IMAGES.md §2, §4a). Neither decides
//  anything: the picker hands back JPEG (or PNG) bytes and the camera hands back pixels, and
//  ImageIntake does the rest. The picker asks only for a JPEG representation, so HEIC, Live Photo
//  and RAW originals are transcoded by the system outside teemoon and never reach it.
//

#if os(iOS)
import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// What the picker may hand teemoon, in order of preference: never the original container.
enum PickedImageTypes {
    static let accepted: [(UTType, ImageIntake.Format)] = [(.jpeg, .jpeg), (.png, .png)]

    /// The type to request from a provider that offers `registered`, or nil (the image is refused).
    static func choice(registered: [String]) -> (UTType, ImageIntake.Format)? {
        accepted.first { type, _ in registered.contains(type.identifier) }
            ?? (registered.isEmpty ? nil : accepted.first)   // Photos transcodes to JPEG on request
    }
}

struct PhotoPicker: UIViewControllerRepresentable {
    let limit: Int
    /// How many were picked, at once, and the load that hands their results back on main.
    let onPicked: (Int, ChatViewModel.ImageLoad) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = max(1, limit)
        config.preferredAssetRepresentationMode = .compatible
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: (Int, ChatViewModel.ImageLoad) -> Void
        init(onPicked: @escaping (Int, ChatViewModel.ImageLoad) -> Void) { self.onPicked = onPicked }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else { return }
            let loaders = results.map { result in
                { (done: @escaping (Result<ImageIntake.Image, ImageIntake.Failure>) -> Void) in
                    let provider = result.itemProvider
                    guard let (type, format) = PickedImageTypes.choice(registered: provider.registeredTypeIdentifiers) else {
                        done(.failure(.unsupportedFormat))
                        return
                    }
                    provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                        // The file exists only during this callback: read it now, decode off it after.
                        let bytes = url.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }.map { Data($0) }
                        DispatchQueue.global(qos: .userInitiated).async {
                            done(bytes.map { ImageIntake.fromBytes($0, declared: format) } ?? .failure(.corrupt))
                        }
                    }
                }
            }
            onPicked(loaders.count) { Self.gather(loaders, onMain: $0) }
        }

        /// Starts every loader, whose `done` may fire on any queue, and hands the results back on main in order.
        static func gather(_ loaders: [(@escaping (Result<ImageIntake.Image, ImageIntake.Failure>) -> Void) -> Void],
                           onMain: @escaping ([Result<ImageIntake.Image, ImageIntake.Failure>]) -> Void) {
            let group = DispatchGroup()
            // Writes run one at a time here: LockedBox's subscript write is not atomic.
            let serial = DispatchQueue(label: "teemoon.picker.collect")
            let collected = LockedBox<[Int: Result<ImageIntake.Image, ImageIntake.Failure>]>([:])
            for (n, load) in loaders.enumerated() {
                group.enter()
                load { result in
                    serial.async {
                        collected.value[n] = result
                        group.leave()
                    }
                }
            }
            group.notify(queue: .main) {
                onMain(collected.value.sorted { $0.key < $1.key }.map(\.value))
            }
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    /// `.camera` in the app; tests use `.photoLibrary` (the simulator has no camera).
    var source: UIImagePickerController.SourceType = .camera
    /// The load of the one photo taken, started as the camera hands it over.
    let onTaken: (ChatViewModel.ImageLoad) -> Void

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = source
        picker.mediaTypes = [UTType.image.identifier]
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onTaken: onTaken) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onTaken: (ChatViewModel.ImageLoad) -> Void
        init(onTaken: @escaping (ChatViewModel.ImageLoad) -> Void) { self.onTaken = onTaken }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            picker.dismiss(animated: true)
            onTaken { done in Self.load(info, done: { done([$0]) }) }
        }

        private static func load(_ info: [UIImagePickerController.InfoKey: Any],
                                 done onTaken: @escaping (Result<ImageIntake.Image, ImageIntake.Failure>) -> Void) {
            guard let photo = info[.originalImage] as? UIImage else { onTaken(.failure(.corrupt)); return }
            // Drawn upright at the kept size into teemoon's own bitmap: pixels, no bytes parsed, no metadata.
            let (w, h) = ImageIntake.scaled(width: Int(photo.size.width), height: Int(photo.size.height),
                                            longSide: ImageIntake.longSide)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let upright = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { _ in
                photo.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            guard let cg = upright.cgImage else { onTaken(.failure(.corrupt)); return }
            DispatchQueue.global(qos: .userInitiated).async { [onTaken] in
                let result = ImageIntake.fromPixels(cg)
                DispatchQueue.main.async { onTaken(result) }
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { picker.dismiss(animated: true) }
    }
}

/// Camera permission, asked only when the user taps take photo.
enum CameraAccess {
    static let deniedMessage = "camera access is off. turn it on in settings to take photos."

    /// Calls back on the main queue with whether the camera may be opened.
    static func request(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in DispatchQueue.main.async { done(granted) } }
        default: done(false)
        }
    }
}
#endif
