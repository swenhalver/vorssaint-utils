// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// The capture surface: one borderless panel per screen, above everything,
/// where the user drags a region, clicks a window or confirms a full screen.
///
/// With freeze on (the default) every display is photographed first and the
/// panels show that still image while the area is chosen. With freeze off the
/// panels are transparent and pixels are captured at confirmation time.
///
/// More than one feature picks an area this way, so the surface says what the
/// area is for and only one session is ever on screen.
final class ScreenshotSelectionController {

    struct Capture {
        let image: CGImage
        /// Pixels per point of the source display, for 1x export math.
        let scale: CGFloat
        /// The captured area in Cocoa global coordinates.
        let anchorRect: CGRect
        var sourceFormat: MediaImageFormat = .png
    }

    /// What the caller wants out of the same gesture. The screenshot tool
    /// wants pixels; the recorder wants to know WHERE, and takes its own
    /// pixels afterwards, for as long as the person keeps recording.
    enum Mode {
        case image
        case geometry
        case color
    }

    enum Outcome {
        case captured(Capture)
        case region(RecorderSupport.Region)
        case scrollingRegion(RecorderSupport.Region)
        case color(NSColor)
        case cancelled
        case failed
    }

    private var panels: [ScreenshotOverlayPanel] = []

    var protectedWindowIDs: Set<CGWindowID> {
        Set(panels.compactMap { $0.windowNumber > 0 ? CGWindowID($0.windowNumber) : nil })
    }

    /// The overlays are part of the capture, so they stay excluded even when
    /// the session is not registered anywhere yet.
    private var captureExcludedWindowIDs: Set<CGWindowID> {
        otherProtectedWindowIDs().union(protectedWindowIDs)
    }
    private var keyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var completion: ((Outcome) -> Void)?
    private var freeze: Bool
    private var includePointer: Bool
    private let showLastRegion: Bool
    /// The area stays on screen after it is drawn, to be moved or resized,
    /// and the session opens with the last one; a button takes the shot.
    fileprivate let adjustsSelection: Bool
    /// A drawn area stays on screen, with its handles, until it is taken.
    /// The system-style toolbar always works this way, as macOS's does: its
    /// Capture or Record button takes the area. Without the toolbar it
    /// follows the setting.
    fileprivate var keepsDrawnArea: Bool { adjustsSelection || showsToolbar }
    /// Whether portion mode reopens on the last area. The toolbar's Options
    /// can change this mid-session, so with the toolbar it is read live.
    private var remembersLastArea: Bool {
        showsToolbar
            ? UserDefaults.standard.bool(forKey: DefaultsKey.screenshotAdjustSelection)
            : adjustsSelection
    }
    private var hideVorssaintWindows: Bool
    private let otherProtectedWindowIDs: () -> Set<CGWindowID>
    private let baseMode: Mode
    private let supportsScrollingCapture: Bool
    private let screenCaptureOptions: ScreenCaptureSelectionOptions?
    private var capturePolicy: ScreenshotSupport.UnifiedCapturePolicy
    /// Bumped whenever the source is re-photographed, so a capture that a
    /// later tool change already replaced never reaches the panels.
    private var sourceGeneration = 0
    private var sourceRefreshPending = false
    /// Old pixels and window choices remain visible during refresh, but cannot
    /// be used by either pointer actions or keyboard confirmations.
    fileprivate var acceptsCaptureInput: Bool {
        !finished && !sourceRefreshPending
    }
    fileprivate let requiresDraggedRegion: Bool
    private var finished = false
    /// Read by the overlays so a late event finds a session that is over.
    fileprivate var isOver: Bool { finished }
    fileprivate var spaceIsDown = false
    fileprivate private(set) var selectionInProgress = false
    fileprivate func setSelectionInProgress(_ active: Bool) {
        let previous = selectionInProgress
        selectionInProgress = active
        panels.forEach {
            $0.overlayView.refreshGuideVisibility()
            $0.overlayView.refreshFullScreenControlVisibility()
        }
        if active != previous {
            screenCaptureOptions?.onSelectionProgressChange?(active)
        }
    }
    fileprivate var scrollingCaptureEnabled = false {
        didSet {
            panels.forEach {
                $0.overlayView.refreshCaptureGuide()
                $0.overlayView.refreshFullScreenControlVisibility()
                $0.overlayView.needsDisplay = true
            }
        }
    }
    fileprivate var offersScrollingCapture: Bool {
        supportsScrollingCapture && activeTool == .screenshot && activeMode == .image
    }
    fileprivate var offersFullScreenCapture: Bool {
        acceptsCaptureInput && activeMode == .image
            && ScreenshotSupport.fullScreenCaptureControlIsAvailable(
                selectedTool: activeTool,
                standaloneScreenshot: screenCaptureOptions == nil,
                requiresDraggedRegion: requiresDraggedRegion,
                scrollingCaptureEnabled: scrollingCaptureEnabled)
    }
    fileprivate var acceptsWindowClick: Bool {
        acceptsCaptureInput && activeMode != .color && !requiresDraggedRegion && !scrollingCaptureEnabled
    }
    fileprivate var isPickingColor: Bool { activeMode == .color }
    /// The panel `repeatLastRegion()` would act on, or nil when there is
    /// nothing to repeat: the guide hint and the action read the same
    /// property so the bar cannot promise a key that does nothing.
    private var repeatTargetPanel: ScreenshotOverlayPanel? {
        guard let last = Self.lastRegion else { return nil }
        return panels.first { $0.displayID == last.displayID }
    }
    fileprivate var offersRepeatLastRegion: Bool {
        ScreenshotSupport.offersRepeatLastRegion(
            isPickingColor: isPickingColor,
            storedRegionDisplayIsAvailable: repeatTargetPanel != nil)
    }
    fileprivate var loupeEnabled = false {
        didSet {
            panels.forEach {
                $0.overlayView.refreshCaptureGuide()
                $0.overlayView.refreshPointerState()
            }
        }
    }
    fileprivate var loupeZoom: CGFloat {
        didSet {
            UserDefaults.standard.set(Double(loupeZoom),
                                      forKey: DefaultsKey.screenshotLoupeLastZoom)
            panels.forEach { $0.overlayView.needsDisplay = true }
        }
    }
    fileprivate var currentPointerLocation: CGPoint?

    /// The last confirmed region, per display, so R repeats it instantly.
    /// Kept in preferences so the next session can open on it after a relaunch.
    private static var lastRegion: (displayID: CGDirectDisplayID, viewRect: CGRect)? {
        get {
            guard let parts = UserDefaults.standard.string(forKey: DefaultsKey.screenshotLastRegion)?
                    .split(separator: " ").compactMap({ Double($0) }),
                  parts.count == 5 else { return nil }
            return (CGDirectDisplayID(parts[0]),
                    CGRect(x: parts[1], y: parts[2], width: parts[3], height: parts[4]))
        }
        set {
            guard let newValue else {
                UserDefaults.standard.removeObject(forKey: DefaultsKey.screenshotLastRegion)
                return
            }
            let rect = newValue.viewRect
            UserDefaults.standard.set("\(newValue.displayID) \(rect.minX) \(rect.minY) \(rect.width) \(rect.height)",
                                      forKey: DefaultsKey.screenshotLastRegion)
        }
    }

    /// True while a session owns the screen. Two surfaces at once would stack
    /// dim over dim and split the keyboard between them, so whichever feature
    /// asks second is turned away.
    private(set) static var isSessionOnScreen = false
    private static weak var activeSession: ScreenshotSelectionController?

    /// Step mode needs the physical wheel event immediately. Fast mode keeps
    /// the normal smooth-scroll packet train, which is what gives it its
    /// deliberately accelerated sweep through the zoom range.
    static func steppedLoupeNeedsRawWheel(optionPressed: Bool) -> Bool {
        guard activeSession?.loupeEnabled == true else { return false }
        return ScreenshotSupport.captureLoupeUsesSteppedZoom(
            steppedByDefault: UserDefaults.standard.bool(
                forKey: DefaultsKey.screenshotLoupeSteppedZoomByDefault),
            optionPressed: optionPressed)
    }

    private let strings = FeatureStrings.screenshot(L10n.shared.language)
    /// Named at the head of the hint bar so the surface never leaves the
    /// person guessing what the area they are about to pick is for.
    private let purpose: String?

    init(freeze: Bool,
         includePointer: Bool,
         showLastRegion: Bool,
         adjustsSelection: Bool = false,
         hideVorssaintWindows: Bool = true,
         protectedWindowIDs: @escaping () -> Set<CGWindowID> = { [] },
         purpose: String? = nil,
         mode: Mode = .image,
         supportsScrollingCapture: Bool = false,
         requiresDraggedRegion: Bool = false,
         screenCaptureOptions: ScreenCaptureSelectionOptions? = nil) {
        self.freeze = freeze
        self.includePointer = includePointer
        self.showLastRegion = showLastRegion
        self.adjustsSelection = adjustsSelection
        self.hideVorssaintWindows = hideVorssaintWindows
        self.otherProtectedWindowIDs = protectedWindowIDs
        self.purpose = purpose
        self.baseMode = mode
        self.supportsScrollingCapture = supportsScrollingCapture
        self.requiresDraggedRegion = requiresDraggedRegion
        self.screenCaptureOptions = screenCaptureOptions
        let defaults = UserDefaults.standard
        self.loupeZoom = ScreenshotSupport.captureLoupeInitialZoom(
            rememberLast: defaults.bool(forKey: DefaultsKey.screenshotLoupeRememberZoom),
            defaultZoom: CGFloat(defaults.double(forKey: DefaultsKey.screenshotLoupeDefaultZoom)),
            lastZoom: CGFloat(defaults.double(forKey: DefaultsKey.screenshotLoupeLastZoom)))
        self.capturePolicy = ScreenshotSupport.UnifiedCapturePolicy(
            freeze: freeze,
            includePointer: includePointer,
            hideVorssaintWindows: hideVorssaintWindows,
            keepsContentWindowsOut: hideVorssaintWindows
                || screenCaptureOptions?.selectedTool == .recording,
            usesGeometry: mode == .geometry)
        defaults.set(Double(loupeZoom), forKey: DefaultsKey.screenshotLoupeLastZoom)
    }

    private var activeTool: ScreenCaptureTool? { screenCaptureOptions?.selectedTool }

    /// Screen, window or portion, as picked on the toolbar. A surface without
    /// the toolbar always picks a portion, which also takes a clicked window.
    fileprivate var captureTarget: ScreenCaptureTarget {
        screenCaptureOptions?.target ?? .portion
    }

    /// The system-style toolbar replaces the hint bar wherever the controls
    /// are not in Dynamic Island.
    fileprivate var showsToolbar: Bool {
        screenCaptureOptions.map { !$0.controlsInNotch } ?? false
    }

    private var activeMode: Mode {
        switch activeTool {
        case .recording: return .geometry
        case .color: return .color
        case .screenshot, .text: return .image
        case .none: return baseMode
        }
    }

