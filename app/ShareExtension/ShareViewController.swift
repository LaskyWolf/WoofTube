import UIKit
import UniformTypeIdentifiers

/// Hands a shared YouTube link to WoofTube by opening it with the app's own scheme.
final class ShareViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await handOver() }
    }

    private func handOver() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?.flatMap { $0.attachments ?? [] } ?? []
        var shared: URL?
        for provider in providers where shared == nil {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                shared = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                // Chat apps often share the link inside a sentence.
                shared = Self.firstLink(in: text)
            }
        }
        if let shared, let link = Self.appLink(for: shared) { open(link) }
        extensionContext?.completeRequest(returningItems: nil)
    }

    private static func firstLink(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return detector?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.url
    }

    /// wooftube://www.youtube.com/watch?v=… reads like the web address, so the app parses it the same way.
    private static func appLink(for url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard parts.scheme == "https" || parts.scheme == "http" else { return url }
        parts.scheme = "wooftube"
        return parts.url
    }

    /// An extension can't reach UIApplication.shared, but the app object is still at the end of the responder chain.
    // ponytail: not an official API. If iOS stops passing the link on, copy it and paste it in WoofTube's search instead.
    private func open(_ url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url)
                return
            }
            responder = current.next
        }
    }
}
