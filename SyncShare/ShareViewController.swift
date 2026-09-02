import UIKit
import UniformTypeIdentifiers
import SwiftData

@objc(ShareViewController)
final class ShareViewController: UIViewController, UITextViewDelegate {
    private let paper = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.090, green: 0.102, blue: 0.094, alpha: 1)
        : UIColor(red: 0.957, green: 0.945, blue: 0.922, alpha: 1) }
    private let raised = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.145, green: 0.160, blue: 0.149, alpha: 1)
        : UIColor.white }
    private let ink = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.910, green: 0.925, blue: 0.910, alpha: 1)
        : UIColor(red: 0.165, green: 0.286, blue: 0.220, alpha: 1) }
    private let muted = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.62, green: 0.66, blue: 0.63, alpha: 1)
        : UIColor(red: 0.35, green: 0.38, blue: 0.36, alpha: 1) }
    private let line = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.12)
        : UIColor(red: 0.165, green: 0.286, blue: 0.220, alpha: 0.14) }
    private let selectedLabel = UIColor { $0.userInterfaceStyle == .dark ? .black : .white }

    private let titleLabel = UILabel()
    private let preview = UILabel()
    private let notes = UITextView()
    private let notesPlaceholder = UILabel()
    private let collectionLabel = UILabel()
    private let chips = UIStackView()
    private let saveButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)

    private var started = false
    private var urlString: String?
    private var sharedText: String?
    private var mediaName: String?
    private var slideNames: [String] = []
    private var collectionNames: [String] = []
    private var selectedCollection: String?
    private var chipButtons: [UIButton] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = paper
        preferredContentSize = CGSize(width: 0, height: 460)
        buildForm()
        applyTheme()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: ShareViewController, _) in
            self.applyTheme()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        Task { await prepare() }
    }

    private func buildForm() {
        titleLabel.text = "Save to sync"
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)

        preview.font = .systemFont(ofSize: 14)
        preview.numberOfLines = 2
        preview.text = "Getting the link…"

        notes.font = .systemFont(ofSize: 16)
        notes.layer.cornerRadius = 14
        notes.layer.borderWidth = 1
        notes.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        notes.delegate = self
        notes.heightAnchor.constraint(equalToConstant: 88).isActive = true

        notesPlaceholder.text = "Add a note (optional)"
        notesPlaceholder.font = .systemFont(ofSize: 16)
        notesPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        notes.addSubview(notesPlaceholder)
        NSLayoutConstraint.activate([
            notesPlaceholder.topAnchor.constraint(equalTo: notes.topAnchor, constant: 12),
            notesPlaceholder.leadingAnchor.constraint(equalTo: notes.leadingAnchor, constant: 15),
        ])

        collectionLabel.text = "Collection"
        collectionLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        chips.axis = .horizontal
        chips.spacing = 8
        chips.alignment = .center

        let chipScroll = UIScrollView()
        chipScroll.showsHorizontalScrollIndicator = false
        chipScroll.addSubview(chips)
        chips.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            chips.topAnchor.constraint(equalTo: chipScroll.topAnchor),
            chips.bottomAnchor.constraint(equalTo: chipScroll.bottomAnchor),
            chips.leadingAnchor.constraint(equalTo: chipScroll.leadingAnchor),
            chips.trailingAnchor.constraint(equalTo: chipScroll.trailingAnchor),
            chips.heightAnchor.constraint(equalTo: chipScroll.heightAnchor),
        ])
        chipScroll.heightAnchor.constraint(equalToConstant: 36).isActive = true

        saveButton.setTitle("Save", for: .normal)
        saveButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        saveButton.layer.cornerRadius = 14
        saveButton.isEnabled = false
        saveButton.alpha = 0.45
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        saveButton.heightAnchor.constraint(equalToConstant: 50).isActive = true

        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            titleLabel, preview, notes, collectionLabel, chipScroll, saveButton, cancelButton
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(16, after: titleLabel)
        stack.setCustomSpacing(8, after: collectionLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    private func prepare() async {
        let id = UUID()
        let providers = extensionContext?.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] } ?? []

        for provider in providers {
            if urlString == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let loaded = await loadURL(provider) {
                urlString = loaded
            }
            if urlString == nil, provider.hasItemConformingToTypeIdentifier("public.url"),
               let loaded = await loadURL(provider, type: "public.url") {
                urlString = loaded
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               let value = await loadText(provider) {
                if let link = SharedLinkParser.url(from: value) {
                    urlString = urlString ?? link
                } else {
                    sharedText = sharedText ?? value
                }
            }
            if mediaName == nil {
                mediaName = await loadMedia(provider, id: id)
            }
            let isMovie = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.mpeg4Movie.identifier)
                || provider.hasItemConformingToTypeIdentifier("public.mpeg-4")
            if !isMovie, let photos = await loadImages(provider) {
                for photo in photos where !slideNames.contains(photo) {
                    slideNames.append(photo)
                }
            }
        }

        if urlString == nil, let clip = UIPasteboard.general.string {
            urlString = SharedLinkParser.url(from: clip)
            if urlString == nil { sharedText = sharedText ?? clip }
        }

        if mediaName != nil {
            slideNames = []
        } else if let raw = urlString, let url = URL(string: raw), TikTokLink.isVideo(url) {
            slideNames = Array(slideNames.prefix(1))
        }

        let bags = ((try? ModelContext(LibraryContainer.shared).fetch(FetchDescriptor<CollectionItem>())) ?? [])
            .map(\.name)
            .filter { !$0.isEmpty }
        collectionNames = Array(Set(bags)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        await MainActor.run {
            preview.text = previewLine()
            rebuildChips()
            saveButton.isEnabled = true
            saveButton.alpha = 1
        }
    }

    private func previewLine() -> String {
        if let urlString, !urlString.isEmpty { return urlString }
        if let sharedText, !sharedText.isEmpty { return String(sharedText.prefix(80)) }
        if mediaName != nil { return "Video from Photos" }
        if !slideNames.isEmpty { return slideNames.count == 1 ? "Photo" : "\(slideNames.count) photos" }
        return "Nothing to save yet"
    }

    private func rebuildChips() {
        chipButtons.forEach { $0.removeFromSuperview() }
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        chipButtons = []
        let names = ["None"] + collectionNames + ["New"]
        for name in names {
            let button = UIButton(type: .system)
            var config = UIButton.Configuration.filled()
            config.title = name
            config.baseForegroundColor = ink
            config.baseBackgroundColor = raised
            config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var out = incoming
                out.font = .systemFont(ofSize: 14, weight: .medium)
                return out
            }
            config.background.cornerRadius = 16
            config.background.strokeWidth = 1
            config.background.strokeColor = line
            button.configuration = config
            button.addTarget(self, action: #selector(chipTapped(_:)), for: .touchUpInside)
            chips.addArrangedSubview(button)
            chipButtons.append(button)
        }
        styleChips()
    }

    private func chipIsOn(_ name: String) -> Bool {
        if name == "New" { return false }
        return (name == "None" && selectedCollection == nil) || name == selectedCollection
    }

    private func applyTheme() {
        view.backgroundColor = paper
        titleLabel.textColor = ink
        preview.textColor = muted
        notes.textColor = ink
        notes.backgroundColor = raised
        notes.layer.borderColor = line.cgColor
        notesPlaceholder.textColor = muted
        collectionLabel.textColor = muted
        saveButton.backgroundColor = ink
        saveButton.setTitleColor(paper, for: .normal)
        saveButton.tintColor = paper
        cancelButton.setTitleColor(ink, for: .normal)
        styleChips()
    }

    private func styleChips() {
        for button in chipButtons {
            let name = button.configuration?.title ?? button.title(for: .normal) ?? ""
            let on = chipIsOn(name)
            var config = button.configuration ?? .filled()
            config.baseForegroundColor = on ? selectedLabel : ink
            config.baseBackgroundColor = on ? ink : raised
            config.background.strokeColor = line
            button.configuration = config
            button.setNeedsUpdateConfiguration()
        }
    }

    @objc private func chipTapped(_ sender: UIButton) {
        let name = sender.configuration?.title ?? sender.title(for: .normal) ?? "None"
        if name == "New" {
            promptNewCollection()
            return
        }
        selectedCollection = name == "None" ? nil : name
        styleChips()
    }

    private func promptNewCollection() {
        let alert = UIAlertController(title: "New collection", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Name"
            field.autocapitalizationType = .words
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self] _ in
            let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let self, !name.isEmpty else { return }
            if !self.collectionNames.contains(where: { $0.compare(name, options: .caseInsensitive) == .orderedSame }) {
                self.collectionNames.append(name)
                self.collectionNames.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            }
            self.selectedCollection = name
            self.rebuildChips()
        })
        present(alert, animated: true)
    }

    @objc private func saveTapped() {
        saveButton.isEnabled = false
        let note = notes.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let bag = selectedCollection
        let urlString = self.urlString
        let text = sharedText
        let media = mediaName
        let slides = slideNames
        Task {
            var ok = false
            do {
                let context = ModelContext(LibraryContainer.shared)
                let save = try DirectSave.insert(
                    urlString: urlString,
                    text: text,
                    mediaFileName: media,
                    slideFileNames: slides,
                    notes: note.isEmpty ? nil : note,
                    collectionName: bag,
                    into: context
                )
                ok = true
                if let deepLink = CaptureDeepLink.make(
                    saveID: save.saveID,
                    urlString: urlString,
                    text: text
                ) {
                    openContainingApp(deepLink)
                }
            } catch {
                ok = false
            }
            await MainActor.run {
                if ok {
                    self.extensionContext?.completeRequest(returningItems: nil)
                } else {
                    self.saveButton.isEnabled = true
                    self.preview.text = "Couldn’t save. Try again."
                }
            }
        }
    }

    @objc private func cancelTapped() {
        extensionContext?.cancelRequest(withError: NSError(domain: "sync", code: 1))
    }

    func textViewDidChange(_ textView: UITextView) {
        notesPlaceholder.isHidden = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func loadURL(_ provider: NSItemProvider, type: String = UTType.url.identifier) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url.absoluteString)
                } else if let url = item as? NSURL {
                    continuation.resume(returning: url.absoluteString)
                } else if let text = item as? String {
                    continuation.resume(returning: SharedLinkParser.url(from: text) ?? text)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadMedia(_ provider: NSItemProvider, id: UUID) async -> String? {
        let types = [
            UTType.movie.identifier,
            "public.mpeg-4",
            UTType.video.identifier,
            UTType.quickTimeMovie.identifier,
            UTType.audio.identifier,
            UTType.mpeg4Audio.identifier,
        ]
        for type in types where provider.hasItemConformingToTypeIdentifier(type) {
            if let copied = await copyFile(provider, type: type, id: id) {
                return copied
            }
            let loaded: String? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                    if let url = item as? URL {
                        continuation.resume(returning: MediaStore.importFile(from: url, id: id))
                    } else if let data = item as? Data {
                        continuation.resume(returning: MediaStore.save(data, id: id, ext: "mp4"))
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
            if let loaded { return loaded }
        }
        return nil
    }

    private func loadImages(_ provider: NSItemProvider) async -> [String]? {
        let types = [
            UTType.image.identifier,
            UTType.jpeg.identifier,
            UTType.png.identifier,
            UTType.heic.identifier,
            "public.image",
        ]
        var names: [String] = []
        for type in types where provider.hasItemConformingToTypeIdentifier(type) {
            if let copied = await copyFile(provider, type: type, id: UUID()) {
                names.append(copied)
                break
            }
            if let data: Data = await withCheckedContinuation({ continuation in
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    continuation.resume(returning: data)
                }
            }), UIImage(data: data) != nil {
                names.append(MediaStore.save(data, id: UUID(), ext: "jpg"))
                break
            }
            let loaded: String? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                    if let url = item as? URL {
                        continuation.resume(returning: MediaStore.importFile(from: url, id: UUID()))
                    } else if let data = item as? Data {
                        continuation.resume(returning: MediaStore.save(data, id: UUID(), ext: "jpg"))
                    } else if let image = item as? UIImage, let data = image.jpegData(compressionQuality: 0.86) {
                        continuation.resume(returning: MediaStore.save(data, id: UUID(), ext: "jpg"))
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
            if let loaded {
                names.append(loaded)
                break
            }
        }
        return names.isEmpty ? nil : names
    }

    private func copyFile(_ provider: NSItemProvider, type: String, id: UUID) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: MediaStore.importFile(from: url, id: id))
            }
        }
    }

    private func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                continuation.resume(returning: item as? String)
            }
        }
    }

    private func openContainingApp(_ url: URL) {
        var responder: UIResponder? = self
        let selector = sel_registerName("openURL:")
        while let current = responder {
            if current !== self, current.responds(to: selector) {
                current.perform(selector, with: url)
                break
            }
            responder = current.next
        }
    }
}