    func begin(completion: @escaping (Outcome) -> Void) {
        Self.isSessionOnScreen = true
        Self.activeSession = self
        self.completion = completion
        screenCaptureOptions?.onSelectionChange = { [weak self] in
            self?.screenCaptureToolDidChange()
        }
        screenCaptureOptions?.onTargetChange = { [weak self] in
            self?.screenCaptureTargetDidChange()
        }
        screenCaptureOptions?.onToolbarAction = { [weak self] action in
            self?.performToolbarAction(action)
        }
        screenCaptureOptions?.onToolbarDrag = { [weak self] translation in
            // The toolbar being dragged keeps the gesture even when the
            // pointer crosses onto a display that shows its own.
            guard let self else { return }
            let panel = self.panels.first { $0.overlayView.isDraggingToolbar }
                ?? self.panelUnderMouse().flatMap { $0.overlayView.showsToolbarNow ? $0 : nil }
                ?? self.panels.first { $0.overlayView.showsToolbarNow }
            panel?.overlayView.dragToolbar(by: translation)
        }
        if freeze {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let images = await ScreenshotCaptureEngine.captureAllDisplays(
                    includePointer: self.includePointer,
                    hideVorssaintWindows: self.hideVorssaintWindows,
                    protectedWindowIDs: self.captureExcludedWindowIDs)
                guard !images.isEmpty else {
                    self.finish(.failed)
                    return
                }
                self.present(frozenImages: images)
            }
        } else {
            present(frozenImages: [:])
        }
    }

    private func present(frozenImages: [CGDirectDisplayID: CGImage]) {
        guard !finished else { return }
        let pickable = ScreenshotCaptureEngine.pickableWindows(
            hideVorssaintWindows: hideVorssaintWindows,
            protectedWindowIDs: captureExcludedWindowIDs)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0

        for screen in NSScreen.screens {
            let displayID = screen.displayID
            if freeze, frozenImages[displayID] == nil { continue }
            let windows = Self.pickableWindows(pickable,
                                               on: screen.frame,
                                               mainScreenHeight: mainHeight)

            let panel = ScreenshotOverlayPanel(screen: screen,
                                               frozenImage: frozenImages[displayID],
                                               windows: windows,
                                               controller: self,
                                               strings: strings,
                                               purpose: purpose,
                                               screenCaptureOptions: screenCaptureOptions)
            if let last = Self.lastRegion, last.displayID == displayID {
                if remembersLastArea, activeMode != .color, captureTarget == .portion,
                   CGRect(origin: .zero, size: screen.frame.size).contains(last.viewRect) {
                    panel.overlayView.beginAdjusting(last.viewRect)
                } else if showLastRegion {
                    if captureTarget == .portion {
                        panel.overlayView.ghostRect = last.viewRect
                    } else {
                        panel.overlayView.stashedGhostRect = last.viewRect
                    }
                }
            }
            // Populate the retained backing store before a full-screen
            // opaque panel can expose its black background for one frame.
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.display()
            panels.append(panel)
        }
        guard !panels.isEmpty else {
            finish(.failed)
            return
        }
        // Each guide was built inside its panel's initializer, before that
        // panel joined `panels`, so the repeat hint could not see the display
        // holding the stored region yet.
        panels.forEach { $0.overlayView.refreshCaptureGuide() }
        screenCaptureOptions?.offersRepeatLastRegion = offersRepeatLastRegion
        installKeyMonitor()
        // Give key ownership to only one destination. Opening and immediately
        // resigning a full-screen key panel can flash the surrounding chrome.
        screenCaptureOptions?.onPresentationReady?()
        guard !finished else { return }
        panels.forEach { $0.orderFrontRegardless() }
        if screenCaptureOptions?.controlsInNotch != true { keyPanelUnderMouse()?.makeKey() }
        if isPickingColor
            || UserDefaults.standard.bool(forKey: DefaultsKey.screenshotLoupeStartsOn) {
            // Opt-in: the session opens with the magnifier already up,
            // instead of waiting for the Z toggle.
            toggleLoupe()
        }
        BackgroundCursor.setAllowed(true)
        NSCursor.crosshair.set()
    }

    private func screenCaptureToolDidChange() {
        if let activeTool {
            let defaults = UserDefaults.standard
            let nextPolicy = ScreenshotSupport.unifiedCapturePolicy(
                for: activeTool,
                screenshotFreeze: defaults.bool(forKey: DefaultsKey.screenshotFreeze),
                screenshotIncludePointer: defaults.bool(forKey: DefaultsKey.screenshotIncludePointer),
                screenshotHideVorssaintWindows: defaults.bool(
                    forKey: DefaultsKey.screenshotHideVorssaintWindows))
            if !nextPolicy.sharesSource(with: capturePolicy) {
                adoptCapturePolicy(nextPolicy)
            }
        }
        scrollingCaptureEnabled = false
        loupeEnabled = isPickingColor
        screenCaptureOptions?.offersRepeatLastRegion = offersRepeatLastRegion
        if isPickingColor, !freeze { loadLiveLoupeImages() }
        panels.forEach { $0.overlayView.captureToolDidChange() }
        if selectionInProgress { setSelectionInProgress(false) }
    }

    /// The chooser stays on screen while the tool changes, so a tool that
    /// needs other pixels gets them behind the panels instead of taking the
    /// surface down and putting an identical one back up.
    private func adoptCapturePolicy(_ policy: ScreenshotSupport.UnifiedCapturePolicy) {
        capturePolicy = policy
        freeze = policy.freeze
        includePointer = policy.includePointer
        hideVorssaintWindows = policy.hideVorssaintWindows
        sourceRefreshPending = true
        sourceGeneration += 1
        let generation = sourceGeneration
        guard policy.freeze else {
            applySource(frozenImages: [:])
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let images = await ScreenshotCaptureEngine.captureAllDisplays(
                includePointer: policy.includePointer,
                hideVorssaintWindows: policy.hideVorssaintWindows,
                protectedWindowIDs: self.captureExcludedWindowIDs)
            guard !self.finished, self.sourceGeneration == generation else { return }
            self.applySource(frozenImages: images)
        }
    }

    /// All visible displays must belong to the current tool before selection
    /// resumes. A missing frame cannot safely fall back to the previous tool.
    private func applySource(frozenImages: [CGDirectDisplayID: CGImage]) {
        guard !freeze || panels.allSatisfy({ frozenImages[$0.displayID] != nil }) else {
            finish(.failed)
            return
        }
        let pickable = ScreenshotCaptureEngine.pickableWindows(
            hideVorssaintWindows: hideVorssaintWindows,
            protectedWindowIDs: captureExcludedWindowIDs)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        for panel in panels {
            let image = freeze ? frozenImages[panel.displayID] : nil
            panel.update(frozenImage: image,
                         windows: Self.pickableWindows(pickable,
                                                       on: panel.screenFrame,
                                                       mainScreenHeight: mainHeight))
        }
        sourceRefreshPending = false
        panels.forEach {
            $0.overlayView.refreshPointerState()
            $0.overlayView.refreshFullScreenControlVisibility()
        }
    }

    func placeFullScreenControlBelowNotch(screenFrame: CGRect, surfaceHeight: CGFloat) {
        for panel in panels {
            panel.overlayView.setNotchCaptureControlsHeight(
                panel.screenFrame == screenFrame ? surfaceHeight : nil)
        }
    }

    private static func pickableWindows(_ entries: [(id: CGWindowID, bounds: CGRect)],
                                        on screenFrame: CGRect,
                                        mainScreenHeight: CGFloat)
        -> [ScreenshotSupport.PickableWindow] {
        entries.map { entry -> ScreenshotSupport.PickableWindow in
            let cocoa = ScreenshotSupport.cocoaRect(fromWindowServer: entry.bounds,
                                                    mainScreenHeight: mainScreenHeight)
            let viewRect = ScreenshotSupport.flippedViewRect(fromCocoa: cocoa,
                                                             screenFrame: screenFrame)
            return ScreenshotSupport.PickableWindow(windowID: entry.id, frame: viewRect)
        }.filter { $0.frame.intersects(CGRect(origin: .zero, size: screenFrame.size)) }
    }

    /// Live selection stays transparent, but the loupe still needs source
    /// pixels. Capture them once after the overlays exist; ScreenCaptureKit
    /// excludes this app's own panels, so the screen itself remains live.
    private func loadLiveLoupeImages() {
        let generation = sourceGeneration
        let hideWindows = hideVorssaintWindows
        let excludedIDs = captureExcludedWindowIDs
        Task { @MainActor [weak self] in
            let images = await ScreenshotCaptureEngine.captureAllDisplays(
                includePointer: false,
                hideVorssaintWindows: hideWindows,
                protectedWindowIDs: excludedIDs)
            guard let self, !self.finished, self.sourceGeneration == generation else { return }
            for panel in self.panels {
                panel.overlayView.updateLoupeImage(images[panel.displayID])
            }
        }
    }

    // MARK: - Toolbar

    /// Screen and window modes take a click, not a drawn area, so the area
    /// waiting to be adjusted steps aside; coming back to portion mode brings
    /// the last one back, the way the system's toolbar does.
    private func screenCaptureTargetDidChange() {
        if captureTarget != .portion { scrollingCaptureEnabled = false }
        panels.forEach { $0.overlayView.captureTargetDidChange() }
        if selectionInProgress { setSelectionInProgress(false) }
    }

    /// The last area on this display, offered again when portion mode opens.
    fileprivate func restorableRegion(on panel: ScreenshotOverlayPanel) -> CGRect? {
        guard remembersLastArea, captureTarget == .portion, !isPickingColor,
              let last = Self.lastRegion, last.displayID == panel.displayID,
              CGRect(origin: .zero, size: panel.screenFrame.size).contains(last.viewRect)
        else { return nil }
        return last.viewRect
    }

    private func performToolbarAction(_ action: CaptureToolbarAction) {
        switch action {
        case .close:
            finish(.cancelled)
        case .confirm:
            if !confirmFromToolbar() { NSSound.beep() }
        case .markup:
            screenCaptureOptions?.markupRequested = true
            if !confirmFromToolbar() {
                screenCaptureOptions?.markupRequested = false
                NSSound.beep()
            }
        case .text:
            screenCaptureOptions?.textRequested = true
            if !confirmFromToolbar() {
                screenCaptureOptions?.textRequested = false
                NSSound.beep()
            }
        }
    }

    /// The toolbar's big button, and Markup: the area being adjusted, the
    /// screen the toolbar is on, or the window last pointed at.
    private func confirmFromToolbar() -> Bool {
        guard acceptsCaptureInput, !isPickingColor,
              !panels.contains(where: { $0.overlayView.isDragging }) else { return false }
        switch captureTarget {
        case .portion:
            return confirmAdjustedSelection()
        case .screen:
            captureFullDisplayUnderMouse()
            // A live capture finishes a moment later, once the panels are
            // gone; marking the capture pending is what proves it started.
            return finished || panels.allSatisfy { $0.overlayView.isCapturePending }
        case .window:
            // Only the display the toolbar is on: a window last shown on
            // another display is not what the person is pointing at now.
            guard let panel = panelUnderMouse(), let pick = panel.overlayView.lastWindowPick
            else { return false }
            if let windowID = pick.windowID {
                confirmWindow(windowID, frame: pick.frame, on: panel)
            } else {
                confirmRegion(pick.frame, on: panel)
            }
            return true
        }
    }

    /// Return in window mode takes what the pointer shows, never the display.
    private func confirmWindowFromKeyboard() {
        if !confirmFromToolbar() { NSSound.beep() }
    }

    /// A click in screen mode takes the display it landed on.
    fileprivate func confirmScreen(on panel: ScreenshotOverlayPanel) {
        guard acceptsCaptureInput, activeMode != .color else { return }
        captureFullDisplay(on: panel)
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            let inNotch = self.screenCaptureOptions?.controlsInNotch == true
                && event.window === NotchService.shared.presentationWindow
            guard event.window is ScreenshotOverlayPanel || inNotch else { return event }
            if inNotch {
                guard event.window?.attachedSheet == nil, !(event.window?.firstResponder is NSText),
                      !ShortcutCapture.isCapturing else { return event }
                let movesSelection = event.keyCode == UInt16(kVK_Space)
                    && (self.spaceIsDown || self.panelUnderMouse()?.overlayView.isDragging == true)
                if self.screenCaptureOptions?.hasFocusedControl == true,
                   event.keyCode != UInt16(kVK_Escape), !movesSelection { return event }
            }
            if event.type == .keyUp {
                guard event.keyCode == UInt16(kVK_Space), self.spaceIsDown else { return event }
                self.spaceIsDown = false
                return nil
            }
            switch Int(event.keyCode) {
            case kVK_Escape:
                // An open Options menu closes first, as a menu does.
                if self.screenCaptureOptions?.showsOptions == true {
                    self.screenCaptureOptions?.showsOptions = false
                } else {
                    self.finish(.cancelled)
                }
            case kVK_Return, kVK_ANSI_KeypadEnter:
                // Window mode takes the window the pointer last showed.
                if self.captureTarget == .window {
                    self.confirmWindowFromKeyboard()
                    break
                }
                self.confirmSelectionWithKeyboard()
            case kVK_Space:
                if let panel = self.panelUnderMouse(), panel.overlayView.isDragging {
                    // Holding Space moves the in-progress selection.
                    self.spaceIsDown = true
                } else { return event }
            case _ where Self.isRepeatRegionKey(event):
                self.repeatLastRegion()
            case _ where self.selectCaptureTool(for: event):
                break
            case _ where Self.isScrollingCaptureKey(event):
                self.toggleScrollingCapture()
            case _ where Self.isLoupeKey(event):
                self.toggleLoupe()
            case _ where Self.isCopyColorKey(event):
                guard self.loupeAcceptsKeyboardActions else { return event }
                self.copyLoupeColor()
            case _ where Self.isNudgeKey(event):
                guard self.loupeAcceptsKeyboardActions else { return event }
                self.nudgePointer(keyCode: Int(event.keyCode),
                                  fast: event.modifierFlags.contains(.shift))
            default:
                return event
            }
            return nil
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return }
            self?.finish(.cancelled)
        }
    }

    private func selectCaptureTool(for event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let tool = ScreenCaptureTool.matchingShortcut(event.charactersIgnoringModifiers),
              let screenCaptureOptions,
              screenCaptureOptions.availableTools.contains(tool)
        else { return false }
        screenCaptureOptions.select(tool)
        return true
    }

    /// The loupe toggle follows the typed character, with the physical slot
    /// as a fallback: the Z key sits elsewhere on some keyboard layouts and
    /// the localized hints promise the letter itself.
    private static func isLoupeKey(_ event: NSEvent) -> Bool {
        matchesShortcutKey(event, character: "z", physicalKeyCode: kVK_ANSI_Z)
    }

    private static func isScrollingCaptureKey(_ event: NSEvent) -> Bool {
        matchesShortcutKey(event, character: "s", physicalKeyCode: kVK_ANSI_S)
    }

    private static func isRepeatRegionKey(_ event: NSEvent) -> Bool {
        matchesShortcutKey(event, character: "r", physicalKeyCode: kVK_ANSI_R)
    }

    private func toggleScrollingCapture() {
        guard offersScrollingCapture else { return }
        scrollingCaptureEnabled.toggle()
        panels.forEach { $0.overlayView.refreshPointerState() }
    }

    private func toggleLoupe() {
        loupeEnabled.toggle()
        // Live mode has no frozen shot to sample. Pixels are fetched only
        // when the loupe actually turns on, and fresh each time, so it
        // magnifies what is on screen now instead of the session's opening
        // frame and idle sessions never pay for a capture.
        if loupeEnabled, !freeze {
            loadLiveLoupeImages()
        }
    }

    fileprivate func adjustLoupeZoom(by scrollDelta: CGFloat,
                                     stepped: Bool,
                                     isContinuous: Bool) {
        loupeZoom = stepped
            ? ScreenshotSupport.captureLoupeSteppedZoom(loupeZoom, adjustedBy: scrollDelta)
            : ScreenshotSupport.captureLoupeFastZoom(loupeZoom, adjustedBy: scrollDelta,
                                                     isContinuous: isContinuous)
    }

    /// C copies the color under the pointer in the configured picker format
    /// without ending the session, so a whole palette can be read off one
    /// frozen screen. Only meaningful while the loupe shows which pixel.
    private static func isCopyColorKey(_ event: NSEvent) -> Bool {
        matchesShortcutKey(event, character: "c", physicalKeyCode: kVK_ANSI_C)
    }

    /// Accept either the character promised by the shortcut hint or its
    /// physical ANSI key. The latter keeps shortcuts reachable on layouts
    /// whose printable character is non-Latin.
    private static func matchesShortcutKey(_ event: NSEvent,
                                           character: String,
                                           physicalKeyCode: Int) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        else { return false }
        return event.charactersIgnoringModifiers?.lowercased() == character
            || Int(event.keyCode) == physicalKeyCode
    }

    private static func isNudgeKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        else { return false }
        return [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow]
            .contains(Int(event.keyCode))
    }

    private var loupeAcceptsKeyboardActions: Bool {
        acceptsCaptureInput && loupeEnabled && !panels.contains(where: { $0.overlayView.isDragging })
    }

    private func copyLoupeColor() {
        guard loupeAcceptsKeyboardActions else { return }
        // The readout, ring and copy all sample the same loupe image. In live
        // selection that image is the snapshot loaded when the loupe opens;
        // toggling Z refreshes it without letting C copy a different frame
        // from the one currently drawn.
        panelUnderMouse()?.overlayView.copyLoupeColorUnderPointer()
    }

    /// Arrow keys nudge the pointer by exactly one device pixel (ten with
    /// Shift) while the loupe is up and no drag is in flight; nudging under
    /// a held button would resize the selection behind the person's back.
    /// The pointer may cross onto a neighbouring display; only when no
    /// display contains the target does it stop at the current edge.
    /// Warping generates no mouse event, so the overlays are refreshed by
    /// hand with the position just warped to.
    private func nudgePointer(keyCode: Int, fast: Bool) {
        guard loupeAcceptsKeyboardActions else { return }
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        switch keyCode {
        case kVK_LeftArrow: dx = -1
        case kVK_RightArrow: dx = 1
        case kVK_UpArrow: dy = 1
        case kVK_DownArrow: dy = -1
        default: return
        }
        let location = currentPointerLocation ?? NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(location, $0.frame, false) })
            ?? NSScreen.withMouse else { return }
        let delta = ScreenshotSupport.captureLoupeNudge(dx: dx,
                                                        dy: dy,
                                                        fast: fast,
                                                        scale: screen.backingScaleFactor)
        var target = CGPoint(x: location.x + delta.x, y: location.y + delta.y)
        if !NSScreen.screens.contains(where: { NSMouseInRect(target, $0.frame, false) }) {
            // The pointer spans [minX, maxX) x (minY, maxY], as NSMouseInRect counts it.
            let frame = screen.frame
            let pixel = 1 / max(screen.backingScaleFactor, 1)
            target = CGPoint(
                x: min(max(target.x, frame.minX), frame.maxX - pixel),
                y: min(max(target.y, frame.minY + pixel), frame.maxY))
        }
        currentPointerLocation = target
        let mainHeight = NSScreen.withMenuBar?.frame.height ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: target.x, y: mainHeight - target.y))
        panels.forEach { $0.overlayView.refreshPointerState(mouseLocation: target) }
    }

    private func panelUnderMouse() -> ScreenshotOverlayPanel? {
        let location = currentPointerLocation ?? NSEvent.mouseLocation
        return panels.first { NSMouseInRect(location, $0.screenFrame, false) } ?? panels.first
    }

    private func keyPanelUnderMouse() -> ScreenshotOverlayPanel? {
        panelUnderMouse()
    }

    // MARK: - Confirmations (called by the views)

    private func confirmSelectionWithKeyboard() {
        if confirmAdjustedSelection() { return }
        if isPickingColor {
            guard acceptsCaptureInput, !panels.contains(where: { $0.overlayView.isDragging }),
                  let panel = panelUnderMouse() else { return }
            let location = currentPointerLocation ?? NSEvent.mouseLocation
            let point = CGPoint(x: location.x - panel.screenFrame.minX,
                                y: panel.screenFrame.maxY - location.y)
            confirmColor(at: point, on: panel)
        } else if acceptsWindowClick {
            captureFullDisplayUnderMouse()
        }
    }

    /// Return takes the area waiting to be adjusted, preferring the display
    /// under the pointer when more than one holds one.
    private func confirmAdjustedSelection() -> Bool {
        guard acceptsCaptureInput, !isPickingColor else { return false }
        let candidates = panels.filter { $0.overlayView.adjustedSelection != nil }
        guard let panel = candidates.first(where: { $0 === panelUnderMouse() }) ?? candidates.first,
              let rect = panel.overlayView.adjustedSelection else { return false }
        confirmRegion(rect, on: panel)
        return true
    }

    /// An area drawn, moved or resized is remembered at once, so the next
    /// session opens on it even when this one is closed without a capture.
    fileprivate func rememberArea(_ viewRect: CGRect, on panel: ScreenshotOverlayPanel) {
        guard activeMode != .color, viewRect.width >= 1, viewRect.height >= 1 else { return }
        Self.lastRegion = (panel.displayID, viewRect)
    }

    /// Drawing a new area on one display drops the one waiting on another.
    fileprivate func endAdjusting(except kept: ScreenshotOverlayPanel) {
        panels.filter { $0 !== kept }.forEach { $0.overlayView.endAdjusting() }
    }

    /// The button under an adjusted area records for the recorder and
    /// captures otherwise.
    fileprivate var confirmsByRecording: Bool {
        activeMode == .geometry && !scrollingCaptureEnabled && activeTool == .recording
    }

    /// The surfaces stop answering the pointer the instant a picture starts
    /// being taken. They are either about to leave the screen or already gone,
    /// and the rest of the gesture must not begin a second capture.
    private func markCapturePending() {
        panels.forEach { $0.overlayView.isCapturePending = true }
    }

    /// The picked area as the recorder needs it: whole even pixels of the
    /// source display, plus the same area in Cocoa points so a panel can be
    /// anchored to it. The point rectangle is derived from the SNAPPED pixels,
    /// so what gets recorded and what the person was shown never disagree.
    private func region(fromView viewRect: CGRect,
                        on panel: ScreenshotOverlayPanel,
                        windowID: CGWindowID?) -> RecorderSupport.Region {
        let displayPixels = CGRect(origin: .zero, size: panel.pixelSize)
        let raw = ScreenshotSupport.imagePixelRect(fromView: viewRect,
                                                   viewSize: panel.screenFrame.size,
                                                   imageSize: panel.pixelSize)
        let snapped = RecorderSupport.snappedPixelRect(raw, in: displayPixels)
        let scale = panel.pixelScale > 0 ? panel.pixelScale : 1
        let snappedView = CGRect(x: snapped.origin.x / scale,
                                 y: snapped.origin.y / scale,
                                 width: snapped.width / scale,
                                 height: snapped.height / scale)
        return RecorderSupport.Region(
            displayID: panel.displayID,
            windowID: windowID,
            pixelRect: snapped,
            anchorRect: ScreenshotSupport.cocoaRect(fromFlippedView: snappedView,
                                                    screenFrame: panel.screenFrame),
            scale: scale)
    }

    fileprivate func confirmRegion(_ viewRect: CGRect, on panel: ScreenshotOverlayPanel) {
        guard acceptsCaptureInput, activeMode != .color,
              viewRect.width >= 1, viewRect.height >= 1 else { return }
        markCapturePending()
        Self.lastRegion = (panel.displayID, viewRect)
        if activeMode == .geometry {
            finish(.region(region(fromView: viewRect, on: panel, windowID: nil)))
            return
        }
        if scrollingCaptureEnabled {
            finish(.scrollingRegion(region(fromView: viewRect, on: panel, windowID: nil)))
            return
        }
        let pixelRect = ScreenshotSupport.imagePixelRect(
            fromView: viewRect,
            viewSize: panel.screenFrame.size,
            imageSize: panel.frozenImageSize ?? panel.pixelSize)
        if let frozen = panel.frozenImage {
            guard let cropped = frozen.cropping(to: pixelRect) else {
                finish(.failed)
                return
            }
            finish(.captured(Capture(
                image: cropped,
                scale: panel.pixelScale,
                anchorRect: ScreenshotSupport.cocoaRect(
                    fromFlippedView: viewRect,
                    screenFrame: panel.screenFrame))))
        } else {
            captureLive(displayID: panel.displayID,
                        pixelRect: pixelRect,
                        scale: panel.pixelScale,
                        anchorRect: ScreenshotSupport.cocoaRect(
                            fromFlippedView: viewRect,
                            screenFrame: panel.screenFrame))
        }
    }

    fileprivate func confirmWindow(_ windowID: CGWindowID,
                                   frame: CGRect,
                                   on panel: ScreenshotOverlayPanel) {
        guard acceptsCaptureInput, activeMode != .color else { return }
        markCapturePending()
        if activeMode == .geometry {
            finish(.region(region(fromView: frame, on: panel, windowID: windowID)))
            return
        }
        if scrollingCaptureEnabled {
            finish(.scrollingRegion(region(fromView: frame, on: panel, windowID: windowID)))
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // A composite with an attached dialog may be captured at another
            // display's scale than this panel's; record the one it has.
            guard let capture = await ScreenshotCaptureEngine.captureWindow(
                windowID, scale: panel.pixelScale) else {
                self.finish(.failed)
                return
            }
            self.finish(.captured(Capture(
                image: capture.image,
                scale: capture.scale,
                anchorRect: ScreenshotSupport.cocoaRect(
                    fromFlippedView: frame,
                    screenFrame: panel.screenFrame))))
        }
    }

    private func captureFullDisplayUnderMouse() {
        guard acceptsCaptureInput, activeMode != .color else { return }
        guard let panel = panelUnderMouse() else { return }
        captureFullDisplay(on: panel)
    }

    fileprivate func captureFullScreenFromControl(on panel: ScreenshotOverlayPanel) {
        guard offersFullScreenCapture else { return }
        captureFullDisplay(on: panel)
    }

    private func captureFullDisplay(on panel: ScreenshotOverlayPanel) {
        markCapturePending()
        if activeMode == .geometry {
            let whole = CGRect(origin: .zero, size: panel.screenFrame.size)
            finish(.region(region(fromView: whole, on: panel, windowID: nil)))
            return
        }
        if let frozen = panel.frozenImage {
            finish(.captured(Capture(image: frozen,
                                     scale: panel.pixelScale,
                                     anchorRect: panel.screenFrame)))
        } else {
            captureLive(displayID: panel.displayID,
                        pixelRect: nil,
                        scale: panel.pixelScale,
                        anchorRect: panel.screenFrame)
        }
    }

    private func repeatLastRegion() {
        guard offersRepeatLastRegion,
              let last = Self.lastRegion,
              let panel = repeatTargetPanel
        else { return }
        confirmRegion(last.viewRect, on: panel)
    }

    fileprivate func confirmColor(at viewPoint: CGPoint, on panel: ScreenshotOverlayPanel) {
        guard acceptsCaptureInput, activeMode == .color,
              let image = panel.frozenImage ?? panel.overlayView.loupeImage else { return }
        let point = ScreenshotSupport.imagePixelPoint(
            fromView: viewPoint,
            viewSize: panel.screenFrame.size,
            imageSize: CGSize(width: image.width, height: image.height))
        let x = min(max(Int(point.x.rounded(.down)), 0), image.width - 1)
        let y = min(max(Int(point.y.rounded(.down)), 0), image.height - 1)
        guard let color = QuickToolsSupport.sampledColor(in: image, x: x, y: y)
        else {
            finish(.failed)
            return
        }
        markCapturePending()
        finish(.color(color))
    }

    /// Live-mode confirmation: the panels leave the screen, the display is
    /// photographed, and only then does the session end. The brief hide is
    /// what the capture must not contain.
    private func captureLive(displayID: CGDirectDisplayID,
                             pixelRect: CGRect?,
                             scale: CGFloat,
                             anchorRect: CGRect) {
        retirePanels()
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard var image = await ScreenshotCaptureEngine.captureDisplay(
                displayID,
                includePointer: self.includePointer,
                hideVorssaintWindows: self.hideVorssaintWindows,
                protectedWindowIDs: self.captureExcludedWindowIDs)
            else {
                self.finish(.failed)
                return
            }
            if let pixelRect {
                let clamped = ScreenshotSupport.clamp(
                    pixelRect,
                    to: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                guard let cropped = image.cropping(to: clamped) else {
                    self.finish(.failed)
                    return
                }
                image = cropped
            }
            self.finish(.captured(Capture(image: image,
                                          scale: scale,
                                          anchorRect: anchorRect)))
        }
    }

    func cancel() {
        finish(.cancelled)
    }

    /// A panel takes every press until its window is really gone, and AppKit
    /// fades it out after `orderOut`, so a quick click or the first scroll
    /// after a capture landed on the leaving panel. A session never shows its
    /// panels again, so they let go of the mouse first. Set alone, the flag
    /// reaches the window server only with the next commit, too late for a
    /// panel already fading, so the flush sends it before the panels leave.
    private func retirePanels() {
        panels.forEach { $0.ignoresMouseEvents = true }
        CATransaction.flush()
        panels.forEach { $0.orderOut(nil) }
    }

    deinit {
        // A session that goes away without ending would otherwise leave the
        // screen marked as taken and every capture feature dead until the app
        // is restarted. The wrong flag is always the one that lets a capture
        // start, never the one that blocks it.
        if !finished {
            Self.isSessionOnScreen = false
            if Self.activeSession === self { Self.activeSession = nil }
        }
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        Self.isSessionOnScreen = false
        if Self.activeSession === self { Self.activeSession = nil }
        screenCaptureOptions?.onSelectionChange = nil
        screenCaptureOptions?.onTargetChange = nil
        screenCaptureOptions?.onToolbarAction = nil
        screenCaptureOptions?.onToolbarDrag = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
        // A gesture can still have events on the way, so the surfaces are made
        // inert before they leave the screen: whatever arrives after this
        // point finds nothing left to act on.
        markCapturePending()
        retirePanels()
        panels.removeAll()
        NSCursor.arrow.set()
        BackgroundCursor.setAllowed(false)
        let completion = completion
        self.completion = nil
        completion?(outcome)
    }
}

