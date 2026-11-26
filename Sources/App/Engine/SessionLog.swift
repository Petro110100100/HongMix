import Foundation

// Session log: what happened during a recording, against the render frame counter.
//
// A session opens when the first recorder (Record output or MultiCorder ISO) starts and closes when the
// last one stops, in any order. While it is open:
//   • WriteDurationToRecordingLog (vMix function, Value = tag text) appends a line to <name>.log next to
//     the recording, in vMix's recording-log format:
//         11/26/2026 6:00:00 PM, StartRecording
//         11/26/2026 6:03:24 PM, 00:03:24.0400000, tag text
//
// Positions are render ticks: renderTick pushes every recorder with the same tick, and the C recorder
// stamps each frame as tick − (tick of its first frame), so a tick maps to a frame in every file.
//
// Threads: the main thread opens/closes the session and adds markers; all file work runs on `queue`.
//
// The model and the text writers only need Foundation: compile this file with `-D SESSIONLOG_STANDALONE`
// to test them outside the app — see tests/sessionlog/.

// MARK: - Model

/// Exact frame rate (fpsNum / fpsDen frames per second, e.g. 30000/1001) and picture size.
struct SessionFormat: Codable, Equatable {
    var width: Int
    var height: Int
    var fpsNum: Int
    var fpsDen: Int

    var fps: Double { Double(fpsNum) / Double(fpsDen) }
    /// Seconds from frame 0 to `frames` — exact rational rate, never rounded to whole frames per second.
    func seconds(_ frames: Int64) -> Double { Double(frames) * Double(fpsDen) / Double(fpsNum) }
}

/// One running recorder as the main thread sees it.
struct SessionRecorder: Equatable {
    enum Role: String { case program, iso }
    var key: String          // output id (program) or input id (ISO) — stable while it records
    var role: Role
    var input: UUID?         // ISO: the recorded input
    var path: String         // file being written now
}

// MARK: - Text formats

enum SessionText {
    /// vMix recording-log time stamp: "11/26/2026 6:03:24 PM" (US format, as vMix writes it everywhere).
    static func vmixDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "M/d/yyyy h:mm:ss a"
        return f.string(from: d)
    }

    /// vMix recording-log duration (.NET TimeSpan): "00:03:24.0400000". Negative values clamp to 0.
    static func vmixDuration(_ seconds: Double) -> String {
        let ticks = Int64((max(0, seconds) * 10_000_000).rounded())   // 100 ns units, like TimeSpan
        let h = ticks / 36_000_000_000
        let m = (ticks / 600_000_000) % 60
        let s = (ticks / 10_000_000) % 60
        let f = ticks % 10_000_000
        return String(format: "%02lld:%02lld:%02lld.%07lld", h, m, s, f)
    }

    /// One marker line. Line breaks in the tag would break the one-line-per-entry format.
    static func vmixLine(date: Date, seconds: Double, tag: String) -> String {
        let clean = tag.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        return clean.isEmpty
            ? "\(vmixDate(date)), \(vmixDuration(seconds))"
            : "\(vmixDate(date)), \(vmixDuration(seconds)), \(clean)"
    }

    static func vmixStartLine(date: Date) -> String { "\(vmixDate(date)), StartRecording" }
    static func vmixStopLine(date: Date) -> String { "\(vmixDate(date)), StopRecording" }

    /// "HongMix_20261126_180000"
    static func baseName(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return "HongMix_" + f.string(from: d)
    }
}

// MARK: - Session log

final class SessionLog {
    /// Called on the main thread with a user-facing message (write errors).
    var onMessage: ((String) -> Void)?

    private let queue = DispatchQueue(label: "HongMix.SessionLog", qos: .utility)

    // main thread
    private(set) var isOpen = false
    private var openRecorders: [String: SessionRecorder] = [:]

    // queue
    private var session: OpenSession?

    private final class OpenSession {
        let folder: String
        let base: String
        let started: Date
        let originTick: Int64
        let format: SessionFormat
        var logStarted = false

        init(folder: String, base: String, started: Date, originTick: Int64, format: SessionFormat) {
            self.folder = folder
            self.base = base
            self.started = started
            self.originTick = originTick
            self.format = format
        }
        func path(_ ext: String) -> String { (folder as NSString).appendingPathComponent("\(base).\(ext)") }
    }

