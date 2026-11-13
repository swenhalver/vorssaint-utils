// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine

/// What the capture toolbar asks of the selection surface.
enum CaptureToolbarAction {
    /// The big button: Capture, Record, or the tool's own verb.
    case confirm
    /// Take the current area, window or screen as a picture and open it in
    /// the markup editor, whatever mode the toolbar is in.
    case markup
    /// Take the current area, window or screen and copy its text, the way
    /// Markup opens it as a picture.
    case text
    case close
}

/// Shared state for the chooser. Every overlay panel observes the same value,
/// so changing a mode on one display updates the controls on all displays.
final class ScreenCaptureSelectionOptions: ObservableObject {
    let availableTools: [ScreenCaptureTool]
    let showsCaptureMenu: Bool
    let controlsInNotch: Bool
    var hasFocusedControl = false
    var onPresentationReady: (() -> Void)?
    var onSelectionProgressChange: ((Bool) -> Void)?
    var onCaptureControlsSurfaceChange: ((CGRect, CGFloat) -> Void)?
    let recorderAudio = RecorderSelectionAudioOptions()
    @Published private(set) var selectedTool: ScreenCaptureTool
    /// Screen, window or portion. The notch's controls predate the toolbar
    /// and always pick a portion, which also takes a clicked window.
    @Published private(set) var target: ScreenCaptureTarget
    @Published var offersRepeatLastRegion = false
    /// The toolbar's Options menu is open.
    @Published var showsOptions = false
    /// Set by the Markup button for the capture it starts, and read once
    /// when that capture is routed.
    var markupRequested = false
    /// Set by the text button the same way, read once when routed.
    var textRequested = false
    var onSelectionChange: (() -> Void)?
    var onTargetChange: (() -> Void)?
    var onToolbarAction: ((CaptureToolbarAction) -> Void)?
    /// A drag of the toolbar: the translation so far, then nil when it ends.
    var onToolbarDrag: ((CGSize?) -> Void)?

    init(availableTools: [ScreenCaptureTool], selectedTool: ScreenCaptureTool,
         showsCaptureMenu: Bool, controlsInNotch: Bool = false,
         defaults: UserDefaults = .standard) {
        precondition(availableTools.contains(selectedTool))
        self.availableTools = availableTools
        self.selectedTool = selectedTool
        self.showsCaptureMenu = showsCaptureMenu
        self.controlsInNotch = controlsInNotch
        self.target = controlsInNotch
            ? .portion
            : ScreenCaptureTarget.remembered(for: selectedTool) { defaults.string(forKey: $0) }
    }

    var mode: CaptureToolbarMode { CaptureToolbarMode(tool: selectedTool, target: target) }

    /// A tool picked by its digit key or from the notch opens on the target
    /// it was last used with.
    func select(_ tool: ScreenCaptureTool) {
        guard availableTools.contains(tool), selectedTool != tool else { return }
        let nextTarget = controlsInNotch
            ? .portion
            : ScreenCaptureTarget.remembered(for: tool) { UserDefaults.standard.string(forKey: $0) }
        apply(tool: tool, target: nextTarget)
    }

    func select(_ mode: CaptureToolbarMode) {
        guard availableTools.contains(mode.tool) else { return }
        if let key = mode.tool.rememberedTargetKey {
            UserDefaults.standard.set(mode.target.rawValue, forKey: key)
        }
        apply(tool: mode.tool, target: mode.target)
    }

    private func apply(tool: ScreenCaptureTool, target nextTarget: ScreenCaptureTarget) {
        let toolChanged = selectedTool != tool
        let targetChanged = target != nextTarget
        guard toolChanged || targetChanged else { return }
        target = nextTarget
        if toolChanged {
            selectedTool = tool
            if !tool.offersOptions { showsOptions = false }
            onSelectionChange?()
        }
        if targetChanged { onTargetChange?() }
    }
}

/// One selection surface for every capture tool. Each tool has its own
/// shortcut; the feature services own what happens after selection.
final class ScreenCaptureService: ObservableObject {
    static let shared = ScreenCaptureService()