// MARK: - Cursor

/// The window server ignores cursor changes from an app in the background,
/// and the capture panels keep the app there, so the crosshair the surface
/// asked for never appeared (measured on macOS 27). The connection property
/// lifts that only while a session is up. Resolved at runtime, so a macOS
/// that drops it degrades to the arrow pointer as before.
private enum BackgroundCursor {
    private typealias ConnectionID = UInt32
    private typealias SetPropertyFunction =
        @convention(c) (ConnectionID, ConnectionID, CFString, CFTypeRef) -> CGError

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2) /* RTLD_DEFAULT */, name)
    }

    private static let connection: ConnectionID = {
        typealias Function = @convention(c) () -> ConnectionID
        guard let symbol = symbol("CGSMainConnectionID") else { return 0 }
        return unsafeBitCast(symbol, to: Function.self)()
    }()

    private static let setProperty: SetPropertyFunction? = {
        guard let symbol = symbol("CGSSetConnectionProperty") else { return nil }
        return unsafeBitCast(symbol, to: SetPropertyFunction.self)
    }()

    static func setAllowed(_ allowed: Bool) {
        guard connection != 0, let setProperty else { return }
        _ = setProperty(connection, connection, "SetsCursorInBackground" as CFString,
                        allowed ? kCFBooleanTrue : kCFBooleanFalse)
    }
}