    /// Main thread: tell the log which recorders run now. Opens the session with the first recorder and
    /// closes it after the last one. `tick` = the next frame the render loop will produce.
    func sync(recorders: [SessionRecorder], tick: Int64, format: SessionFormat, now: Date = Date()) {
        if !isOpen, let first = recorders.first(where: { $0.role == .program }) ?? recorders.first {
            isOpen = true
            let folder = (first.path as NSString).deletingLastPathComponent
            let s = OpenSession(folder: folder, base: SessionText.baseName(now), started: now,
                                originTick: tick, format: format)
            queue.async { self.session = s }
        } else if isOpen && recorders.isEmpty {
            close(tick: tick, now: now)
        }
        openRecorders = Dictionary(recorders.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Main thread: closes the session (recording stopped, app quitting). `wait` blocks until written.
    func close(tick: Int64, now: Date = Date(), wait: Bool = false) {
        guard isOpen else { return }
        isOpen = false
        openRecorders = [:]
        if wait { queue.sync { finish(now: now) } } else { queue.async { self.finish(now: now) } }
    }

    /// queue: ends the open session.
    private func finish(now: Date) {
        guard let s = session else { return }
        session = nil
        if s.logStarted { append(SessionText.vmixStopLine(date: now), to: s.path("log")) }
    }

    /// Main thread: WriteDurationToRecordingLog. Returns the recording duration written, nil = no session.
    @discardableResult
    func marker(_ text: String, tick: Int64, now: Date = Date()) -> Double? {
        guard isOpen else { return nil }
        var seconds = 0.0
        queue.sync {
            guard let s = session else { return }
            seconds = s.format.seconds(tick - s.originTick)
            let log = s.path("log")
            if !s.logStarted {
                s.logStarted = true
                append(SessionText.vmixStartLine(date: s.started), to: log)
            }
            append(SessionText.vmixLine(date: now, seconds: seconds, tag: text), to: log)
        }
        return seconds
    }

    /// Main thread: waits for queued file work (tests, quit).
    func flush() { queue.sync {} }

    /// queue: appends one line (CRLF, like vMix on Windows) and closes the file again, so a crash or a
    /// pulled disk never loses more than the line being written.
    private func append(_ line: String, to path: String) {
        let data = Data((line + "\r\n").utf8)
        if !FileManager.default.fileExists(atPath: path) {
            if !FileManager.default.createFile(atPath: path, contents: data) { report(path) }
            return
        }
        guard let h = FileHandle(forWritingAtPath: path) else { report(path); return }
        defer { try? h.close() }
        do {
            try h.seekToEnd()
            try h.write(contentsOf: data)
        } catch { report(path) }
    }

    private func report(_ path: String) {
        #if SESSIONLOG_STANDALONE
        let text = "Session log: cannot write \(path)"
        #else
        let text = Lf("녹화 로그를 쓸 수 없음: %@", path)
        #endif
        DispatchQueue.main.async { self.onMessage?(text) }
    }
}

#if !SESSIONLOG_STANDALONE

// MARK: - App glue

extension SwitcherEngine {
    /// Recorders running now: Record outputs and MultiCorder ISO files (main thread).
    func sessionRecorders() -> [SessionRecorder] {
        var out: [SessionRecorder] = []
        for o in outputs where o.running && o.config.kind == .record && !o.lastFile.isEmpty {
            out.append(SessionRecorder(key: o.id.uuidString, role: .program, input: nil, path: o.lastFile))
        }
        for (id, path) in isoRecorderFiles() {
            out.append(SessionRecorder(key: id.uuidString, role: .iso, input: id, path: path))
        }
        return out
    }

    var sessionFormat: SessionFormat {
        SessionFormat(width: format.width, height: format.height, fpsNum: format.fpsNum, fpsDen: format.fpsDen)
    }

    /// Opens / closes the session log to match the running recorders (switch events + once a second).
    func syncSessionLog() {
        sessionLog.sync(recorders: sessionRecorders(), tick: nextRenderTick(), format: sessionFormat)
    }

    /// vMix WriteDurationToRecordingLog: one line with the recording duration and the tag text.
    /// Returns an error text for the API, nil on success.
    func writeRecordingLog(_ text: String) -> String? {
        syncSessionLog()   // a recording started a moment ago counts even before the next switch event
        guard let seconds = sessionLog.marker(text, tick: nextRenderTick()) else {
            lastMessage = L("녹화 로그: 녹화 중이 아닙니다")
            return "No recording running"
        }
        let shown = String(SessionText.vmixDuration(seconds).prefix(11)) + (text.isEmpty ? "" : " " + text)
        lastMessage = Lf("녹화 로그에 기록: %@", shown)
        return nil
    }
}

#endif