    /// The tools whose own shortcut could not be registered, so each tool's
    /// settings can say so.
    @Published private(set) var toolShortcutRegistrationFailures: Set<ScreenCaptureTool> = []

    /// One hotkey per tool, built from the tool list so a new mode cannot be
    /// added without one. Ids continue past the hand-assigned quick tool
    /// range, which ends at 24.
    private let toolHotkeys: [ScreenCaptureTool: QuickToolHotkey] = {
        var next: UInt32 = 25
        var hotkeys: [ScreenCaptureTool: QuickToolHotkey] = [:]
        for tool in ScreenCaptureTool.allCases {
            hotkeys[tool] = QuickToolHotkey(id: next)
            next += 1
        }
        return hotkeys
    }()
    private var selection: ScreenshotSelectionController?
    private var options: ScreenCaptureSelectionOptions?
    /// The next surface, built while nothing is being captured, so a click
    /// or a shortcut only has to show it. Building it is most of what
    /// opening costs, and several times more on a Mac short of memory.
    private struct ReadySurface {
        let options: ScreenCaptureSelectionOptions
        let controller: ScreenshotSelectionController
        let language: String
        /// The preferences it was built from.
        let preferences: NSDictionary
    }
    private var ready: ReadySurface?
    /// A preference changed since `ready` was built; it is compared before use.
    private var readyMayBeStale = false
    private var readyIsBuilding = false
    private var readyWork: DispatchWorkItem?
    private var readyObservers: [NSObjectProtocol] = []
    /// What was opened last, which is what is most likely asked for next.
    private var lastOpened: (tool: ScreenCaptureTool, showsCaptureMenu: Bool)?
    private var countdown: DispatchWorkItem?
    private var countdownTools: [ScreenCaptureTool]?
    private var countdownRemaining = 0

    var protectedWindowIDs: Set<CGWindowID> {
        selection?.protectedWindowIDs ?? []
    }

    private init() {
        for (tool, hotkey) in toolHotkeys {
            hotkey.onPress = { [weak self] in self?.capture(initial: tool, fromShortcut: true) }
        }
    }

    func syncWithPreferences() {
        let availableTools = ScreenCaptureTool.available()
        CaptureHotspot.shared.syncWithPreferences()
        guard !availableTools.isEmpty else {
            toolShortcutRegistrationFailures = []
            toolHotkeys.values.forEach { $0.unregister() }
            cancelSelection()
            dropReadySurface()
            return
        }
        watchReadySurface()
        scheduleReadySurface(after: 2)
        if let activeTools = options?.availableTools ?? countdownTools,
           ScreenshotSupport.captureAvailabilityChanged(activeTools: activeTools,
                                                        availableTools: availableTools) {
            cancelSelection()
        }
        syncToolShortcuts(availableTools: availableTools, defaults: UserDefaults.standard)
    }

    /// A tool's own shortcut opens the same chooser already on that mode. A
    /// tool whose feature is not installed leaves its combination free for
    /// whatever else wants it.
    private func syncToolShortcuts(availableTools: [ScreenCaptureTool],
                                   defaults: UserDefaults) {
        var failures: Set<ScreenCaptureTool> = []
        for (tool, hotkey) in toolHotkeys {
            let keys = tool.dedicatedShortcut
            let enabled = availableTools.contains(tool) && defaults.bool(forKey: keys.enabledKey)
            if !hotkey.sync(enabled: enabled, shortcut: keys.role.savedShortcut,
                            storageKey: keys.role.storageKey) {
                failures.insert(tool)
            }
        }
        toolShortcutRegistrationFailures = failures
    }

    func suspend() {
        CaptureHotspot.shared.suspend()
        toolHotkeys.values.forEach { $0.unregister() }
        cancelSelection()
        readyObservers.forEach(NotificationCenter.default.removeObserver)
        readyObservers = []
        dropReadySurface()
    }

    /// Opens the same chooser from every feature surface. A feature-specific
    /// button merely picks the initial mode; the person can switch before
    /// selecting anything.
    /// Set while the island's Markup tile opens capture: the area, window or
    /// screen taken goes to the markup editor, as the toolbar's Markup does.
    private var opensForMarkup = false