/// The pointers screen mode shows, as the system's toolbar does: a camera
/// over a display a click would photograph, a video camera over one it
/// would record. White with a dark rim, so they read on any picture.
private enum CaptureModeCursor {
    static let camera = make("camera.fill")
    static let record = make("video.fill")

    private static func make(_ symbol: String) -> NSCursor {
        let size = CGSize(width: 30, height: 30)
        let configuration = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return .crosshair }
        let image = NSImage(size: size, flipped: false) { rect in
            let glyphSize = glyph.size
            let target = CGRect(x: rect.midX - glyphSize.width / 2,
                                y: rect.midY - glyphSize.height / 2,
                                width: glyphSize.width, height: glyphSize.height)
            func tinted(_ color: NSColor) -> NSImage {
                let copy = NSImage(size: glyphSize, flipped: false) { bounds in
                    glyph.draw(in: bounds)
                    color.set()
                    bounds.fill(using: .sourceAtop)
                    return true
                }
                return copy
            }
            let rim = tinted(.black.withAlphaComponent(0.75))
            for (dx, dy) in [(-1.0, 0.0), (1, 0), (0, -1), (0, 1)] {
                rim.draw(in: target.offsetBy(dx: dx, dy: dy))
            }
            tinted(.white).draw(in: target)
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: size.width / 2, y: size.height / 2))
    }
}

// MARK: - Panel

/// Full-screen borderless panel for one display. Never activates the app;
/// becomes key only so Esc and friends arrive.
private final class ScreenshotOverlayPanel: OverlayPanel {
    let screenFrame: CGRect
    let displayID: CGDirectDisplayID
    /// Height reserved by macOS chrome at the top of this display. The
    /// full-screen action stays below it even when there is no notch surface.
    let topChromeHeight: CGFloat
    private(set) var frozenImage: CGImage?
    let pixelScale: CGFloat
    private(set) var overlayViewStorage: ScreenshotOverlayView!
    private var backdropView: NSImageView!

    var overlayView: ScreenshotOverlayView { overlayViewStorage }

    var frozenImageSize: CGSize? {
        frozenImage.map { CGSize(width: $0.width, height: $0.height) }
    }

    /// Display size in pixels, for live-mode crop math.
    var pixelSize: CGSize {
        CGSize(width: screenFrame.width * pixelScale, height: screenFrame.height * pixelScale)
    }

    init(screen: NSScreen,
         frozenImage: CGImage?,
         windows: [ScreenshotSupport.PickableWindow],
         controller: ScreenshotSelectionController,
         strings: ScreenshotFeatureStrings,
         purpose: String?,
         screenCaptureOptions: ScreenCaptureSelectionOptions?) {
        screenFrame = screen.frame
        displayID = screen.displayID
        topChromeHeight = max(screen.safeAreaInsets.top,
                              screen.frame.maxY - screen.visibleFrame.maxY)
        self.frozenImage = frozenImage
        pixelScale = screen.backingScaleFactor
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isReleasedWhenClosed = false
        isOpaque = frozenImage != nil
        backgroundColor = frozenImage == nil ? .clear : .black
        hasShadow = false
        // A frame change on this visible shielding window is scaled by the
        // window server around the window's centre. The dim, and the still
        // under it, then sit inside the display for a fraction of a second
        // instead of covering its width and height.
        animationBehavior = .none
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        // Live, the panel is clear, and with the controls in Dynamic Island it
        // draws nothing over the desktop until a drag starts. Left at its
        // default, a window hands a press on a fully transparent pixel to
        // whatever is under it, so the desktop took the drag instead of the
        // selection (#3005). Set explicitly, the panel takes every press.
        ignoresMouseEvents = false

        // The frozen still sits in its own view UNDER the chrome: a backing
        // layer configured before the view joins a window can lose its
        // contents, and the chrome's dim must paint over the image anyway.
        let container = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        let imageView = NSImageView(frame: container.bounds)
        imageView.image = frozenImage.map { NSImage(cgImage: $0, size: screen.frame.size) }
        imageView.imageScaling = .scaleAxesIndependently
        imageView.autoresizingMask = [.width, .height]
        container.addSubview(imageView)
        backdropView = imageView
        let view = ScreenshotOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size),
                                         frozenImage: frozenImage,
                                         loupeImage: frozenImage,
                                         windows: windows,
                                         controller: controller,
                                         panel: self,
                                         strings: strings,
                                         purpose: purpose,
                                         screenCaptureOptions: screenCaptureOptions)
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        overlayViewStorage = view
        container.autoresizingMask = [.width, .height]
        contentView = container
    }

    /// Tool chrome lives in hosting views whose ideal size is a small bar.
    /// Accepting that size pulls this window in from every edge.
    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool) {
        super.setFrame(Self.frameCoveringScreen(screenFrame, insteadOf: frameRect), display: displayFlag)
    }

    private static func frameCoveringScreen(_ screen: NSRect, insteadOf requested: NSRect) -> NSRect {
        guard !screen.isEmpty else { return requested }
        let drifted = abs(requested.width - screen.width) > 1
            || abs(requested.height - screen.height) > 1
            || abs(requested.minX - screen.minX) > 1
            || abs(requested.minY - screen.minY) > 1
        return drifted ? screen : requested
    }

    /// New pixels for a tool that needs its own photograph, without the
    /// panel ever leaving the screen.
    func update(frozenImage: CGImage?, windows: [ScreenshotSupport.PickableWindow]) {
        self.frozenImage = frozenImage
        isOpaque = frozenImage != nil
        backgroundColor = frozenImage == nil ? .clear : .black
        backdropView.image = frozenImage.map { NSImage(cgImage: $0, size: screenFrame.size) }
        overlayView.update(frozenImage: frozenImage, windows: windows)
    }

    override var canBecomeKey: Bool { true }
}

// MARK: - View

/// Draws the frozen background, the dim, the selection, window highlights
/// and the magnifier; owns all mouse interaction. Flipped so
/// geometry matches image pixels (top-left origin) with no sign juggling.
private final class ScreenshotOverlayView: NSView {
    private var pointerHasMoved = false
    private var frozenImage: CGImage?
    fileprivate var loupeImage: CGImage?
    private var windows: [ScreenshotSupport.PickableWindow]
    /// Both are held weakly on purpose. The session hands its result over
    /// after the panels leave the screen, so the controller is already gone
    /// while the window server still delivers the tail of a gesture here.
    private weak var controller: ScreenshotSelectionController?
    private weak var panel: ScreenshotOverlayPanel?
    private let strings: ScreenshotFeatureStrings
    private let purpose: String?
    private let screenCaptureOptions: ScreenCaptureSelectionOptions?
    private let guideHost: PassThroughHostingView<CaptureGuideView>
    private let fullScreenHost: PassThroughHostingView<FullScreenCaptureButton>
    private var notchCaptureControlsHeight: CGFloat?
    private var fullScreenControlHovered = false
    private var deferredNotchCaptureControlsHeight: CGFloat?
    private var hasDeferredNotchCaptureControlsHeight = false

    private var dragOrigin: CGPoint?
    private var lastDragPoint: CGPoint = .zero
    private var selection: CGRect = .zero
    private var hoverPoint: CGPoint = .zero
    private var pointerIsInside = false
    private var hoveredWindow: ScreenshotSupport.PickableWindow?
    private let highlightWindowsPreference = UserDefaults.standard.bool(forKey: DefaultsKey.screenshotHighlightWindows)
    /// Window mode always outlines the window it would take; screen mode
    /// takes the whole display, so no window is singled out there.
    private var highlightWindows: Bool {
        switch controller?.captureTarget ?? .portion {
        case .window: return true
        case .screen: return false
        case .portion: return highlightWindowsPreference
        }
    }
    /// The system-style toolbar and its Options menu, when this surface has
    /// them; nil where the controls live in Dynamic Island or nowhere.
    private var toolbarHost: PassThroughHostingView<CaptureToolbarView>?
    private var optionsHost: PassThroughHostingView<CaptureOptionsCard>?
    private var toolbarDragStart: CGPoint?
    private var optionsObservation: AnyCancellable?
    /// A press in screen or window mode, taken on release like a click.
    private var pendingTargetClick: CGPoint?
    /// What the pointer last showed in window mode, which the toolbar's
    /// button and Return take: a window, or a smaller part of one (no id)
    /// the wheel stepped in to.
    private(set) var lastWindowPick: (windowID: CGWindowID?, frame: CGRect)?
    private var settingsObservation: AnyCancellable?
    /// The last area outline, set aside while screen or window mode is on.
    var stashedGhostRect: CGRect?

