// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Foundation

/// Picks the areas worth offering from the accessibility elements under the
/// pointer: the window's own panes (split views, sidebars, toolbars, tab
/// views, the page area of a browser), never the buttons, rows, text and
/// page sections inside them. Inside a web page only its landmarks
/// (navigation, main, sidebar) count; ordinary divs never do.
enum ScreenshotSmartAreaSupport {
    struct Element: Equatable {
        let role: String?
        let subrole: String?
        let frame: CGRect?
    }

    static let webAreaRole = "AXWebArea"
    static let scrollAreaRole = "AXScrollArea"

    /// Containers that divide a native window into panes.
    static let paneRoles: Set<String> = [
        scrollAreaRole, webAreaRole, "AXSplitGroup", "AXGroup", "AXToolbar", "AXTabGroup",
        "AXBrowser", "AXLayoutArea", "AXSheet", "AXDrawer", "AXPopover",
    ]

    /// A pane smaller than this is a control, not a part of the window.
    static let minimumPaneSize = CGSize(width: 80, height: 32)

    /// `chain` runs from the element under the pointer up to, not including,
    /// the window. Smallest first, ending with the window itself.
    static func areas(chain: [Element], point: CGPoint, windowFrame: CGRect) -> [CGRect] {
        // Everything below the outermost web area is page content.
        let page = chain.lastIndex { $0.role == webAreaRole }
        var clip = windowFrame
        var frames: [CGRect] = []
        for (index, element) in chain.enumerated().reversed() {
            guard let frame = element.frame else { continue }
            let visible = frame.intersection(clip)
            guard !visible.isNull, !visible.isEmpty else { continue }
            // Scrolled content reaches past its view; only the visible part counts.
            if element.role == scrollAreaRole || element.role == webAreaRole { clip = visible }
            let offered: Bool
            if let page, index < page {
                offered = element.subrole?.hasPrefix("AXLandmark") == true
            } else {
                offered = element.role.map(paneRoles.contains) ?? false
            }
            if offered, visible.width >= minimumPaneSize.width, visible.height >= minimumPaneSize.height,
               visible.contains(point) {
                frames.append(visible)
            }
        }
        frames.append(windowFrame)
        return distinct(frames)
    }

    /// Nested elements often share a frame; one step should always change it.
    static func distinct(_ frames: [CGRect]) -> [CGRect] {
        var result: [CGRect] = []
        for frame in frames.sorted(by: { $0.width * $0.height < $1.width * $1.height }) {
            if result.contains(where: { isClose($0, frame) }) { continue }
            result.append(frame)
        }
        return result
    }

    static func isClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 3) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.maxX - b.maxX) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
    }
}