    /// Opens screenshot capture whose result opens in the markup editor.
    func captureForMarkup() {
        opensForMarkup = true
        defer { opensForMarkup = false }
        capture(initial: .screenshot)
    }

    func capture(initial preferred: ScreenCaptureTool? = nil, fromShortcut: Bool = false) {
        CaptureTiming.mark("capture(initial:)")
        if preferred == .scrolling, ScreenshotService.shared.finishScrollingCaptureIfActive() { return }
        let recorder = ScreenRecorderService.shared
        if preferred == .recording, AppFeature.screenRecorder.isAvailable,
           recorder.stopOrCancelActiveCapture() {
            return
        }
        guard !ScreenshotService.shared.hasActiveCapture, !cancelCountdownIfActive() else { return }
        let duringRecording = recorder.hasActiveCapture
        if duringRecording {
            guard let preferred, preferred.opensDuringRecording(fromShortcut: fromShortcut) else { return }
        }
        if selection != nil {
            // Pressed again, by the shortcut or a hotspot that sends it, the
            // surface closes. Not while a button is held: an area dragged up
            // into a hotspot must not cancel itself.
            if NSEvent.pressedMouseButtons == 0 { cancelSelection() }
            return
        }
        guard !ScreenshotSelectionController.isSessionOnScreen else { return }

        let available = ScreenCaptureTool.available()
        guard !available.isEmpty else { return }
        let selected = preferred.flatMap { available.contains($0) ? $0 : nil }
            ?? (available.contains(.screenshot) ? .screenshot : available[0])
        if duringRecording, selected != preferred { return }
        // The digit keys switch tools even with the menu hidden, so a
        // selection that runs over a recording offers only its own tool.
        let tools = duringRecording ? [selected] : available

        guard Permissions.shared.screenRecording else {
            // Color sampling itself needs no capture permission, so its
            // direct action keeps the native path when capture access is off.
            if selected == .color {
                ColorSamplerService.shared.pickNative()
            } else {
                Permissions.shared.requestScreenRecording()
            }
            return
        }
        if selected == .recording,
           !ScreenRecorderService.shared.prepareForSelection() {
            return
        }

        let showsCaptureMenu = selected.showsCaptureMenu(fromShortcut: fromShortcut)
        let delay = selected == .screenshot || selected == .scrolling
            ? ScreenshotSupport.sanitizedDelay(
                UserDefaults.standard.integer(forKey: DefaultsKey.screenshotDelay))
            : 0
        let forMarkup = opensForMarkup
        performAfterDelay(delay, tools: tools) { [weak self] in
            self?.beginSelection(tools: tools, selected: selected, showsCaptureMenu: showsCaptureMenu,
                                 forMarkup: forMarkup)
        }
    }