    var showsToolbarNow: Bool { toolbarHost.map { !$0.isHidden } ?? false }
    var isDraggingToolbar: Bool { toolbarDragStart != nil }
    /// Parts of the window under the pointer, smallest first, in view
    /// coordinates; the pointer picks one and the wheel steps between them.
    private let smartAreasEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.screenshotSmartAreas)
    private var smartAreas: [CGRect] = []
    private var smartLevel = 0
    private var smartWindowID: CGWindowID?
    /// The person stepped to another level; moving keeps that part while
    /// the pointer stays on it.
    private var smartLevelChosen = false
    private var smartQueryInFlight = false
    private var smartPendingPoint: CGPoint?
    private var smartScrollAccumulator: CGFloat = 0
    /// The value just copied with C, shown briefly in the loupe's info bar
    /// because the regular HUD sits under these shielding-level panels.
    private var copiedValue: String?
    private var copiedValueReset: DispatchWorkItem?
    var ghostRect: CGRect?
    var isCapturePending = false {
        didSet {
            refreshGuideVisibility()
            refreshFullScreenControlVisibility()
            refreshConfirmControl()
            needsDisplay = true
        }
    }

    /// The selection is drawn and waits to be moved, resized or taken.
    private(set) var isAdjusting = false
    private enum AdjustHandle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }
    private enum DragAction {
        case draw
        case move(CGRect)
        case resize(AdjustHandle, CGRect)
    }
    private var dragAction = DragAction.draw
    /// The adjusted area a press outside it replaced, put back if the press
    /// turns out to be a click rather than a new drag.
    private var replacedSelection: CGRect?
    private let confirmHost: PassThroughHostingView<SelectionConfirmButton>

    var adjustedSelection: CGRect? {
        isAdjusting && !isDragging && selection.width >= 1 && selection.height >= 1 ? selection : nil
    }
    /// A tool change keeps the area being adjusted, unless the new tool
    /// picks a color instead of an area.
    var keepsAdjustedSelection: Bool {
        isAdjusting && controller?.isPickingColor == false
    }

    var isDragging: Bool { dragOrigin != nil }

    /// A surface whose session is over answers nothing, so the rest of a
    /// gesture can neither reach a controller that is gone nor start a second
    /// capture behind the one already running.
    private var acceptsPointerInput: Bool {
        controller?.acceptsCaptureInput == true && ScreenshotSupport.selectionAcceptsPointerInput(
            sessionIsOver: controller?.isOver ?? true,
            capturePending: isCapturePending)
    }

    func update(frozenImage: CGImage?, windows: [ScreenshotSupport.PickableWindow]) {
        self.frozenImage = frozenImage
        self.loupeImage = frozenImage
        self.windows = windows
        refreshPointerState()
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// With the controls in Dynamic Island, the island's panel holds key
    /// focus for its shortcuts and this surface never becomes key on its own.
    /// AppKit would then spend the first click making the window key and
    /// swallow it, so the first drag drew nothing. Claim it instead.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(frame: CGRect,
         frozenImage: CGImage?,
         loupeImage: CGImage?,
         windows: [ScreenshotSupport.PickableWindow],
         controller: ScreenshotSelectionController,
         panel: ScreenshotOverlayPanel,
         strings: ScreenshotFeatureStrings,
         purpose: String?,
         screenCaptureOptions: ScreenCaptureSelectionOptions?) {
        self.frozenImage = frozenImage
        self.loupeImage = loupeImage
        self.windows = windows
        self.controller = controller
        self.panel = panel
        self.strings = strings
        self.purpose = purpose
        self.screenCaptureOptions = screenCaptureOptions
        let host = PassThroughHostingView(fixedFrameRootView: CaptureGuideView(
            strings: strings,
            purpose: purpose,
            offersScrollingCapture: controller.offersScrollingCapture,
            offersRepeatLastRegion: controller.offersRepeatLastRegion,
            requiresDraggedRegion: controller.requiresDraggedRegion,
            scrollingCaptureEnabled: controller.scrollingCaptureEnabled,
            loupeEnabled: controller.loupeEnabled,
            screenCaptureOptions: screenCaptureOptions))
        host.passesThrough = screenCaptureOptions == nil
        guideHost = host
        let hoverRelay = FullScreenControlHoverRelay()
        let fullScreen = PassThroughHostingView(interactiveRootView: FullScreenCaptureButton(
            action: { [weak controller, weak panel] in
                guard let controller, let panel else { return }
                controller.captureFullScreenFromControl(on: panel)
            },
            hoverChanged: { hoverRelay.update($0) }))
        fullScreenHost = fullScreen
        confirmHost = PassThroughHostingView(interactiveRootView: SelectionConfirmButton(
            recording: false,
            action: { [weak controller, weak panel] in
                guard let controller, let panel,
                      let rect = panel.overlayView.adjustedSelection else { return }
                controller.confirmRegion(rect, on: panel)
            }))
        if controller.showsToolbar, let screenCaptureOptions {
            toolbarHost = PassThroughHostingView(interactiveRootView: CaptureToolbarView(
                options: screenCaptureOptions))
            optionsHost = PassThroughHostingView(interactiveRootView: CaptureOptionsCard(
                options: screenCaptureOptions))
        }
        super.init(frame: frame)
        hoverRelay.changed = { [weak self] in self?.fullScreenControlHoverChanged($0) }
        let tracking = NSTrackingArea(rect: .zero,
                                      options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited,
                                                .inVisibleRect],
                                      owner: self)
        addTrackingArea(tracking)
        addSubview(guideHost)
        addSubview(fullScreenHost)
        addSubview(confirmHost)
        if let toolbarHost, let optionsHost {
            addSubview(toolbarHost)
            addSubview(optionsHost)
            optionsObservation = screenCaptureOptions?.$showsOptions
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.refreshGuideVisibility()
                    self?.needsLayout = true
                }
            // A choice in the Options menu can add or remove a row, so the
            // card is measured again whenever a preference changes.
            settingsObservation = NotificationCenter.default
                .publisher(for: UserDefaults.didChangeNotification)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.needsLayout = true }
        }
        refreshGuideVisibility()
        refreshFullScreenControlVisibility()
        refreshConfirmControl()
    }

    // MARK: Adjusting

    func beginAdjusting(_ rect: CGRect) {
        selection = ScreenshotSupport.clamp(rect, to: bounds)
        isAdjusting = true
        ghostRect = nil
        if let panel { controller?.rememberArea(selection, on: panel) }
        refreshConfirmControl()
        needsDisplay = true
    }

    func endAdjusting() {
        guard isAdjusting else { return }
        isAdjusting = false
        if !isDragging { selection = .zero }
        refreshConfirmControl()
        needsDisplay = true
    }

    /// The toolbar switched between screen, window and portion.
    func captureTargetDidChange() {
        dragOrigin = nil
        pendingTargetClick = nil
        clearSmartAreas()
        hoveredWindow = nil
        lastWindowPick = nil
        let target = controller?.captureTarget ?? .portion
        if target == .portion {
            if ghostRect == nil, let stashed = stashedGhostRect {
                ghostRect = stashed
                stashedGhostRect = nil
            }
            if !isAdjusting, let panel, let rect = controller?.restorableRegion(on: panel) {
                beginAdjusting(rect)
            }
        } else {
            if let ghostRect {
                stashedGhostRect = ghostRect
                self.ghostRect = nil
            }
            isAdjusting = false
            selection = .zero
            refreshConfirmControl()
        }
        refreshPointerState()
        needsLayout = true
        needsDisplay = true
    }

    private func pointerIsOverToolbar(_ point: CGPoint) -> Bool {
        (toolbarHost.map { !$0.isHidden && $0.frame.contains(point) } ?? false)
            || (optionsHost.map { !$0.isHidden && $0.frame.contains(point) } ?? false)
    }

    /// Window mode remembers what it shows: the part the wheel picked, or
    /// the window under the pointer.
    private func refreshWindowPick() {
        guard controller?.captureTarget == .window else { return }
        if let area = hoveredArea, area.contains(hoverPoint) {
            lastWindowPick = (area == smartAreas.last ? smartWindowID : nil, area)
        } else if let window = hoveredWindow {
            lastWindowPick = (window.windowID, window.frame)
        }
    }

    /// Follows a drag of the toolbar, kept whole on this display, and stores
    /// where it was let go so the next session opens it there.
    func dragToolbar(by translation: CGSize?) {
        guard let toolbarHost else { return }
        guard let translation else {
            if toolbarDragStart != nil {
                toolbarDragStart = nil
                UserDefaults.standard.set(
                    ScreenshotSupport.captureToolbarStoredPosition(frame: toolbarHost.frame, bounds: bounds),
                    forKey: DefaultsKey.captureToolbarPosition)
                needsLayout = true
            }
            return
        }
        if toolbarDragStart == nil { toolbarDragStart = toolbarHost.frame.origin }
        guard let start = toolbarDragStart else { return }
        toolbarHost.setFrameOrigin(ScreenshotSupport.clampedCaptureToolbarOrigin(
            CGPoint(x: start.x + translation.width, y: start.y + translation.height),
            size: toolbarHost.frame.size, bounds: bounds))
        layoutOptionsCard()
    }

    private func layoutOptionsCard() {
        guard let toolbarHost, let optionsHost else { return }
        let size = optionsHost.fittingSize
        let toolbar = toolbarHost.frame
        let margin = ScreenshotSupport.captureToolbarMargin
        var x = toolbar.maxX - size.width - 70
        x = min(max(x, bounds.minX + margin), bounds.maxX - size.width - margin)
        var y = toolbar.minY - size.height - 8
        if y < bounds.minY + margin { y = toolbar.maxY + 8 }
        optionsHost.frame = CGRect(x: x.rounded(), y: y.rounded(),
                                   width: size.width, height: size.height)
    }

    func refreshConfirmControl() {
        // With the system-style toolbar, its own Capture or Record button
        // takes the area, as on macOS; the button under the area is for the
        // surfaces without it.
        let shown = toolbarHost == nil && adjustedSelection != nil && !isCapturePending
            && controller?.acceptsCaptureInput == true
        confirmHost.isHidden = !shown
        guard shown else { return }
        let recording = controller?.confirmsByRecording ?? false
        if confirmHost.rootView.recording != recording {
            confirmHost.rootView = SelectionConfirmButton(recording: recording, action: confirmHost.rootView.action)
        }
        let size = confirmHost.fittingSize
        let width = max(size.width, 1), height = max(size.height, 34)
        var y = selection.maxY + 14
        if y + height > bounds.maxY - 8 { y = selection.minY - height - 14 }
        if y < 8 { y = selection.maxY - height - 12 }
        let x = min(max(selection.midX - width / 2, 8), bounds.maxX - width - 8)
        confirmHost.frame = CGRect(x: x, y: y, width: width, height: height)
    }

    private func handleRects() -> [(AdjustHandle, CGRect)] {
        let r = selection, s: CGFloat = 16
        func box(_ x: CGFloat, _ y: CGFloat) -> CGRect { CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s) }
        return [(.topLeft, box(r.minX, r.minY)), (.topRight, box(r.maxX, r.minY)),
                (.bottomRight, box(r.maxX, r.maxY)), (.bottomLeft, box(r.minX, r.maxY)),
                (.top, CGRect(x: r.minX + s / 2, y: r.minY - 5, width: max(0, r.width - s), height: 10)),
                (.bottom, CGRect(x: r.minX + s / 2, y: r.maxY - 5, width: max(0, r.width - s), height: 10)),
                (.left, CGRect(x: r.minX - 5, y: r.minY + s / 2, width: 10, height: max(0, r.height - s))),
                (.right, CGRect(x: r.maxX - 5, y: r.minY + s / 2, width: 10, height: max(0, r.height - s)))]
    }

    private func handle(at point: CGPoint) -> AdjustHandle? {
        guard adjustedSelection != nil else { return nil }
        return handleRects().first { $0.1.contains(point) }?.0
    }

    private static func resized(_ start: CGRect, by handle: AdjustHandle, to point: CGPoint,
                                in bounds: CGRect) -> CGRect {
        let p = CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX),
                        y: min(max(point.y, bounds.minY), bounds.maxY))
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        switch handle {
        case .topLeft: minX = p.x; minY = p.y
        case .top: minY = p.y
        case .topRight: maxX = p.x; minY = p.y
        case .right: maxX = p.x
        case .bottomRight: maxX = p.x; maxY = p.y
        case .bottom: maxY = p.y
        case .bottomLeft: minX = p.x; maxY = p.y
        case .left: minX = p.x
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY),
                      width: max(abs(maxX - minX), 4), height: max(abs(maxY - minY), 4))
    }

    private static func moved(_ start: CGRect, by delta: CGPoint, in bounds: CGRect) -> CGRect {
        var rect = start.offsetBy(dx: delta.x, dy: delta.y)
        rect.origin.x = min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
        rect.origin.y = min(max(rect.minY, bounds.minY), bounds.maxY - rect.height)
        return rect
    }

    // MARK: Smart areas

    private var hoveredArea: CGRect? {
        guard !smartAreas.isEmpty, dragOrigin == nil else { return nil }
        let area = smartAreas[min(smartLevel, smartAreas.count - 1)]
        // The area waiting to be adjusted keeps the pointer while it is on
        // it; anywhere else the part under the pointer is offered, even where
        // it overlaps that area.
        if let adjusted = adjustedSelection, adjusted.contains(hoverPoint) { return nil }
        return area
    }

    private var smartAreasApply: Bool {
        guard smartAreasEnabled, let controller else { return false }
        return controller.acceptsCaptureInput && !controller.isPickingColor
            && !controller.requiresDraggedRegion && !isCapturePending
            && controller.captureTarget != .screen
    }

    private func clearSmartAreas() {
        guard !smartAreas.isEmpty || smartWindowID != nil else { return }
        smartAreas = []
        smartWindowID = nil
        smartLevelChosen = false
        needsDisplay = true
    }

    private func requestSmartAreas(at point: CGPoint) {
        guard smartAreasApply, !isDragging, let panel,
              !(adjustedSelection?.contains(point) ?? false),
              let window = ScreenshotSupport.window(at: point, in: windows) else {
            smartPendingPoint = nil
            clearSmartAreas()
            return
        }
        if smartQueryInFlight {
            smartPendingPoint = point
            return
        }
        smartQueryInFlight = true
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let offset = CGPoint(x: panel.screenFrame.minX, y: primaryHeight - panel.screenFrame.maxY)
        let global = CGPoint(x: point.x + offset.x, y: point.y + offset.y)
        let windowFrame = window.frame.offsetBy(dx: offset.x, dy: offset.y)
        let windowID = window.windowID
        ScreenshotSmartAreas.queue.async { [weak self] in
            let found = ScreenshotSmartAreas.areas(at: global, windowID: windowID, windowFrame: windowFrame)
            DispatchQueue.main.async {
                guard let self else { return }
                self.smartQueryInFlight = false
                // The pointer reached the toolbar while this was looked up.
                if let window = self.window,
                   self.pointerIsOverToolbar(self.convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
                    return
                }
                let areas = found.map { $0.offsetBy(dx: -offset.x, dy: -offset.y) }
                if let pending = self.smartPendingPoint {
                    self.smartPendingPoint = nil
                    self.requestSmartAreas(at: pending)
                    // A newer point is on its way; this answer still shows
                    // meanwhile if it covers where the pointer is now.
                    guard areas.first?.contains(pending) == true else { return }
                }
                self.applySmartAreas(areas, windowID: windowID)
            }
        }
    }

    private func applySmartAreas(_ areas: [CGRect], windowID: CGWindowID) {
        guard smartAreasApply, !isDragging else { return }
        let previous = hoveredArea
        let sameWindow = windowID == smartWindowID
        smartAreas = areas
        smartWindowID = windowID
        if sameWindow, smartLevelChosen, let previous,
           let kept = areas.firstIndex(where: { ScreenshotSmartAreas.isClose($0, previous) }) {
            smartLevel = kept
        } else {
            smartLevelChosen = false
            // Window mode starts on the whole window and scrolls inward.
            smartLevel = controller?.captureTarget == .window
                ? max(0, areas.count - 1)
                : ScreenshotSmartAreas.defaultLevel(areas)
        }
        refreshWindowPick()
        needsDisplay = true
    }

    /// The wheel steps out to the part around this one, or back in.
    private func stepSmartArea(by delta: CGFloat) -> Bool {
        guard smartAreasApply, !smartAreas.isEmpty, !isDragging else { return false }
        smartScrollAccumulator += delta
        guard abs(smartScrollAccumulator) >= 6 else { return true }
        let step = smartScrollAccumulator > 0 ? 1 : -1
        smartScrollAccumulator = 0
        let next = min(max(smartLevel + step, 0), smartAreas.count - 1)
        if next != smartLevel {
            smartLevel = next
            smartLevelChosen = true
            refreshWindowPick()
            needsDisplay = true
        }
        return true
    }

    private func adjustCursor(at point: CGPoint) -> NSCursor? {
        var reshaping = false
        if case .draw = dragAction {} else { reshaping = isDragging }
        guard adjustedSelection != nil || reshaping else { return nil }
        if case .move = dragAction, isDragging { return .closedHand }
        let active: AdjustHandle?
        if case .resize(let handle, _) = dragAction, isDragging { active = handle } else { active = handle(at: point) }
        switch active {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .some: return .crosshair
        case nil: return selection.contains(point) ? .openHand : nil
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    /// The panels never activate the app, and AppKit only reads cursor rects
    /// for the active app, so the pointer is set on every pointer event: the
    /// crosshair over the area to pick, the arrow over the clickable controls.
    private func refreshCursor(at point: CGPoint) {
        let overControl = pointerIsOverFullScreenControl(point)
            || (!guideHost.isHidden && !guideHost.passesThrough && guideHost.frame.contains(point))
            || (!confirmHost.isHidden && confirmHost.frame.contains(point))
        if overControl || pointerIsOverToolbar(point) { NSCursor.arrow.set(); return }
        if controller?.captureTarget == .screen {
            (controller?.confirmsByRecording == true
                ? CaptureModeCursor.record : CaptureModeCursor.camera).set()
            return
        }
        (adjustCursor(at: point) ?? NSCursor.crosshair).set()
    }

    override func layout() {
        super.layout()
        if let toolbarHost {
            if toolbarDragStart == nil {
                let size = toolbarHost.fittingSize
                toolbarHost.frame = ScreenshotSupport.captureToolbarFrame(
                    size: CGSize(width: max(size.width, 1), height: max(size.height, 1)),
                    bounds: bounds,
                    stored: UserDefaults.standard.string(forKey: DefaultsKey.captureToolbarPosition) ?? "")
            }
            layoutOptionsCard()
            // The toolbar has its own Capture Entire Screen mode.
            fullScreenHost.frame = .zero
            return
        }
        let width = min(screenCaptureOptions == nil ? 680 : 620,
                        max(280, bounds.width - 32))
        let height: CGFloat = screenCaptureOptions != nil
            ? (screenCaptureOptions?.showsCaptureMenu == false ? 82 : 146)
            : 72
        guideHost.frame = CGRect(x: bounds.midX - width / 2,
                                 y: bounds.maxY - height - 32,
                                 width: width,
                                 height: height)
        let availableWidth = max(1, bounds.width - 32)
        let fitting = fullScreenHost.fittingSize
        let fullScreenWidth = min(max(fitting.width, 1), availableWidth)
        let fullScreenHeight = max(fitting.height, 32)
        let topInset = ScreenshotSupport.fullScreenCaptureControlTopInset(
            screenChromeHeight: panel?.topChromeHeight ?? 0,
            notchControlsHeight: notchCaptureControlsHeight)
        fullScreenHost.frame = CGRect(x: bounds.midX - fullScreenWidth / 2,
                                      y: topInset,
                                      width: fullScreenWidth,
                                      height: fullScreenHeight)
    }

    /// An explicit location covers pointer warps, whose new position may not
    /// be visible through NSEvent.mouseLocation yet when this runs.
    func refreshPointerState(mouseLocation: CGPoint? = nil) {
        guard let panel else { return }
        let global = mouseLocation ?? controller?.currentPointerLocation ?? NSEvent.mouseLocation
        let point = CGPoint(x: global.x - panel.screenFrame.minX,
                            y: panel.screenFrame.maxY - global.y)
        pointerIsInside = bounds.contains(point)
        if pointerIsInside {
            updatePointerHover(point)
        } else {
            hoveredWindow = nil
        }
        refreshFullScreenControlVisibility()
        if pointerIsInside { refreshCursor(at: point) }
        needsDisplay = true
    }

    func updateLoupeImage(_ image: CGImage?) {
        loupeImage = image
        needsDisplay = true
    }

    func copyLoupeColorUnderPointer() {
        guard let loupeImage else { return }
        let point = isDragging ? lastDragPoint : hoverPoint
        let pixelPoint = ScreenshotSupport.imagePixelPoint(
            fromView: point,
            viewSize: bounds.size,
            imageSize: CGSize(width: loupeImage.width, height: loupeImage.height))
        let sample = loupePixelColor(in: loupeImage, at: pixelPoint)
        guard let color = sample.color,
              let value = ColorSamplerService.shared.copyQuietly(color)
        else { return }
        copiedValue = value
        copiedValueReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in
            self?.copiedValue = nil
            self?.needsDisplay = true
        }
        copiedValueReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: reset)
        needsDisplay = true
    }

    func refreshCaptureGuide() {
        guideHost.rootView = CaptureGuideView(
            strings: strings,
            purpose: purpose,
            offersScrollingCapture: controller?.offersScrollingCapture ?? false,
            offersRepeatLastRegion: controller?.offersRepeatLastRegion ?? false,
            requiresDraggedRegion: controller?.requiresDraggedRegion ?? false,
            scrollingCaptureEnabled: controller?.scrollingCaptureEnabled ?? false,
            loupeEnabled: controller?.loupeEnabled ?? false,
            screenCaptureOptions: screenCaptureOptions)
    }

    func captureToolDidChange() {
        dragOrigin = nil
        if keepsAdjustedSelection {
            refreshConfirmControl()
        } else {
            isAdjusting = false
            selection = .zero
            refreshConfirmControl()
        }
        hoveredWindow = nil
        refreshGuideVisibility()
        refreshCaptureGuide()
        refreshFullScreenControlVisibility()
        needsLayout = true
        needsDisplay = true
        refreshPointerState()
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        pointerHasMoved = true
        controller?.currentPointerLocation = nil
        let point = convert(event.locationInWindow, from: nil)
        if pointerIsOverToolbar(point) {
            // The toolbar is not part of the picture: nothing under it is
            // offered while the pointer is on it. Window mode keeps its last
            // pick, so the Capture button still takes the window shown before.
            smartPendingPoint = nil
            clearSmartAreas()
            if hoveredWindow != nil {
                hoveredWindow = nil
                needsDisplay = true
            }
            refreshCursor(at: point)
            return
        }
        updatePointerHover(point)
        requestSmartAreas(at: point)
        refreshWindowPick()
        refreshFullScreenControlVisibility()
        refreshCursor(at: point)
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        refreshPointerState()
        refreshGuideVisibility()
        refreshFullScreenControlVisibility()
    }

    // System chrome can take pointer ownership without the pointer leaving
    // this display. Re-evaluate the real location so the chooser does not
    // disappear over the Dock, menu bar or its own interactive controls.
    override func mouseExited(with event: NSEvent) {
        refreshPointerState()
        refreshGuideVisibility()
        refreshFullScreenControlVisibility()
        if let panel, !NSMouseInRect(NSEvent.mouseLocation, panel.screenFrame, false) { clearSmartAreas() }
    }

    override func scrollWheel(with event: NSEvent) {
        if acceptsPointerInput, controller?.loupeEnabled == false {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 6
            if stepSmartArea(by: delta) { return }
        }
        guard acceptsPointerInput, let controller, controller.loupeEnabled else {
            super.scrollWheel(with: event)
            return
        }
        let steppedByDefault = UserDefaults.standard.bool(
            forKey: DefaultsKey.screenshotLoupeSteppedZoomByDefault)
        let stepped = ScreenshotSupport.captureLoupeUsesSteppedZoom(
            steppedByDefault: steppedByDefault,
            optionPressed: event.modifierFlags.contains(.option))
        let wheelDelta: CGFloat
        if let cgEvent = event.cgEvent {
            wheelDelta = ScreenshotSupport.captureLoupeWheelDelta(
                scrollingDelta: event.scrollingDeltaY,
                lineDelta: cgEvent.getIntegerValueField(.scrollWheelEventDeltaAxis1),
                fixedPointDelta: cgEvent.getDoubleValueField(
                    .scrollWheelEventFixedPtDeltaAxis1))
        } else {
            wheelDelta = event.scrollingDeltaY
        }
        controller.adjustLoupeZoom(
            by: wheelDelta,
            stepped: stepped,
            isContinuous: event.hasPreciseScrollingDeltas)
    }

    override func mouseDown(with event: NSEvent) {
        guard acceptsPointerInput else { return }
        controller?.currentPointerLocation = nil
        let point = convert(event.locationInWindow, from: nil)
        pointerIsInside = true
        hoverPoint = point
        // A press anywhere on the screen closes the Options menu, as a click
        // outside any menu does.
        if screenCaptureOptions?.showsOptions == true { screenCaptureOptions?.showsOptions = false }
        if let controller, controller.captureTarget != .portion, !controller.isPickingColor {
            // Screen and window modes take a click; nothing is drawn.
            pendingTargetClick = point
            return
        }
        if let current = adjustedSelection, let controller, let panel, !controller.isPickingColor {
            if event.clickCount >= 2, current.contains(point) {
                controller.confirmRegion(current, on: panel)
                return
            }
            if let handle = handle(at: point) {
                dragAction = .resize(handle, current)
            } else if current.contains(point) {
                dragAction = .move(current)
            }
            if case .draw = dragAction {} else {
                dragOrigin = point
                lastDragPoint = point
                confirmHost.isHidden = true
                refreshCursor(at: point)
                needsDisplay = true
                return
            }
        }
        dragAction = .draw
        replacedSelection = adjustedSelection
        if let panel { controller?.endAdjusting(except: panel) }
        isAdjusting = false
        confirmHost.isHidden = true
        dragOrigin = point
        controller?.setSelectionInProgress(true)
        lastDragPoint = point
        selection = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard acceptsPointerInput, let controller, let origin = dragOrigin else { return }
        controller.currentPointerLocation = nil
        let point = convert(event.locationInWindow, from: nil)
        pointerIsInside = true
        hoverPoint = point
        if controller.isPickingColor {
            lastDragPoint = point
            needsDisplay = true
            return
        }
        switch dragAction {
        case .move(let start):
            selection = Self.moved(start, by: CGPoint(x: point.x - origin.x, y: point.y - origin.y), in: bounds)
            lastDragPoint = point
            needsDisplay = true
            return
        case .resize(let handle, let start):
            selection = Self.resized(start, by: handle, to: point, in: bounds)
            lastDragPoint = point
            needsDisplay = true
            return
        case .draw:
            break
        }
        if controller.spaceIsDown, selection.width > 0 {
            // Space pans the selection instead of resizing it.
            let delta = CGPoint(x: point.x - lastDragPoint.x, y: point.y - lastDragPoint.y)
            selection.origin.x += delta.x
            selection.origin.y += delta.y
            dragOrigin = CGPoint(x: origin.x + delta.x, y: origin.y + delta.y)
        } else {
            selection = ScreenshotSupport.selectionRect(
                from: origin,
                to: point,
                square: event.modifierFlags.contains(.shift),
                fromCenter: event.modifierFlags.contains(.option))
        }
        selection = ScreenshotSupport.clamp(selection, to: bounds)
        lastDragPoint = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard acceptsPointerInput, let controller, let panel else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let press = pendingTargetClick {
            pendingTargetClick = nil
            if ScreenshotSupport.isClick(from: press, to: point) {
                takeTargetClick(at: point, controller: controller, panel: panel)
            }
            return
        }
        guard let origin = dragOrigin else { return }
        dragOrigin = nil
        controller.spaceIsDown = false

        switch dragAction {
        case .move, .resize:
            // Moving or resizing keeps the area waiting for the button.
            dragAction = .draw
            controller.rememberArea(selection, on: panel)
            refreshConfirmControl()
            refreshCursor(at: point)
            needsDisplay = true
            return
        case .draw:
            break
        }
        let replaced = replacedSelection
        replacedSelection = nil
        let clickedSmartArea = hoveredArea

        if controller.isPickingColor {
            selection = .zero
            controller.confirmColor(at: point, on: panel)
            return
        }

        let clicked = ScreenshotSupport.isClick(from: origin, to: point)
        // A click's few pixels of travel are not a selection.
        if clicked { selection = .zero }
        // A drawn area replaces whatever part was highlighted before it.
        if !clicked { clearSmartAreas() }
        if clicked, let area = clickedSmartArea, area.contains(point) {
            // A click takes the highlighted part: as a window when it is the
            // whole window, otherwise as an area, kept for adjusting if asked.
            if let windowID = smartWindowID, area == smartAreas.last, controller.acceptsWindowClick,
               !controller.keepsDrawnArea {
                controller.confirmWindow(windowID, frame: area, on: panel)
            } else if controller.keepsDrawnArea {
                clearSmartAreas()
                beginAdjusting(area)
                controller.setSelectionInProgress(false)
                refreshCursor(at: point)
            } else {
                controller.confirmRegion(area, on: panel)
            }
            return
        }
        if clicked, let replaced {
            // A click beside an area being adjusted keeps that area.
            beginAdjusting(replaced)
            controller.setSelectionInProgress(false)
            return
        }
        if clicked, let ghostRect = clickableGhostRect(at: point) {
            // A click inside the outline of the last selection takes that
            // selection again, the same as pressing R.
            controller.confirmRegion(ghostRect, on: panel)
            return
        }
        if clicked {
            if controller.acceptsWindowClick,
               let target = ScreenshotSupport.window(at: point, in: windows) {
                controller.confirmWindow(target.windowID, frame: target.frame, on: panel)
            }
            selection = .zero
            needsDisplay = true
            controller.setSelectionInProgress(false)
            return
        }
        guard selection.width >= 2, selection.height >= 2 else {
            selection = .zero
            controller.setSelectionInProgress(false)
            needsDisplay = true
            return
        }
        if controller.keepsDrawnArea, !controller.isPickingColor {
            beginAdjusting(selection)
            controller.setSelectionInProgress(false)
            refreshCursor(at: point)
            return
        }
        controller.confirmRegion(selection, on: panel)
    }

    /// Screen mode takes the display that was clicked. Window mode takes the
    /// part the pointer shows: the whole window, or a smaller part of it the
    /// wheel stepped in to.
    private func takeTargetClick(at point: CGPoint,
                                 controller: ScreenshotSelectionController,
                                 panel: ScreenshotOverlayPanel) {
        switch controller.captureTarget {
        case .screen:
            controller.confirmScreen(on: panel)
        case .window:
            if let area = hoveredArea, area.contains(point) {
                if let windowID = smartWindowID, area == smartAreas.last {
                    controller.confirmWindow(windowID, frame: area, on: panel)
                } else {
                    controller.confirmRegion(area, on: panel)
                }
            } else if let target = ScreenshotSupport.window(at: point, in: windows) {
                controller.confirmWindow(target.windowID, frame: target.frame, on: panel)
            }
        case .portion:
            break
        }
    }

    func refreshGuideVisibility() {
        if let toolbarHost, let optionsHost, let panel {
            guideHost.isHidden = true
            let global = controller?.currentPointerLocation ?? NSEvent.mouseLocation
            let visible = ScreenshotSupport.captureGuideIsVisible(
                pointerOnDisplay: NSMouseInRect(global, panel.screenFrame, false)
                    || toolbarDragStart != nil,
                selectionInProgress: controller?.selectionInProgress ?? true,
                capturePending: isCapturePending)
            toolbarHost.isHidden = !visible
            optionsHost.isHidden = !visible || screenCaptureOptions?.showsOptions != true
                || screenCaptureOptions?.selectedTool.offersOptions != true
            return
        }
        guard screenCaptureOptions?.controlsInNotch != true, let panel else {
            guideHost.isHidden = true
            return
        }
        let global = controller?.currentPointerLocation ?? NSEvent.mouseLocation
        guideHost.isHidden = !ScreenshotSupport.captureGuideIsVisible(
            pointerOnDisplay: NSMouseInRect(global, panel.screenFrame, false),
            selectionInProgress: controller?.selectionInProgress ?? true,
            capturePending: isCapturePending)
    }

    func setNotchCaptureControlsHeight(_ height: CGFloat?) {
        // The island collapses on its own timer. Do not move the action out
        // from under a pointer that is already aiming at it; apply the latest
        // surface geometry as soon as the pointer leaves instead.
        if fullScreenControlHovered {
            deferredNotchCaptureControlsHeight = height
            hasDeferredNotchCaptureControlsHeight = true
            return
        }
        notchCaptureControlsHeight = height
        needsLayout = true
    }

    func refreshFullScreenControlVisibility() {
        guard let panel else {
            fullScreenHost.isHidden = true
            resetFullScreenControlHover()
            return
        }
        let global = controller?.currentPointerLocation ?? NSEvent.mouseLocation
        let hidden = !ScreenshotSupport.fullScreenCaptureControlIsVisible(
            isAvailable: controller?.offersFullScreenCapture ?? false,
            pointerOnDisplay: NSMouseInRect(global, panel.screenFrame, false),
            selectionInProgress: controller?.selectionInProgress ?? true,
            capturePending: isCapturePending)
        fullScreenHost.isHidden = hidden
        if hidden { resetFullScreenControlHover() }
    }

    private func pointerIsOverFullScreenControl(_ point: CGPoint) -> Bool {
        !fullScreenHost.isHidden && fullScreenHost.frame.contains(point)
    }

    private func updatePointerHover(_ point: CGPoint) {
        pointerIsInside = true
        hoverPoint = point
        hoveredWindow = highlightWindows && controller?.acceptsWindowClick == true
                && !pointerIsOverFullScreenControl(point)
                && clickableGhostRect(at: point) == nil && !isAdjusting
            ? ScreenshotSupport.window(at: point, in: windows)
            : nil
    }

    /// The last selection's outline when a click at `point` would take it
    /// again: shown, on this display, and with nothing being dragged.
    private func clickableGhostRect(at point: CGPoint) -> CGRect? {
        guard let ghostRect, selection == .zero, !isCapturePending,
              let controller, !controller.isPickingColor,
              ghostRect.width >= 1, ghostRect.height >= 1,
              ghostRect.contains(point) else { return nil }
        return ghostRect
    }

    private func fullScreenControlHoverChanged(_ hovered: Bool) {
        fullScreenControlHovered = hovered
        if !hovered { applyDeferredNotchCaptureControlsHeight() }
        // SwiftUI owns the pill's hover tracking, while AppKit owns the
        // window highlight. Re-evaluate the latter on the same transition.
        refreshPointerState()
    }

    private func resetFullScreenControlHover() {
        guard fullScreenControlHovered else { return }
        fullScreenControlHovered = false
        applyDeferredNotchCaptureControlsHeight()
    }

    private func applyDeferredNotchCaptureControlsHeight() {
        if hasDeferredNotchCaptureControlsHeight {
            notchCaptureControlsHeight = deferredNotchCaptureControlsHeight
            deferredNotchCaptureControlsHeight = nil
            hasDeferredNotchCaptureControlsHeight = false
            needsLayout = true
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let controller,
              let panel
        else { return }
        // Opening controls in the notch should not darken the whole desktop.
        // Keep selection feedback, without the initial full-screen dim/tint.
        let notchChooser = screenCaptureOptions?.controlsInNotch == true
        let dimAlpha = ScreenshotSupport.selectionDimAlpha(notchControls: notchChooser,
                                                          isFrozen: frozenImage != nil, isDragging: isDragging)
        context.setFillColor(CGColor(gray: 0, alpha: dimAlpha))
        if selection.width > 0, selection.height > 0 {
            context.beginPath()
            context.addRect(bounds)
            // Square corners, like the system's own area: the clear inside is
            // exactly the area that will be taken.
            context.addRect(selection)
            context.fillPath(using: .evenOdd)
            drawSelectionChrome(context, pixelScale: panel.pixelScale)
            if !isDragging, let area = hoveredArea {
                drawWindowHighlight(context, rect: area)
                drawAreaBadge(area, pixelScale: panel.pixelScale)
            }
        } else if controller.captureTarget == .screen, !controller.isPickingColor {
            // Screen mode leaves the picture clear and outlines the display
            // a click would take.
            if pointerIsInside { drawWindowHighlight(context, rect: bounds.insetBy(dx: 3, dy: 3)) }
        } else if dragOrigin == nil, let area = hoveredArea {
            context.beginPath()
            context.addRect(bounds)
            context.addRect(area)
            context.fillPath(using: .evenOdd)
            drawWindowHighlight(context, rect: area)
            drawAreaBadge(area, pixelScale: panel.pixelScale)
        } else if dragOrigin == nil, hoveredWindow != nil {
            if let hovered = hoveredWindow {
                context.beginPath()
                context.addRect(bounds)
                context.addRect(hovered.frame)
                context.fillPath(using: .evenOdd)
                if !notchChooser || pointerHasMoved { drawWindowHighlight(context, rect: hovered.frame) }
            } else {
                context.fill(bounds)
            }
        } else {
            context.fill(bounds)
        }

        if controller.loupeEnabled, !controller.spaceIsDown,
           pointerIsInside, let loupeImage {
            let point = isDragging ? lastDragPoint : hoverPoint
            drawCaptureLoupe(context,
                             image: loupeImage,
                             near: point,
                             zoom: controller.loupeZoom)
        }

        if let ghostRect, dragOrigin == nil, selection == .zero {
            drawGhost(context, rect: ghostRect)
        }
    }

    /// The system recorder's look: a thin white dashed outline with a dark
    /// hairline under it so it reads on light and dark pixels alike, and
    /// eight round white handles, one per corner and one per edge.
    private func drawSelectionChrome(_ context: CGContext, pixelScale: CGFloat) {
        let outline = selection.insetBy(dx: -0.75, dy: -0.75)
        context.saveGState()
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.45))
        context.setLineWidth(2.5)
        context.stroke(outline)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.98))
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: ScreenshotSupport.selectionOutlineDash)
        context.stroke(outline)
        context.restoreGState()

        if isAdjusting {
            for (_, rect) in handleRects() {
                let center = CGPoint(x: rect.midX, y: rect.midY)
                let radius = ScreenshotSupport.selectionHandleRadius
                let dot = CGRect(x: center.x - radius, y: center.y - radius,
                                 width: radius * 2, height: radius * 2)
                context.saveGState()
                context.setShadow(offset: .zero, blur: 2.5, color: CGColor(gray: 0, alpha: 0.55))
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fillEllipse(in: dot)
                context.restoreGState()
                context.setStrokeColor(CGColor(gray: 0, alpha: 0.28))
                context.setLineWidth(0.75)
                context.strokeEllipse(in: dot)
            }
        }

        let pixelWidth = Int((selection.width * pixelScale).rounded())
        let pixelHeight = Int((selection.height * pixelScale).rounded())
        drawBadge("\(pixelWidth) × \(pixelHeight)",
                  near: CGPoint(x: selection.midX, y: selection.maxY + 10))
    }

    /// The size of the part on offer, and where it sits among the parts the
    /// wheel steps through.
    private func drawAreaBadge(_ area: CGRect, pixelScale: CGFloat) {
        let pixelWidth = Int((area.width * pixelScale).rounded())
        let pixelHeight = Int((area.height * pixelScale).rounded())
        let level = smartAreas.count > 1
            ? "  ·  scroll ↕ \(min(smartLevel, smartAreas.count - 1) + 1)/\(smartAreas.count)"
            : ""
        drawBadge("\(pixelWidth) × \(pixelHeight)\(level)", near: CGPoint(x: area.midX, y: area.maxY + 10))
    }

    private func drawWindowHighlight(_ context: CGContext, rect: CGRect) {
        let path = CGPath(roundedRect: rect.insetBy(dx: 1.25, dy: 1.25),
                          cornerWidth: 9,
                          cornerHeight: 9,
                          transform: nil)
        context.addPath(path)
        context.setFillColor(CGColor(srgbRed: 0.35, green: 0.62, blue: 1, alpha: 0.14))
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(CGColor(srgbRed: 0.35, green: 0.62, blue: 1, alpha: 0.95))
        context.setLineWidth(2.5)
        context.strokePath()
    }

    private func drawGhost(_ context: CGContext, rect: CGRect) {
        context.saveGState()
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.65))
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [5, 4])
        context.stroke(rect)
        context.restoreGState()
    }

    // MARK: Pixel loupe

    private func drawCaptureLoupe(_ context: CGContext,
                                  image: CGImage,
                                  near point: CGPoint,
                                  zoom: CGFloat) {
        let imageSize = CGSize(width: image.width, height: image.height)
        let pixelPoint = ScreenshotSupport.imagePixelPoint(
            fromView: point,
            viewSize: bounds.size,
            imageSize: imageSize)
        let sampleSide = ScreenshotSupport.captureLoupeSampleSide(zoom: zoom)
        let source = ScreenshotSupport.cropLoupeSampleRect(
            around: pixelPoint,
            imageSize: imageSize,
            sideLength: sampleSide)
        guard let sample = image.cropping(to: source) else { return }

        let side = ScreenshotSupport.captureLoupeFrameSide
        let infoHeight: CGFloat = 24
        let infoGap: CGFloat = 6
        let block = captureLoupeFrame(
            near: point,
            size: CGSize(width: side, height: side + infoGap + infoHeight))
        let frame = CGRect(x: block.minX, y: block.minY, width: side, height: side)
        let path = CGPath(roundedRect: frame,
                          cornerWidth: 9,
                          cornerHeight: 9,
                          transform: nil)
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.interpolationQuality = .none
        // CGImage draws bottom-up inside the flipped overlay, so mirror only
        // this destination to keep the magnified pixels upright.
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        let flippedFrame = CGRect(x: frame.minX,
                                  y: bounds.height - frame.maxY,
                                  width: frame.width,
                                  height: frame.height)
        context.draw(sample, in: flippedFrame)
        context.restoreGState()

        // A ring around the target pixel rather than lines through it: the
        // ring sits just outside the pixel so the sample keeps its own color
        // (issue #755), and the pixel grid underneath makes each
        // magnified cell read as the single screen pixel it is.
        let target = ScreenshotSupport.captureLoupeTargetPixelRect(
            around: pixelPoint,
            source: source,
            frame: frame)
        let ring = target.insetBy(dx: -1, dy: -1)
        let reticle = CGMutablePath()
        reticle.addRect(ring)
        // Arms still carry the eye in from the frame edges, which is what the
        // selection tools aim with, and stop before they reach the pixel.
        let arms = [
            (CGPoint(x: ring.midX, y: frame.minY), CGPoint(x: ring.midX, y: ring.minY)),
            (CGPoint(x: ring.midX, y: ring.maxY), CGPoint(x: ring.midX, y: frame.maxY)),
            (CGPoint(x: frame.minX, y: ring.midY), CGPoint(x: ring.minX, y: ring.midY)),
            (CGPoint(x: ring.maxX, y: ring.midY), CGPoint(x: frame.maxX, y: ring.midY)),
        ]
        for (start, end) in arms where end.x > start.x || end.y > start.y {
            reticle.move(to: start)
            reticle.addLine(to: end)
        }

        context.saveGState()
        context.addPath(path)
        context.clip()
        if ScreenshotSupport.captureLoupeGridVisible(
            frameSide: side, sampleSide: max(source.width, source.height)) {
            drawLoupeGrid(context, frame: frame, source: source)
        }
        context.addPath(reticle)
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.76))
        context.setLineWidth(3)
        context.strokePath()
        context.addPath(reticle)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.92))
        context.setLineWidth(1)
        context.strokePath()
        context.restoreGState()

        context.saveGState()
        context.addPath(path)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        context.setLineWidth(1.5)
        context.strokePath()
        context.restoreGState()

        drawLoupeInfo(context,
                      in: CGRect(x: frame.minX,
                                 y: frame.maxY + infoGap,
                                 width: frame.width,
                                 height: infoHeight),
                      image: image,
                      pixelPoint: pixelPoint)
    }

    /// Pixel grid: a faint line between every pair of sampled
    /// pixels, so each cell reads as the single screen pixel it magnifies.
    private func drawLoupeGrid(_ context: CGContext, frame: CGRect, source: CGRect) {
        let columns = Int(source.width)
        let rows = Int(source.height)
        guard columns > 1, rows > 1 else { return }
        context.saveGState()
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.28))
        context.setLineWidth(1)
        for column in 1..<columns {
            let x = frame.minX + CGFloat(column) * frame.width / CGFloat(columns)
            context.move(to: CGPoint(x: x, y: frame.minY))
            context.addLine(to: CGPoint(x: x, y: frame.maxY))
        }
        for row in 1..<rows {
            let y = frame.minY + CGFloat(row) * frame.height / CGFloat(rows)
            context.move(to: CGPoint(x: frame.minX, y: y))
            context.addLine(to: CGPoint(x: frame.maxX, y: y))
        }
        context.strokePath()
        context.restoreGState()
    }

    private func loupePixelColor(in image: CGImage,
                                 at pixelPoint: CGPoint) -> (color: NSColor?, point: CGPoint) {
        let x = min(max(Int(pixelPoint.x.rounded(.down)), 0), image.width - 1)
        let y = min(max(Int(pixelPoint.y.rounded(.down)), 0), image.height - 1)
        let point = CGPoint(x: x, y: y)
        return (QuickToolsSupport.sampledColor(in: image, x: x, y: y), point)
    }

    /// Readout bar under the magnifier: a swatch of the pixel under the
    /// pointer, its value in the same format C would copy, and its position
    /// in display pixels.
    private func drawLoupeInfo(_ context: CGContext,
                               in rect: CGRect,
                               image: CGImage,
                               pixelPoint: CGPoint) {
        let sample = loupePixelColor(in: image, at: pixelPoint)
        let x = Int(sample.point.x)
        let y = Int(sample.point.y)
        var swatch: NSColor?
        var value = ""
        if let color = sample.color,
           let srgb = color.usingColorSpace(.sRGB) {
            swatch = srgb
            value = ColorSamplerService.shared.formattedValue(color) ?? ""
        }
        let text: String
        if let copiedValue {
            text = "✓ \(copiedValue)"
        } else {
            text = value.isEmpty ? "\(x), \(y)" : "\(value)   \(x), \(y)"
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let swatchSide: CGFloat = swatch == nil ? 0 : 12
        let swatchGap: CGFloat = swatch == nil ? 0 : 7
        let contentWidth = swatchSide + swatchGap + textSize.width
        let barWidth = min(max(contentWidth + 20, rect.width), bounds.width - 12)
        var bar = CGRect(x: rect.midX - barWidth / 2,
                         y: rect.minY,
                         width: barWidth,
                         height: rect.height)
        bar.origin.x = min(max(bar.origin.x, bounds.minX + 6),
                           bounds.maxX - bar.width - 6)
        let path = CGPath(roundedRect: bar, cornerWidth: 7, cornerHeight: 7,
                          transform: nil)
        context.saveGState()
        context.addPath(path)
        context.setFillColor(CGColor(gray: 0, alpha: 0.72))
        context.fillPath()
        context.restoreGState()

        var cursor = bar.minX + (bar.width - contentWidth) / 2
        if let swatch {
            let swatchRect = CGRect(x: cursor,
                                    y: bar.midY - swatchSide / 2,
                                    width: swatchSide,
                                    height: swatchSide)
            context.saveGState()
            context.setFillColor(swatch.cgColor)
            context.fill(swatchRect)
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.85))
            context.setLineWidth(1)
            context.stroke(swatchRect)
            context.restoreGState()
            cursor += swatchSide + swatchGap
        }
        text.draw(at: CGPoint(x: cursor, y: bar.midY - textSize.height / 2),
                  withAttributes: attributes)
    }

    private func captureLoupeFrame(near point: CGPoint, size: CGSize) -> CGRect {
        let gap: CGFloat = 16
        let inset: CGFloat = 8
        var origin = CGPoint(x: point.x + gap,
                             y: point.y - size.height - gap)
        if origin.x + size.width > bounds.maxX - inset {
            origin.x = point.x - size.width - gap
        }
        if origin.y < bounds.minY + inset {
            origin.y = point.y + gap
        }
        origin.x = min(max(origin.x, bounds.minX + inset),
                       bounds.maxX - size.width - inset)
        origin.y = min(max(origin.y, bounds.minY + inset),
                       bounds.maxY - size.height - inset)
        return CGRect(origin: origin, size: size)
    }

    // MARK: Text chrome

    private func drawBadge(_ text: String, near point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        var rect = CGRect(x: point.x - size.width / 2 - 7,
                          y: point.y - 3,
                          width: size.width + 14,
                          height: size.height + 6)
        rect.origin.x = max(6, min(rect.origin.x, bounds.maxX - rect.width - 6))
        rect.origin.y = max(6, min(rect.origin.y, bounds.maxY - rect.height - 6))
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSColor(white: 0, alpha: 0.72).setFill()
        path.fill()
        text.draw(at: CGPoint(x: rect.minX + 7, y: rect.minY + 3), withAttributes: attributes)
    }

}

