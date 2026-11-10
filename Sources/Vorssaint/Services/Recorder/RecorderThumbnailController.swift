// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AVFoundation
import AppKit
import UniformTypeIdentifiers

/// Turns a finished take into the file a person keeps without opening the
/// editor: the picture as it was recorded, with the pointer drawn in (the
/// capture never contains one), written once into a private folder named the
/// way the saved file will be. Whoever needs the file waits for the one
/// export instead of starting another.
final class RecorderQuickExport {
    enum State { case running, finished, failed }

    let take: RecorderTakeStore.Take
    /// Where the export lands, already carrying the saved file's name, so a
    /// drag into another app hands over a well-named file.
    let fileURL: URL
    private let exporter = RecorderExporter()
    private(set) var state = State.running
    private var waiters: [(URL?) -> Void] = []
    private var started = false

    init?(take: RecorderTakeStore.Take, strings: RecorderFeatureStrings) {
        guard let folder = Self.makeFolder() else { return nil }
        self.take = take
        let name = RecorderSupport.recordingFileName(prefix: strings.fileNamePrefix,
                                                     date: Date(),
                                                     uses12HourClock: RecorderSupport.systemUses12HourClock,
                                                     fileExtension: "mp4")
        fileURL = folder.appendingPathComponent(name)
    }

    func start() {
        guard !started else { return }
        started = true
        let defaults = UserDefaults.standard
        let document = RecorderEditDocument.asRecorded(
            quality: defaults.string(forKey: DefaultsKey.recorderQuality),
            showsClicks: defaults.bool(forKey: DefaultsKey.recorderShowClicks))
        let exporter = exporter
        let take = take
        let destination = fileURL
        // Held until the export ends, so whoever is waiting always hears
        // back, even after the thumbnail that started it has gone.
        Task { @MainActor in
            let failure = await exporter.export(take: take, document: document, output: .video,
                                                to: destination) { _ in }
            self.complete(failure == nil ? .finished : .failed)
        }
    }

    /// Calls back on the main thread with the file once the export is done,
    /// or nil when it failed or was cancelled.
    func whenDone(_ body: @escaping (URL?) -> Void) {
        switch state {
        case .finished: body(fileURL)
        case .failed: body(nil)
        case .running: waiters.append(body)
        }
    }

    func cancel() {
        exporter.cancel()
        if state != .running { removeFile() }
    }

    func removeFile() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func complete(_ result: State) {
        guard state == .running else { return }
        state = result
        let waiting = waiters
        waiters = []
        waiting.forEach { $0(result == .finished ? fileURL : nil) }
    }

    /// One folder per export in the app's caches, cleared of anything a day
    /// old: a file dragged into another app has to outlive the gesture, since
    /// some apps read it only after the drop.
    private static func makeFolder() -> URL? {
        let manager = FileManager.default
        guard let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let root = caches.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Finished Recordings", isDirectory: true)
        if let old = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let cutoff = Date().addingTimeInterval(-24 * 3600)
            for item in old where ((try? item.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantFuture) < cutoff {
                try? manager.removeItem(at: item)
            }
        }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard (try? manager.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
        else { return nil }
        return folder
    }
}

/// The thumbnail a stopped recording leaves in the corner, the way the
/// system recorder does. Left alone, or swiped toward the edge, it saves.
/// A click opens the editor (trim, cut, share, delete). Dragging it hands the
/// file to another app instead of saving it. A right click offers the rest.
final class RecorderThumbnailController: NSObject, NSDraggingSource, NSFilePromiseProviderDelegate {
    let take: RecorderTakeStore.Take
    private let export: RecorderQuickExport
    private let screen: NSScreen?
    private var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?
    private var pointerInside = false
    private var dragging = false
    private(set) var isClosed = false
    private var terminationObserver: NSObjectProtocol?
    /// Called once the thumbnail has handed the take on, however it did.
    var onFinish: ((RecorderThumbnailController) -> Void)?

    private var strings: RecorderFeatureStrings { FeatureStrings.recorder(L10n.shared.language) }
    private var toolbarStrings: CaptureToolbarStrings { FeatureStrings.captureToolbar(L10n.shared.language) }