    /// The toolbar's Timer was set while it is open. The delay runs before
    /// the surface opens, so the open capture closes and starts over through
    /// the countdown, in the mode it was in.
    func restartThroughDelay() {
        guard selection != nil, let tool = options?.selectedTool else { return }
        // After the click that chose the timer has been handled.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.selection != nil else { return }
            self.cancelSelection()
            self.capture(initial: tool)
        }
    }

    /// The direct full-screen shortcut and the chooser share one countdown.
    /// Pressing either while the other is waiting cancels the pending action.
    func performAfterDelay(_ delay: Int, tools: [ScreenCaptureTool]? = nil, action: @escaping () -> Void) {
        guard delay > 0 else {
            action()
            return
        }
        countdownRemaining = delay
        countdownTools = tools
        tickCountdown(action: action)
    }

    private func tickCountdown(action: @escaping () -> Void) {
        guard countdownRemaining > 0 else {
            countdown = nil
            countdownTools = nil
            action()
            return
        }
        QuickToolHUD.showCountdown(countdownRemaining)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.countdownRemaining -= 1
            self.tickCountdown(action: action)
        }
        countdown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func beginSelection(tools: [ScreenCaptureTool], selected: ScreenCaptureTool,
                               showsCaptureMenu: Bool, forMarkup: Bool = false) {
        guard selection == nil, !ScreenshotSelectionController.isSessionOnScreen else { return }
        let controlsInNotch = NotchSupport.routesCaptureControls() && NotchService.shared.acceptsSystemFeedback
        lastOpened = (selected, showsCaptureMenu)
        let waiting = takeReadySurface(tools: tools, selected: selected,
                                       showsCaptureMenu: showsCaptureMenu,
                                       controlsInNotch: controlsInNotch)
        let options = waiting?.options
            ?? ScreenCaptureSelectionOptions(availableTools: tools,
                                             selectedTool: selected,
                                             showsCaptureMenu: showsCaptureMenu,
                                             controlsInNotch: controlsInNotch)
        self.options = options
        if forMarkup { options.markupRequested = true }
        startSelection(options: options, controller: waiting?.controller)
    }

    /// The policy a surface for `options` follows, as the preferences stand.
    private func capturePolicy(for options: ScreenCaptureSelectionOptions)
        -> ScreenshotSupport.UnifiedCapturePolicy {
        let defaults = UserDefaults.standard
        return ScreenshotSupport.unifiedCapturePolicy(
            for: options.selectedTool,
            screenshotFreeze: defaults.bool(forKey: DefaultsKey.screenshotFreeze),
            screenshotIncludePointer: defaults.bool(forKey: DefaultsKey.screenshotIncludePointer),
            screenshotHideVorssaintWindows: defaults.bool(
                forKey: DefaultsKey.screenshotHideVorssaintWindows))
    }

    private func makeController(for options: ScreenCaptureSelectionOptions,
                                policy: ScreenshotSupport.UnifiedCapturePolicy)
        -> ScreenshotSelectionController {
        let defaults = UserDefaults.standard
        return ScreenshotSelectionController(
            freeze: policy.freeze,
            includePointer: policy.includePointer,
            showLastRegion: defaults.bool(forKey: DefaultsKey.screenshotShowLastRegion),
            adjustsSelection: defaults.bool(forKey: DefaultsKey.screenshotAdjustSelection),
            hideVorssaintWindows: policy.hideVorssaintWindows,
            protectedWindowIDs: { [weak options] in
                var windows: Set<CGWindowID> = []
                if AppFeature.screenshot.isAvailable {
                    // The tool can still change while the selection is up, so it
                    // is read here rather than captured. A session on its way out
                    // leaves no tool, and keeps both kinds out.
                    let tool = options?.selectedTool
                    windows = ScreenshotService.shared.protectedWindowIDsForCapture(
                        honoursVisibilityPreference: tool != nil && tool != .recording)
                }
                // The island follows its own preference even without the
                // screenshot feature, and the capture controls it turns into
                // never belong in the pixels.
                if NotchSupport.isEnabled() { windows.formUnion(NotchService.shared.protectedWindowIDs) }
                return windows
            },
            purpose: FeatureStrings.screenshot(L10n.shared.language).screenCaptureTitle,
            mode: policy.usesGeometry ? .geometry : .image,
            supportsScrollingCapture: options.availableTools.contains(.screenshot),
            screenCaptureOptions: options)
    }

    /// `waiting` is a surface built ahead for exactly these options.
    private func startSelection(options: ScreenCaptureSelectionOptions,
                                controller waiting: ScreenshotSelectionController? = nil) {
        CaptureTiming.mark(waiting == nil ? "startSelection" : "startSelection, built ahead")
        guard selection == nil, !ScreenshotSelectionController.isSessionOnScreen,
              self.options === options else {
            waiting?.discardPrepared()
            return
        }
        let controller = waiting ?? makeController(for: options, policy: capturePolicy(for: options))
        if options.controlsInNotch {
            connectCaptureControlsSurface(options, controller: controller)
            options.onPresentationReady = { [weak self, weak options] in
                guard let self, let options, self.options === options else { return }
                NotchService.shared.presentCaptureControls(options) { [weak self] in self?.cancelSelection() }
            }
        }
        selection = controller
        controller.begin { [weak self, weak controller, weak options] outcome in
            guard let self, let controller, let options,
                  self.selection === controller else { return }
            NotchService.shared.endCaptureControls()
            // The surface held the keyboard, and a Command Bar that stayed
            // open to be in the picture takes it back.
            CommandBarService.shared.captureSurfaceDidClose()
            options.onPresentationReady = nil
            options.onCaptureControlsSurfaceChange = nil
            self.selection = nil
            self.options = nil
            // A surface closed without a capture may be opened again at
            // once. Otherwise the next one waits until the picture is taken
            // and its preview is up.
            if case .cancelled = outcome {
                self.scheduleReadySurface(after: Self.readyDelayAfterClosing)
            } else {
                self.scheduleReadySurface(after: 1)
            }
            let markup = options.markupRequested
            let text = options.textRequested
            options.markupRequested = false
            options.textRequested = false
            if markup, AppFeature.screenshot.isAvailable {
                self.routePicture(outcome) { ScreenshotService.shared.receiveMarkupCapture($0) }
                return
            }
            if text, AppFeature.screenOCR.isAvailable {
                self.routePicture(outcome) { ScreenTextService.shared.receiveUnifiedCapture($0) }
                return
            }
            self.route(outcome, selected: options.selectedTool,
                       recorderAudio: options.recorderAudio)
        }
    }

    private func connectCaptureControlsSurface(_ options: ScreenCaptureSelectionOptions,
                                               controller: ScreenshotSelectionController) {
        options.onCaptureControlsSurfaceChange = { [weak self, weak options, weak controller] screenFrame, surfaceHeight in
            guard let self, let options, let controller,
                  self.options === options, self.selection === controller else { return }
            controller.placeFullScreenControlBelowNotch(
                screenFrame: screenFrame,
                surfaceHeight: surfaceHeight)
        }
    }

    private func route(_ outcome: ScreenshotSelectionController.Outcome,
                       selected: ScreenCaptureTool,
                       recorderAudio: RecorderSelectionAudioOptions) {
        guard ScreenshotSupport.captureRouteIsAuthorized(selected: selected) else { return }
        switch outcome {
        case .captured(let capture):
            switch selected {
            case .screenshot:
                ScreenshotService.shared.receiveUnifiedCapture(capture)
            case .text:
                ScreenTextService.shared.receiveUnifiedCapture(capture)
            case .recording, .color, .scrolling:
                showFailure(for: selected)
            }
        case .region(let region):
            guard selected == .recording else {
                showFailure(for: selected)
                return
            }
            ScreenRecorderService.shared.record(region,
                                                audioOptions: recorderAudio)
        case .scrollingRegion(let region):
            guard selected == .screenshot || selected == .scrolling else {
                showFailure(for: selected)
                return
            }
            ScreenshotService.shared.receiveUnifiedScrollingRegion(region)
        case .color(let color):
            guard selected == .color else {
                showFailure(for: selected)
                return
            }
            ColorSamplerService.shared.receiveUnifiedColor(color)
        case .cancelled:
            break
        case .failed:
            showFailure(for: selected)
        }
    }

    /// The toolbar's Markup button: whatever the mode, the area, window or
    /// screen becomes a picture in the markup editor. Record modes chose an
    /// area rather than pixels, so the picture is taken once the surface has
    /// left the screen, the same way a live screenshot is.
    private func routePicture(_ outcome: ScreenshotSelectionController.Outcome,
                              deliver: @escaping (ScreenshotSelectionController.Capture) -> Void) {
        switch outcome {
        case .captured(let capture):
            deliver(capture)
        case .region(let region), .scrollingRegion(let region):
            let defaults = UserDefaults.standard
            let includePointer = defaults.bool(forKey: DefaultsKey.screenshotIncludePointer)
            let hideWindows = defaults.bool(forKey: DefaultsKey.screenshotHideVorssaintWindows)
            let protected = ScreenshotService.shared
                .protectedWindowIDsForCapture(honoursVisibilityPreference: true)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000)
                var capture: ScreenshotSelectionController.Capture?
                if let windowID = region.windowID,
                   let window = await ScreenshotCaptureEngine.captureWindow(windowID, scale: region.scale) {
                    capture = .init(image: window.image, scale: window.scale, anchorRect: region.anchorRect)
                } else if let image = await ScreenshotCaptureEngine.captureDisplay(
                    region.displayID, includePointer: includePointer,
                    hideVorssaintWindows: hideWindows, protectedWindowIDs: protected) {
                    let clamped = ScreenshotSupport.clamp(
                        region.pixelRect, to: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                    if let cropped = image.cropping(to: clamped) {
                        capture = .init(image: cropped, scale: region.scale, anchorRect: region.anchorRect)
                    }
                }
                guard let capture else {
                    self?.showFailure(for: .screenshot)
                    return
                }
                deliver(capture)
            }
        case .color, .cancelled:
            break
        case .failed:
            showFailure(for: .screenshot)
        }
    }

    private func showFailure(for tool: ScreenCaptureTool) {
        if tool == .recording {
            let strings = FeatureStrings.recorder(L10n.shared.language)
            QuickToolHUD.show(icon: "record.circle", message: strings.recordFailed)
        } else {
            let strings = FeatureStrings.screenshot(L10n.shared.language)
            QuickToolHUD.show(icon: "camera.viewfinder", message: strings.captureFailed)
        }
    }

    @discardableResult
    func cancelCountdownIfActive() -> Bool {
        guard let work = countdown else { return false }
        work.cancel()
        countdown = nil
        countdownTools = nil
        countdownRemaining = 0
        return true
    }

    private func cancelSelection() {
        NotchService.shared.endCaptureControls()
        options?.onPresentationReady = nil
        options?.onCaptureControlsSurfaceChange = nil
        cancelCountdownIfActive()
        let hadSelection = selection != nil
        selection?.cancel()
        selection = nil
        options = nil
        if hadSelection { scheduleReadySurface(after: Self.readyDelayAfterClosing) }
    }

    // MARK: Ready surface

    /// Window positions and what the Command Bar learns change all day and
    /// decide nothing about a capture surface.
    private static let readyIgnoredPreferencePrefixes = ["commandBar", "NSWindow Frame", "NSSplitView",
                                                         "NSNavPanel", "NSStatusItem"]

    /// Long enough for the closed surface to leave the screen first.
    private static let readyDelayAfterClosing: TimeInterval = 0.15

    private static func readyPreferences() -> NSDictionary {
        guard let name = Bundle.main.bundleIdentifier,
              var domain = UserDefaults.standard.persistentDomain(forName: name) else { return [:] }
        for key in domain.keys where readyIgnoredPreferencePrefixes.contains(where: key.hasPrefix) {
            domain[key] = nil
        }
        return domain as NSDictionary
    }

    /// A surface is built from the preferences and the displays as they
    /// were, so a change to either sends it back to be checked or rebuilt.
    private func watchReadySurface() {
        guard readyObservers.isEmpty else { return }
        let center = NotificationCenter.default
        readyObservers.append(center.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                self?.readyPreferencesChanged()
            } else {
                DispatchQueue.main.async { self?.readyPreferencesChanged() }
            }
        })
        readyObservers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.dropReadySurface()
            self?.scheduleReadySurface(after: 2)
        })
    }

    /// Called for every preference written anywhere in the app, so it only
    /// notes the change. The comparison waits until the writing stops.
    private func readyPreferencesChanged() {
        // Building a surface writes a few preferences of its own.
        guard !readyIsBuilding, selection == nil else { return }
        if ready != nil { readyMayBeStale = true }
        scheduleReadySurface(after: 2)
    }

    private func scheduleReadySurface(after delay: TimeInterval) {
        readyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.readyWork = nil
            self?.refreshReadySurface()
        }
        readyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func dropReadySurface() {
        readyWork?.cancel()
        readyWork = nil
        ready?.controller.discardPrepared()
        ready = nil
        readyMayBeStale = false
    }

    /// Keeps a surface waiting whenever one can be: checks the one there
    /// against the preferences, and builds one when there is none.
    private func refreshReadySurface() {
        if let waiting = ready {
            guard readyMayBeStale else { return }
            readyMayBeStale = false
            let current = Self.readyPreferences()
            if waiting.preferences.isEqual(current), waiting.language == L10n.shared.language.rawValue { return }
            CaptureTiming.note("surface built ahead is out of date: "
                + Self.changedKeys(from: waiting.preferences, to: current))
            dropReadySurface()
        }
        guard selection == nil, !ScreenshotSelectionController.isSessionOnScreen else { return }
        guard countdown == nil, !ScreenshotService.shared.hasActiveCapture,
              !ScreenRecorderService.shared.hasActiveCapture else {
            // Busy taking or recording something, which ends without a word here.
            scheduleReadySurface(after: 5)
            return
        }
        guard Permissions.shared.screenRecording else { return }
        let available = ScreenCaptureTool.available()
        guard !available.isEmpty else { return }
        let selected = lastOpened.flatMap { available.contains($0.tool) ? $0.tool : nil }
            ?? (available.contains(.screenshot) ? .screenshot : available[0])
        // Until something was opened, the likeliest opening is a shortcut's
        // or the top edge's, which both count as a shortcut.
        let showsCaptureMenu = lastOpened.flatMap { $0.tool == selected ? $0.showsCaptureMenu : nil }
            ?? selected.showsCaptureMenu(fromShortcut: true)
        let options = ScreenCaptureSelectionOptions(
            availableTools: available,
            selectedTool: selected,
            showsCaptureMenu: showsCaptureMenu,
            controlsInNotch: NotchSupport.routesCaptureControls() && NotchService.shared.acceptsSystemFeedback)
        let policy = capturePolicy(for: options)
        // A frozen surface shows photographs taken as it opens.
        guard !policy.freeze else { return }
        readyIsBuilding = true
        defer { readyIsBuilding = false }
        let controller = makeController(for: options, policy: policy)
        guard controller.prepare() else { return }
        ready = ReadySurface(options: options, controller: controller,
                             language: L10n.shared.language.rawValue,
                             preferences: Self.readyPreferences())
        readyMayBeStale = false
    }

    /// The surface built ahead, when it is the one being asked for and
    /// nothing it was built from has changed. Otherwise it is let go, and
    /// the caller builds one as it always did.
    private func takeReadySurface(tools: [ScreenCaptureTool], selected: ScreenCaptureTool,
                                  showsCaptureMenu: Bool, controlsInNotch: Bool) -> ReadySurface? {
        guard let waiting = ready else {
            CaptureTiming.note("no surface built ahead")
            return nil
        }
        ready = nil
        readyWork?.cancel()
        readyWork = nil
        let stale = readyMayBeStale
        readyMayBeStale = false
        var mismatch: String?
        if waiting.options.availableTools != tools || waiting.options.selectedTool != selected
            || waiting.options.showsCaptureMenu != showsCaptureMenu
            || waiting.options.controlsInNotch != controlsInNotch {
            mismatch = "another tool or menu"
        } else if !waiting.controller.coversCurrentScreens {
            mismatch = "displays changed"
        } else if waiting.language != L10n.shared.language.rawValue {
            mismatch = "language changed"
        } else if stale {
            let current = Self.readyPreferences()
            if !waiting.preferences.isEqual(current) {
                mismatch = Self.changedKeys(from: waiting.preferences, to: current)
            }
        }
        if let mismatch {
            CaptureTiming.note("surface built ahead not used: \(mismatch)")
            waiting.controller.discardPrepared()
            return nil
        }
        return waiting
    }

    /// The names of up to five preferences that differ, for the timing log.
    private static func changedKeys(from old: NSDictionary, to new: NSDictionary) -> String {
        let keys = Set((old.allKeys + new.allKeys).compactMap { $0 as? String })
        let changed = keys.filter { key in
            let before = old[key] as AnyObject?, after = new[key] as AnyObject?
            return !(before === after || before?.isEqual(after) == true)
        }.sorted()
        return changed.prefix(5).joined(separator: ", ") + (changed.count > 5 ? ", …" : "")
    }
}