private final class FullScreenControlHoverRelay {
    var changed: ((Bool) -> Void)?
    func update(_ hovered: Bool) { changed?(hovered) }
}

private final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    var passesThrough = true
    var acceptsFirstClick = false
    /// The guide gets its frame from the overlay's layout. Its changing
    /// ideal size must not resize the shielding window. Other hosts keep
    /// intrinsic sizing, including the full-screen button measured by layout.
    convenience init(fixedFrameRootView rootView: Content) {
        self.init(rootView: rootView)
        sizingOptions = []
        safeAreaRegions = []
        translatesAutoresizingMaskIntoConstraints = true
    }
    /// Capture actions remain clickable while the Dynamic Island panel owns
    /// key focus. Keep both parts of that policy on the interactive host.
    convenience init(interactiveRootView rootView: Content) {
        self.init(rootView: rootView)
        passesThrough = false
        acceptsFirstClick = true
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        acceptsFirstClick || super.acceptsFirstMouse(for: event)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        passesThrough ? nil : super.hitTest(point)
    }
}

/// Takes the adjusted area: Capture for a picture, Record for the recorder.
private struct SelectionConfirmButton: View {
    let recording: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(recording ? "Record" : "Capture", systemImage: recording ? "record.circle" : "camera.fill")
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(minHeight: 34)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(Capsule(style: .continuous)
            .fill(recording ? Color.red : Color.accentColor)
            .brightness(isHovered ? 0.06 : 0))
        .scaleEffect(isHovered ? 1.03 : 1)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .help("Return")
    }
}

