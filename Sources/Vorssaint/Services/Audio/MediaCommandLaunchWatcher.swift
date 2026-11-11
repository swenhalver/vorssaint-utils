// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Foundation

/// Reports when the system opens an app for a media command. Headphones,
/// AirPods and Control Center send Play through mediaremoted without any
/// key event this process could observe; only the system log records that
/// mediaremoted asked for the launch. Reading the log stream needs an admin
/// account; without one the stream ends at once and nothing is reported.
final class MediaCommandLaunchWatcher {
    typealias Handler = (_ bundleID: String, _ plays: Bool) -> Void

    private var process: Process?
    private var handler: Handler?
    private var buffer = Data()
    private var restartWork: DispatchWorkItem?
    private var quickExits = 0
    private var startedAt: TimeInterval = 0
    private var terminationObserver: NSObjectProtocol?

    /// The stream ends on its own after this long and is started again, so
    /// a stream orphaned by a crash cannot outlive the app for long.
    private static let streamTimeout = "10m"

    var isRunning: Bool { process != nil }

    func start(_ handler: @escaping Handler) {
        self.handler = handler
        if terminationObserver == nil {
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.stop() }
        }
        guard process == nil, restartWork == nil else { return }
        quickExits = 0
        launch()
    }

    func stop() {
        handler = nil
        restartWork?.cancel()
        restartWork = nil
        buffer.removeAll()
        guard let running = process else { return }
        process = nil
        (running.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if running.isRunning { running.terminate() }
    }

    private func launch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        task.arguments = ["stream", "--style", "compact", "--timeout", Self.streamTimeout,
                          "--predicate", MusicLaunchSupport.commandLaunchLogPredicate]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { self?.receive(data, from: task) }
        }
        task.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async { self?.streamEnded(ended) }
        }
        do {
            try task.run()
            process = task
            startedAt = ProcessInfo.processInfo.systemUptime
        } catch {
            process = nil
        }
    }

    private func receive(_ data: Data, from task: Process) {
        guard task === process, !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            if let request = MusicLaunchSupport.commandLaunch(in: line) {
                handler?(request.bundleID, request.plays)
            }
        }
        // A runaway line without a newline must not grow without bound.
        if buffer.count > 64 * 1024 { buffer.removeAll() }
    }

    /// The timeout ends the stream on schedule; start it again at once. A
    /// stream that keeps ending right away (no admin rights) is given up.
    private func streamEnded(_ ended: Process) {
        guard ended === process else { return }
        process = nil
        buffer.removeAll()
        guard handler != nil else { return }
        let ranFor = ProcessInfo.processInfo.systemUptime - startedAt
        quickExits = ranFor < 5 ? quickExits + 1 : 0
        guard quickExits < 3 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWork = nil
            guard self.handler != nil, self.process == nil else { return }
            self.launch()
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (quickExits == 0 ? 0.2 : 5), execute: work)
    }
}
