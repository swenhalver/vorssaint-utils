// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import os

/// Timestamps for how long the capture surface takes to come up, readable
/// with `log stream --predicate 'subsystem == "com.vorssaint.utils.capture-timing"'`.
enum CaptureTiming {
    private static let log = Logger(subsystem: "com.vorssaint.utils.capture-timing", category: "open")
    private static var started: UInt64 = 0

    static func start(_ stage: String) {
        started = DispatchTime.now().uptimeNanoseconds
        log.log("\(stage, privacy: .public) +0 ms")
    }

    static func mark(_ stage: String) {
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        // A mark long after the last start begins a new measurement.
        guard started > 0, ms < 3000 else { return start(stage) }
        log.log("\(stage, privacy: .public) +\(ms, format: .fixed(precision: 1), privacy: .public) ms")
    }
}