private struct FullScreenCaptureButton: View {
    let action: () -> Void
    let hoverChanged: (Bool) -> Void
    @ObservedObject private var l10n = L10n.shared
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(FeatureStrings.screenshot(l10n.language).fullScreenCaptureButton,
                  systemImage: "rectangle.inset.filled")
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 14)
                .frame(minHeight: 32)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background(CaptureChromeBackdrop(
            material: .regularMaterial,
            shape: Capsule(style: .continuous)))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(isHovered ? 0.34 : 0.12),
                              lineWidth: isHovered ? 1.5 : 1)
        }
        .scaleEffect(isHovered ? 1.02 : 1)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover {
            isHovered = $0
            hoverChanged($0)
        }
        .shadow(color: .black.opacity(0.20), radius: 12, y: 5)
        .help(FeatureStrings.screenshot(l10n.language).fullScreenShortcutTitle)
        .accessibilityLabel(FeatureStrings.screenshot(l10n.language).fullScreenCaptureButton)
    }
}

/// The backing plate the capture chrome draws behind its text.
///
/// The shared `HUDBackdrop` cannot serve here: its material blends with what
/// sits behind the window, and this chrome lives inside the overlay window,
/// which is opaque while it shows the frozen still. Blending there would read
/// the live desktop instead of the still the person is aiming at. The plate is
/// the part that fixes contrast anyway, so keep the material these panels
/// already draw and add only the plate over it.
struct CaptureChromeBackdrop<S: Shape>: View {
    let material: Material
    let shape: S

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Reduced transparency already gives an opaque material, so the plate
    /// steps aside; otherwise it carries the same calibration the shared
    /// backdrop documents.
    private var plateOpacity: Double {
        guard !reduceTransparency else { return 0 }
        return HUDBackdrop.plateOpacity(dark: colorScheme == .dark)
    }

