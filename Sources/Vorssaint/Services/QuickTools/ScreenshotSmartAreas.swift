// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices

/// The parts of a window under the pointer that a capture can take on its
/// own: a pane, a sidebar, a toolbar, the page area of a browser. They come from
/// the app's accessibility tree, asked through the app's own element so the
/// overlay covering the screen does not answer instead.
enum ScreenshotSmartAreas {
    /// Lookups wait on other apps, so they never run on the main thread.
    static let queue = DispatchQueue(label: "vorssaint.screenshot.smart-areas", qos: .userInteractive)

    /// Smallest first, ending with the window itself. Frames are in global
    /// top-left coordinates, the ones Accessibility and the window server use.
    static func areas(at point: CGPoint, windowID: CGWindowID, windowFrame: CGRect) -> [CGRect] {
        guard AXIsProcessTrusted(), let pid = ownerPID(of: windowID), pid != getpid() else {
            return [windowFrame]
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return [windowFrame] }

        var chain: [ScreenshotSmartAreaSupport.Element] = []
        var current: AXUIElement? = hit
        while let element = current, chain.count < 40 {
            let role = string(element, kAXRoleAttribute)
            if role == kAXWindowRole as String || role == kAXApplicationRole as String { break }
            chain.append(.init(role: role, subrole: string(element, kAXSubroleAttribute), frame: frame(of: element)))
            current = parent(of: element)
        }
        return ScreenshotSmartAreaSupport.areas(chain: chain, point: point, windowFrame: windowFrame)
    }

    static func isClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 3) -> Bool {
        ScreenshotSmartAreaSupport.isClose(a, b, tolerance: tolerance)
    }

    /// The level the pointer starts on: the smallest part big enough to be
    /// worth a picture on its own, not a lone icon or a line of text.
    static func defaultLevel(_ areas: [CGRect]) -> Int {
        areas.firstIndex { $0.width >= 40 && $0.height >= 24 } ?? max(0, areas.count - 1)
    }

    private static func ownerPID(of windowID: CGWindowID) -> pid_t? {
        guard let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let pid = info.first?[kCGWindowOwnerPID as String] as? pid_t else { return nil }
        return pid
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: AnyObject?
        var size: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent),
              extent.width > 0, extent.height > 0 else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}
