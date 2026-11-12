// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

/// The top-center strip of every display, at the notch. Pushing the pointer
/// into it opens the notch island (`notchTopEdgeOpens`); clicking in it opens
/// the capture toolbar (`captureTopEdgeClick`). Pushing fires once per entry
/// and never while a button is held, so an area dragged up to the edge does
/// not cancel itself.
final class CaptureHotspot {
    static let shared = CaptureHotspot()

    /// Virtual displays an agent works on: a hit there first moves the
    /// pointer to the main display, so what opens shows where Swen is.
    private static let pointerHandoffDisplayNames: Set<String> = ["S-Space"]

    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var regions: [(id: UInt32, rect: CGRect)] = []
    private var activeDisplayID: UInt32?
    private var opensIsland = false
    private var clickCaptures = false
    /// A press that began in the strip; its release there is the click.
    private var pressedInStrip = false

    private init() {}

    /// Reads both switches; the notch and capture services each call this
    /// when their preferences change.
    func syncWithPreferences() {
        let defaults = UserDefaults.standard
        opensIsland = NotchSupport.isEnabled() && defaults.bool(forKey: DefaultsKey.notchTopEdgeOpens)
        clickCaptures = !ScreenCaptureTool.available().isEmpty
            && defaults.bool(forKey: DefaultsKey.captureTopEdgeClick)
        opensIsland || clickCaptures ? start() : stop()
        syncClickMonitors()
    }

    /// Polled rather than fed by mouse events: event monitors missed hits
    /// while the capture panels held the mouse and arrived seconds late for
    /// some moves. A position read every 30 ms is a few microseconds of work.
    private func start() {
        guard timer == nil else { return }
        rebuildRegions()
        activeDisplayID = ScreenshotSupport.captureHotspotDisplay(containing: NSEvent.mouseLocation, in: regions)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuildRegions() }
        let poll = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in self?.pointerMoved() }
        poll.tolerance = 0.01
        RunLoop.main.add(poll, forMode: .common)
        timer = poll
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        activeDisplayID = nil
    }

    /// A click is an event, not a position, so it is heard rather than
    /// polled: globally for other apps' windows and the menu bar, locally
    /// for the island, where the click is taken so the island does not also
    /// act on it.
    private func syncClickMonitors() {
        if clickCaptures {
            if globalClickMonitor == nil {
                globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                    let down = event.type == .leftMouseDown
                    DispatchQueue.main.async { _ = self?.mouse(down: down) }
                }
            }
            if localClickMonitor == nil {
                localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                    self?.mouse(down: event.type == .leftMouseDown) == true ? nil : event
                }
            }
        } else {
            if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
            if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
            globalClickMonitor = nil
            localClickMonitor = nil
            pressedInStrip = false
        }
    }

    private func rebuildRegions() {
        let displays = NSScreen.screens.enumerated().map { index, screen -> ScreenshotSupport.HotspotDisplay in
            var left: CGFloat?, right: CGFloat?
            if screen.safeAreaInsets.top > 0,
               let leftArea = screen.auxiliaryTopLeftArea, let rightArea = screen.auxiliaryTopRightArea {
                left = leftArea.width
                right = rightArea.width
            }
            return .init(id: Self.displayID(of: screen) ?? UInt32.max - UInt32(index),
                         frame: screen.frame, auxLeftWidth: left, auxRightWidth: right)
        }
        regions = ScreenshotSupport.captureHotspotRegions(for: displays)
    }

    private func pointerMoved() {
        let hit = ScreenshotSupport.captureHotspotDisplay(containing: NSEvent.mouseLocation, in: regions)
        defer { activeDisplayID = hit }
        guard opensIsland, let hit, hit != activeDisplayID, NSEvent.pressedMouseButtons == 0 else { return }
        handOffPointer(from: hit)
        NotchService.shared.openFromTopEdge()
    }

    /// True when the press or release belongs to a click in the strip,
    /// which opens the capture toolbar on release. A click while capture is
    /// already on screen belongs to it, as an area started at the top edge.
    private func mouse(down: Bool) -> Bool {
        let hit = ScreenshotSupport.captureHotspotDisplay(containing: NSEvent.mouseLocation, in: regions)
        if down {
            pressedInStrip = clickCaptures && hit != nil && !ScreenshotSelectionController.isSessionOnScreen
            return pressedInStrip
        }
        guard pressedInStrip else { return false }
        pressedInStrip = false
        guard let hit, !ScreenshotSelectionController.isSessionOnScreen else { return true }
        handOffPointer(from: hit)
        DispatchQueue.main.async {
            ScreenCaptureService.shared.capture(initial: .screenshot, fromShortcut: true)
        }
        return true
    }

    private func handOffPointer(from display: UInt32) {
        guard let screen = NSScreen.screens.first(where: { Self.displayID(of: $0) == display }),
              Self.pointerHandoffDisplayNames.contains(screen.localizedName) else { return }
        let main = CGDisplayBounds(CGMainDisplayID())
        if main.width > 0 { CGWarpMouseCursorPosition(CGPoint(x: main.midX, y: main.midY)) }
    }

    private static func displayID(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