    var body: some View {
        shape.fill(material)
            .overlay(shape.fill(colorScheme == .dark ? Color.black : Color.white)
                        .opacity(plateOpacity))
    }
}

private struct CaptureGuideView: View {
    let strings: ScreenshotFeatureStrings
    let purpose: String?
    let offersScrollingCapture: Bool
    let offersRepeatLastRegion: Bool
    let requiresDraggedRegion: Bool
    let scrollingCaptureEnabled: Bool
    let loupeEnabled: Bool
    let screenCaptureOptions: ScreenCaptureSelectionOptions?

    var body: some View {
        if let screenCaptureOptions {
            UnifiedCaptureGuideContent(strings: strings,
                                       options: screenCaptureOptions,
                                       offersScrollingCapture: offersScrollingCapture,
                                       offersRepeatLastRegion: offersRepeatLastRegion,
                                       scrollingCaptureEnabled: scrollingCaptureEnabled,
                                       loupeEnabled: loupeEnabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(true)
        } else {
            standardGuide
        }
    }

    private var standardGuide: some View {
        HStack(spacing: 12) {
            Image(systemName: "viewfinder")
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 7) {
                if !requiresDraggedRegion && !scrollingCaptureEnabled {
                    CaptureKeyHint(key: "↩", icon: "rectangle.inset.filled")
                }
                if offersScrollingCapture {
                    CaptureKeyHint(key: scrollingCaptureEnabled ? "S on" : "S",
                                   icon: "rectangle.stack")
                }
                CaptureKeyHint(key: loupeEnabled ? "Z on" : "Z",
                               icon: "plus.magnifyingglass")
                if loupeEnabled {
                    CaptureKeyHint(key: "C", icon: "doc.on.doc")
                }
                if offersRepeatLastRegion {
                    CaptureKeyHint(key: "R", icon: "rectangle.dashed")
                }
                CaptureKeyHint(key: "esc", icon: "xmark")
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CaptureChromeBackdrop(
            material: .regularMaterial,
            shape: RoundedRectangle(cornerRadius: 16, style: .continuous)))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 18, y: 7)
        .allowsHitTesting(false)
    }

    private var title: String {
        guard let purpose, !purpose.isEmpty else { return strings.hintDrag }
        return purpose
    }

    private var subtitle: String {
        let base = requiresDraggedRegion || scrollingCaptureEnabled
            ? strings.scrollingCaptureSelectionHint
            : purpose?.isEmpty == false
            ? strings.hintDrag + "  ·  " + strings.hintClick
            : strings.hintClick
        guard offersScrollingCapture else { return base }
        let scrolling = scrollingCaptureEnabled
            ? strings.scrollingCaptureHintOn
            : strings.scrollingCaptureHintOff
        return base + "  ·  " + scrolling
    }

}

private struct UnifiedCaptureGuideContent: View {
    let strings: ScreenshotFeatureStrings
    @ObservedObject var options: ScreenCaptureSelectionOptions
    @ObservedObject private var l10n = L10n.shared
    let offersScrollingCapture: Bool
    let offersRepeatLastRegion: Bool
    let scrollingCaptureEnabled: Bool
    let loupeEnabled: Bool
    @State private var hoveredTool: ScreenCaptureTool?

    var body: some View {
        VStack(spacing: 8) {
            if options.showsCaptureMenu {
                HStack(spacing: 8) {
                    captureModePalette
                    escapeHint
                }
            }
            HStack(spacing: 8) {
                contextualGuide
                if !options.showsCaptureMenu {
                    escapeHint
                }
            }
            RecorderSelectionAudioControls(options: options.recorderAudio)
                .opacity(options.selectedTool == .recording ? 1 : 0)
                .allowsHitTesting(options.selectedTool == .recording)
                .accessibilityHidden(options.selectedTool != .recording)
        }
    }

    private var contextualGuide: some View {
        HStack(spacing: 7) {
            Text(subtitle)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            CaptureKeyHint(key: "1–4", icon: "keyboard")
            if options.selectedTool != .color {
                CaptureKeyHint(key: "↩", icon: "rectangle.inset.filled")
                if offersScrollingCapture, options.selectedTool == .screenshot {
                    CaptureKeyHint(key: scrollingCaptureEnabled ? "S on" : "S",
                                   icon: "rectangle.stack")
                }
                CaptureKeyHint(key: loupeEnabled ? "Z on" : "Z",
                               icon: "plus.magnifyingglass")
                if loupeEnabled {
                    CaptureKeyHint(key: "C", icon: "doc.on.doc")
                }
                if offersRepeatLastRegion {
                    CaptureKeyHint(key: "R", icon: "rectangle.dashed")
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(CaptureChromeBackdrop(material: .ultraThinMaterial,
                                          shape: Capsule(style: .continuous)))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }

    private var escapeHint: some View {
        HStack(spacing: 5) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
            Text("esc")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: options.showsCaptureMenu ? 56 : 30)
        .background(CaptureChromeBackdrop(
            material: .regularMaterial,
            shape: RoundedRectangle(cornerRadius: 14, style: .continuous)))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
    }

    private var captureModePalette: some View {
        HStack(spacing: 2) {
            ForEach(options.availableTools, id: \.self) { tool in
                captureModeButton(tool)
            }
        }
        .padding(4)
        .background(CaptureChromeBackdrop(
            material: .regularMaterial,
            shape: RoundedRectangle(cornerRadius: 14, style: .continuous)))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
    }

    private func captureModeButton(_ tool: ScreenCaptureTool) -> some View {
        let selected = options.selectedTool == tool
        let hovered = hoveredTool == tool
        let title = tool.settingsTitle(l10n.s, language: l10n.language)
        return Button {
            // Animating this publishes the new tool through the hosting view
            // that fills the display. That view then asks the window to adopt
            // the bar's size, and the window server scales the request.
            options.select(tool)
        } label: {
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    Text(tool.shortcutKey)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .frame(width: 19, height: 19)
                        .background(selected ? Color.accentColor : Color.primary.opacity(0.11),
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Image(systemName: tool.systemImageName)
                        .font(.system(size: 13, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                }
                Text(title)
                    .font(.system(size: 10, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.78))
            .frame(width: 116, height: 48)
            .background(selected ? Color.accentColor.opacity(0.16)
                        : Color.primary.opacity(hovered ? 0.08 : 0.035),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(selected ? 0.48 : 0), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredTool = hovering ? tool : nil
            }
        }
        .help("\(title) (\(tool.shortcutKey))")
        .accessibilityLabel(title)
        .accessibilityValue(tool.shortcutKey)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var subtitle: String {
        switch options.selectedTool {
        case .screenshot:
            let base = strings.hintDrag + "  ·  " + strings.hintClick
            guard offersScrollingCapture else { return base }
            return base + "  ·  "
                + (scrollingCaptureEnabled
                   ? strings.scrollingCaptureHintOn
                   : strings.scrollingCaptureHintOff)
        case .recording:
            return FeatureStrings.recorder(l10n.language).selectionPurpose
                + "  ·  " + strings.hintDrag + "  ·  " + strings.hintClick
        case .text:
            return l10n.s.ocrCaption
        case .color:
            return l10n.s.colorPickerCaption
        }
    }
}

private struct CaptureKeyHint: View {
    let key: String
    let icon: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct RecorderSelectionAudioControls: View {
    @ObservedObject var options: RecorderSelectionAudioOptions
    @ObservedObject private var l10n = L10n.shared

    private var strings: RecorderFeatureStrings { FeatureStrings.recorder(l10n.language) }

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $options.systemAudio) {
                Label(strings.systemAudioTrackLabel, systemImage: "speaker.wave.2.fill")
            }
            Toggle(isOn: $options.microphone) {
                Label(strings.microphoneTrackLabel, systemImage: "mic.fill")
            }
        }
        .toggleStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(4)
        .background(CaptureChromeBackdrop(material: .regularMaterial,
                                          shape: Capsule(style: .continuous)))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }
}