    init?(take: RecorderTakeStore.Take, displayID: CGDirectDisplayID) {
        guard let export = RecorderQuickExport(take: take,
                                               strings: FeatureStrings.recorder(L10n.shared.language))
        else { return nil }
        self.take = take
        self.export = export
        screen = NSScreen.screens.first { $0.displayID == displayID } ?? NSScreen.main
        super.init()
        // Quitting with a thumbnail up must not lose the recording.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.saveBeforeQuitting() }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    func show() {
        export.start()
        let asset = AVURLAsset(url: take.videoURL)
        Task { @MainActor [weak self] in
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 520, height: 520)
            let image = try? await generator.image(at: .zero).image
            self?.present(image)
        }
    }

    private func present(_ image: CGImage?) {
        guard !isClosed, let host = screen ?? NSScreen.main else { return }
        let videoSize = image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        let size = RecorderSupport.thumbnailSize(for: videoSize)
        let visible = host.visibleFrame
        let final = CGRect(x: visible.maxX - size.width - 20, y: visible.minY + 20,
                           width: size.width, height: size.height)
        let view = ThumbnailView(frame: CGRect(origin: .zero, size: size), image: image)
        view.controller = self
        view.setAccessibilityLabel(strings.editorTitle)
        let panel = OverlayPanel(contentRect: final.offsetBy(dx: size.width + 40, dy: 0),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.orderFrontRegardless()
        self.panel = panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(final, display: true)
        }
        scheduleDismiss()
    }

    // MARK: - Timing

    private func scheduleDismiss() {
        dismissWork?.cancel()
        guard !isClosed, !pointerInside, !dragging else { return }
        let work = DispatchWorkItem { [weak self] in self?.commit() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + RecorderSupport.floatingThumbnailDuration,
                                      execute: work)
    }

    fileprivate func pointerChanged(inside: Bool) {
        pointerInside = inside
        if inside {
            dismissWork?.cancel()
            dismissWork = nil
        } else {
            scheduleDismiss()
        }
    }

    // MARK: - Outcomes

    /// Saves to the chosen folder and copies the file, the default ending.
    func commit(reveal: Bool = false) {
        guard close() else { return }
        ScreenRecorderService.shared.saveAsRecorded(take, export: export, reveal: reveal) { [weak self] in
            guard let self else { return }
            self.onFinish?(self)
        }
    }

