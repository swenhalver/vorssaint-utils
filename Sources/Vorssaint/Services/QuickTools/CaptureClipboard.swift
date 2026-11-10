// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

/// Puts a saved capture on the clipboard as a file, the way Finder's Copy
/// does, so pasting into Mail, Messages, Slack or a Finder window brings the
/// file itself.
enum CaptureClipboard {
    @discardableResult
    static func copyFile(_ url: URL) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([url as NSURL]) else { return false }
        pasteboard.declareVorssaintSource()
        return true
    }

    /// The same, only when the person keeps copying on (the default).
    @discardableResult
    static func copyIfWanted(_ url: URL) -> Bool {
        guard ScreenshotSupport.capturesCopyToClipboard() else { return false }
        return copyFile(url)
    }
}
