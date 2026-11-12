// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

/// Pushing the pointer into the top-center strip of any display opens the
/// notch island, and doing it again closes it. Fires once per entry and
/// never while a button is held, so an area dragged up to the edge does not
/// cancel itself. 
final class CaptureHotspot {
    static let shared = CaptureHotspot()

    /// Virtual displays an agent works on: a hit there first moves the
    /// pointer to the main display, so the island opens where Swen is.
    private static let pointerHandoffDisplayNames: Set<String> = ["S-Space"]

    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var regions: [(id: UInt32, rect: CGRect)] = []
    private var activeDisplayID: UInt32?

    private init() {}

    func sync(enabled: Bool) {
        enabled ? start() : stop()
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
        guard let hit, hit != activeDisplayID, NSEvent.pressedMouseButtons == 0 else { return }
        if let screen = NSScreen.screens.first(where: { Self.displayID(of: $0) == hit }),
           Self.pointerHandoffDisplayNames.contains(screen.localizedName) {
            let main = CGDisplayBounds(CGMainDisplayID())
            if main.width > 0 { CGWarpMouseCursorPosition(CGPoint(x: main.midX, y: main.midY)) }
        }
        // Hover has already opened the island by the time the pointer reaches
        // the edge, so there the edge only opens and never closes it again.
        let notch = NotchService.shared
        if notch.expanded, UserDefaults.standard.bool(forKey: DefaultsKey.notchOpenOnHover) { return }
        notch.toggleFromShortcut()
    }

    private static func displayID(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
