import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Unofficial fork: UIKit Files picker (as KSign/Feather use). `asCopy: true` hands us a
/// copy in our own tmp, so no security-scoped access is needed and every file is selectable.
struct DocumentPicker: UIViewControllerRepresentable {
    var types: [UTType] = [.item]
    let onPick: (URL) -> Void
    var onCancel: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        init(_ parent: DocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { parent.onCancel(); return }
            parent.onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}

enum BuildInfo {
    static var text: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let sha = (info["TVSGitSHA"] as? String).flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 } ?? "local"
        return "TV Sideload \(version) (\(build)) · \(sha)"
    }
}