    fileprivate func swipeAway() {
        guard let panel, !isClosed else { return }
        let gone = panel.frame.offsetBy(dx: panel.frame.width + 40, dy: 0)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().setFrame(gone, display: true)
        }, completionHandler: { [weak self] in self?.commit() })
    }

    fileprivate func openEditor() {
        guard close() else { return }
        export.cancel()
        export.whenDone { [weak self] _ in self?.export.removeFile() }
        if !ScreenRecorderService.shared.openEditor(with: take) {
            ScreenRecorderService.shared.saveAsRecorded(take, export: nil, reveal: false) {}
        }
        onFinish?(self)
    }

    /// Saved like any finished recording, and copied even when automatic
    /// copying is off: a pasted file must still exist tomorrow.
    fileprivate func copyFile() {
        guard close() else { return }
        ScreenRecorderService.shared.saveAsRecorded(take, export: export, reveal: false,
                                                    alwaysCopies: true) { [weak self] in
            guard let self else { return }
            self.onFinish?(self)
        }
    }

    fileprivate func delete() {
        guard close() else { return }
        export.cancel()
        export.whenDone { [weak self] _ in
            guard let self else { return }
            self.export.removeFile()
            RecorderTakeStore.shared.delete(self.take)
            self.onFinish?(self)
        }
    }

    /// Dropped into another app: that app has the file now, so nothing is
    /// saved to the folder as well, as with the system's thumbnail.
    private func handedOff() {
        guard close() else { return }
        export.whenDone { [weak self] url in
            guard let self else { return }
            if url == nil {
                // The drop could not be given a file: keep the recording.
                ScreenRecorderService.shared.saveAsRecorded(self.take, export: nil, reveal: false) {}
            } else {
                RecorderTakeStore.shared.delete(self.take)
            }
            self.onFinish?(self)
        }
    }

    /// False when the thumbnail had already gone.
    @discardableResult
    private func close() -> Bool {
        guard !isClosed else { return false }
        isClosed = true
        dismissWork?.cancel()
        dismissWork = nil
        panel?.orderOut(nil)
        panel = nil
        return true
    }

    /// A synchronous last resort while the app quits: the finished export
    /// when there is one, otherwise the master as it was captured.
    private func saveBeforeQuitting() {
        guard close() else { return }
        ScreenRecorderService.shared.saveSynchronously(take, export: export)
    }

    // MARK: - Menu

    fileprivate func menu() -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        item(FeatureStrings.screenshot(L10n.shared.language).editButton, #selector(menuEdit))
        item(strings.saveButton, #selector(menuSave))
        item(strings.copyButton, #selector(menuCopy))
        item(toolbarStrings.showInFinder, #selector(menuReveal))
        menu.addItem(.separator())
        item(strings.discardButton, #selector(menuDelete))
        return menu
    }

    @objc private func menuEdit() { openEditor() }
    @objc private func menuSave() { commit() }
    @objc private func menuCopy() { copyFile() }
    @objc private func menuReveal() { commit(reveal: true) }
    @objc private func menuDelete() { delete() }

    // MARK: - Dragging

    fileprivate func beginDrag(with event: NSEvent, from view: NSView, image: NSImage?) {
        guard !isClosed else { return }
        dragging = true
        dismissWork?.cancel()
        let writer: NSPasteboardWriting
        if export.state == .finished {
            writer = export.fileURL as NSURL
        } else {
            writer = NSFilePromiseProvider(fileType: UTType.mpeg4Movie.identifier, delegate: self)
        }
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(view.bounds, contents: image)
        view.beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        dragging = false
        if operation.isEmpty {
            scheduleDismiss()
        } else {
            handedOff()
        }
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String {
        export.fileURL.lastPathComponent
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async { [export] in
            export.whenDone { source in
                guard let source else {
                    completionHandler(CocoaError(.fileWriteUnknown))
                    return
                }
                do {
                    try FileManager.default.copyItem(at: source, to: url)
                    completionHandler(nil)
                } catch {
                    completionHandler(error)
                }
            }
        }
    }

    // MARK: - The view

    private final class ThumbnailView: NSView {
        weak var controller: RecorderThumbnailController?
        private let image: CGImage?
        private var pressLocation: CGPoint?
        private var swipeTravel: CGFloat = 0

        init(frame: CGRect, image: CGImage?) {
            self.image = image
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 7
            layer?.masksToBounds = true
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.contents = image
            layer?.contentsGravity = .resizeAspect
            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                           owner: self))
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseEntered(with event: NSEvent) { controller?.pointerChanged(inside: true) }
        override func mouseExited(with event: NSEvent) { controller?.pointerChanged(inside: false) }

        override func mouseDown(with event: NSEvent) {
            pressLocation = event.locationInWindow
        }

        override func mouseDragged(with event: NSEvent) {
            guard let press = pressLocation else { return }
            let location = event.locationInWindow
            guard hypot(location.x - press.x, location.y - press.y) > 4 else { return }
            pressLocation = nil
            controller?.beginDrag(with: event, from: self,
                                  image: image.map { NSImage(cgImage: $0, size: bounds.size) })
        }

        override func mouseUp(with event: NSEvent) {
            guard pressLocation != nil else { return }
            pressLocation = nil
            controller?.openEditor()
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let menu = controller?.menu() else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        /// A two-finger swipe toward the right edge sends it away and saves.
        override func scrollWheel(with event: NSEvent) {
            guard event.hasPreciseScrollingDeltas else { return }
            if event.phase == .began { swipeTravel = 0 }
            let fingers = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            swipeTravel += fingers
            if RecorderSupport.thumbnailSwipeSaves(accumulatedFingerTravel: swipeTravel) {
                swipeTravel = -.greatestFiniteMagnitude
                controller?.swipeAway()
            }
        }
    }
}
