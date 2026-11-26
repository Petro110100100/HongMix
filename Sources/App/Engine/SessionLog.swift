import Foundation

// Session log: what happened during a recording, against the render frame counter.
//
// A session opens when the first recorder (Record output or MultiCorder ISO) starts and closes when the
// last one stops, in any order. While it is open:
//   • WriteDurationToRecordingLog (vMix function, Value = tag text) appends a line to <name>.log next to
//     the recording, in vMix's recording-log format:
//         11/26/2026 6:00:00 PM, StartRecording
//         11/26/2026 6:03:24 PM, 00:03:24.0400000, tag text
//   • With "Cut list" on (MultiCorder settings, off by default) every program change, transition, overlay,
//     fade to black, marker, recorder file and render stall is appended to <name>.session.journal as it
//     happens (one JSON object per line — survives a crash), and <name>.session.json is written when the
//     session closes: format, inputs, recorder files with their first frames, events and the shot list,
//     plus <name>.fcpxml (Final Cut Pro, Resolve) and <name>.edl (CMX3600, up to 30 fps) of the live cut.
//
// Positions are render ticks: renderTick pushes every recorder with the same tick, and the C recorder
// stamps each frame as tick − (tick of its first frame), so a tick maps to a time in every file
// (mc_output_current_file_start_tick). In <name>.session.json frames count from the session start.
//
// Threads: the render thread only compares its state snapshot with the previous frame (SwitcherEngine)
// and hands a change to `ingest`; the main thread opens/closes the session and adds markers; all file
// work runs on `queue`.
//
// The model and the writers only need Foundation: compile this file with `-D SESSIONLOG_STANDALONE`
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
    var firstTick: Int64 = -1   // tick of that file's first frame (-1 = no frame yet)
}

/// Input number and name, for the session file.
struct SessionInputInfo: Codable, Equatable {
    var id: String
    var number: Int
    var name: String
}

/// One journal line / one event of the session file. Unused fields stay out of the JSON.
///   type        fields
///   program     input, from, cause (cut | transition | tbar | stinger | start), transition, start (transition start)
///   transition  input (incoming), from, transition (fade, merge …); `end` set when it ends
///   overlay     channel (1…8), input, on
///   fadeToBlack on
///   marker      text, wall
///   file        path, role (program | iso), recorder, input — frame = the file's first frame
///   fileEnd     recorder
///   stall       lostMs (render clock reset after a stall or Mac sleep)
///   input       input, number, text (= name)
///   session     header: text (= app version), width, height, fpsNum, fpsDen, wall (start, s since 1970)
///   stop        —
struct SessionRecord: Codable, Equatable {
    var type: String
    var frame: Int64 = 0
    var input: String? = nil
    var from: String? = nil
    var cause: String? = nil
    var transition: String? = nil
    var start: Int64? = nil
    var end: Int64? = nil
    var channel: Int? = nil
    var number: Int? = nil
    var on: Bool? = nil
    var text: String? = nil
    var path: String? = nil
    var role: String? = nil
    var recorder: String? = nil
    var lostMs: Int? = nil
    var wall: Double? = nil
    var width: Int? = nil
    var height: Int? = nil
    var fpsNum: Int? = nil
    var fpsDen: Int? = nil
}

/// <name>.session.json
struct SessionDocument: Codable, Equatable {
    struct Format: Codable, Equatable {
        var width: Int
        var height: Int
        var fpsNum: Int
        var fpsDen: Int
        var frameRate: String        // "30000/1001"
    }
    struct File: Codable, Equatable {
        var path: String
        var role: String             // program | iso
        var recorder: String
        var input: String?
        var firstFrame: Int64        // session frame of the file's first frame
        var endFrame: Int64          // session frame after its last frame
    }
    struct Shot: Codable, Equatable {
        var start: Int64             // session frames, end exclusive
        var end: Int64
        var input: String?
        var number: Int?
        var name: String?
        var file: String?            // nil = no recording of this input at that time
        var fileFrame: Int64?        // frame in `file` at `start`
        var source: String?          // iso | program
    }
    var hongmixSessionLog = 1
    var app: String
    var started: String              // ISO 8601
    var format: Format
    var startTick: Int64             // render tick of session frame 0
    var durationFrames: Int64
    var inputs: [SessionInputInfo]
    var files: [File]
    var events: [SessionRecord]
    var shots: [Shot]
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

// MARK: - Cut list (journal records → session file)

enum SessionCutList {
    /// Builds the session file from the journal records (absolute ticks). Works on a crashed session's
    /// journal too: a missing `stop` ends the session at the last record.
    static func document(_ records: [SessionRecord]) -> SessionDocument? {
        guard let h = records.first(where: { $0.type == "session" }),
              let w = h.width, let ht = h.height, let num = h.fpsNum, let den = h.fpsDen, num > 0, den > 0 else { return nil }
        let files0 = records.filter { $0.type == "file" }
        // frame 0 = the session start, or an earlier first frame of a file (a recorder seen late)
        let origin = min(h.frame, files0.map(\.frame).min() ?? h.frame)
        let stopTick = records.first(where: { $0.type == "stop" })?.frame ?? (records.map(\.frame).max() ?? origin)
        let end = max(stopTick, origin) - origin

        // inputs: latest number/name per id, in number order
        var inputMap: [String: SessionInputInfo] = [:]
        for r in records where r.type == "input" {
            if let id = r.input { inputMap[id] = SessionInputInfo(id: id, number: r.number ?? 0, name: r.text ?? "") }
        }
        let inputs = inputMap.values.sorted { ($0.number, $0.name) < ($1.number, $1.name) }

        // files: each recorder's files in order; a file ends where the next one of the same recorder starts,
        // at that recorder's fileEnd, or at the session end
        var files: [SessionDocument.File] = []
        let byRecorder = Dictionary(grouping: files0, by: { $0.recorder ?? $0.path ?? "" })
        for (rec, list) in byRecorder {
            let sorted = list.sorted { $0.frame < $1.frame }
            let recEnd = records.last(where: { $0.type == "fileEnd" && $0.recorder == rec })?.frame ?? stopTick
            for (i, f) in sorted.enumerated() {
                let e = i + 1 < sorted.count ? sorted[i + 1].frame : max(recEnd, f.frame)
                files.append(SessionDocument.File(path: f.path ?? "", role: f.role ?? "iso", recorder: rec, input: f.input,
                                                  firstFrame: f.frame - origin, endFrame: e - origin))
            }
        }
        files.sort { ($0.firstFrame, $0.role, $0.path) < ($1.firstFrame, $1.role, $1.path) }

        // events: session-relative frames, header/inputs/files left to their own sections
        let skip: Set<String> = ["session", "input", "file", "fileEnd", "stop"]
        var events: [SessionRecord] = []
        for var r in records where !skip.contains(r.type) {
            r.frame = max(0, r.frame - origin)
            if let s = r.start { r.start = max(0, s - origin) }
            if let e = r.end { r.end = max(0, e - origin) }
            events.append(r)
        }
        events.sort { $0.frame < $1.frame }   // stable: same-frame events keep their order

        let shots = shotList(events: events, files: files, inputs: inputMap, end: end)
        let started = Date(timeIntervalSince1970: h.wall ?? 0)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone.current
        return SessionDocument(app: h.text ?? "HongMix", started: iso.string(from: started),
                               format: .init(width: w, height: ht, fpsNum: num, fpsDen: den, frameRate: "\(num)/\(den)"),
                               startTick: origin, durationFrames: end, inputs: inputs, files: files, events: events, shots: shots)
    }

    /// Program input over time → shots. A transition (auto or T-bar) is cut at its midpoint; a stinger at
    /// its cut point (where the program actually changed). Each shot points at the input's ISO file, or
    /// at the program recording where the input has none, split where a file changes.
    static func shotList(events: [SessionRecord], files: [SessionDocument.File],
                         inputs: [String: SessionInputInfo], end: Int64) -> [SessionDocument.Shot] {
        var cuts: [(frame: Int64, input: String?)] = []
        for e in events where e.type == "program" {
            var f = e.frame
            if (e.cause == "transition" || e.cause == "tbar"), let s = e.start, s < f { f = s + (f - s) / 2 }
            if let last = cuts.last, last.input == e.input { continue }
            if let last = cuts.last, f <= last.frame { cuts[cuts.count - 1] = (last.frame, e.input); continue }
            cuts.append((f, e.input))
        }
        guard !cuts.isEmpty, end > 0 else { return [] }
        cuts[0].frame = 0   // the first program state covers the session from its start
        var shots: [SessionDocument.Shot] = []
        for (i, c) in cuts.enumerated() {
            let s = c.frame, e = i + 1 < cuts.count ? min(cuts[i + 1].frame, end) : end
            guard e > s else { continue }
            // file boundaries inside the shot
            var bounds: Set<Int64> = [s, e]
            for f in files where f.firstFrame > s && f.firstFrame < e { bounds.insert(f.firstFrame) }
            for f in files where f.endFrame > s && f.endFrame < e { bounds.insert(f.endFrame) }
            let b = bounds.sorted()
            for j in 0..<(b.count - 1) {
                let ps = b[j], pe = b[j + 1]
                let info = c.input.flatMap { inputs[$0] }
                var shot = SessionDocument.Shot(start: ps, end: pe, input: c.input, number: info?.number, name: info?.name)
                if let f = file(for: c.input, at: ps, files) {
                    shot.file = f.path
                    shot.fileFrame = ps - f.firstFrame
                    shot.source = f.role
                }
                if let last = shots.last, last.input == shot.input, last.file == shot.file, last.end == shot.start,
                   shot.file == nil || (last.fileFrame ?? 0) + (last.end - last.start) == shot.fileFrame {
                    shots[shots.count - 1].end = shot.end
                } else {
                    shots.append(shot)
                }
            }
        }
        return shots
    }

    /// The file holding `input` at session frame `f`: its ISO file, else the program recording.
    static func file(for input: String?, at f: Int64, _ files: [SessionDocument.File]) -> SessionDocument.File? {
        func covering(_ c: [SessionDocument.File]) -> SessionDocument.File? {
            c.filter { $0.firstFrame <= f && f < $0.endFrame }.max { $0.firstFrame < $1.firstFrame }
        }
        if let id = input, let iso = covering(files.filter { $0.role == "iso" && $0.input == id }) { return iso }
        // the program file of the first Record output (others are copies)
        let programs = files.filter { $0.role == "program" }
        guard let firstRec = programs.min(by: { $0.firstFrame < $1.firstFrame })?.recorder else { return nil }
        return covering(programs.filter { $0.recorder == firstRec })
    }

    static func json(_ doc: SessionDocument) -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? e.encode(doc)
    }

    /// Journal file → records (unreadable lines, e.g. the last one cut by a crash, are skipped).
    static func records(journal: Data) -> [SessionRecord] {
        let d = JSONDecoder()
        return journal.split(separator: UInt8(ascii: "\n")).compactMap { try? d.decode(SessionRecord.self, from: Data($0)) }
    }
}

// MARK: - Editor files (session file → FCPXML / EDL)

enum SessionEditorFiles {
    /// FCPXML 1.10 (Final Cut Pro, DaVinci Resolve): one timeline, a clip per shot from the ISO files (the
    /// program file where an input has no ISO file), a gap where neither exists, markers on the clips.
    /// Times are exact multiples of the frame duration at every rate (1001/30000s …).
    static func fcpxml(_ doc: SessionDocument, name: String) -> String {
        let num = Int64(doc.format.fpsNum), den = Int64(doc.format.fpsDen)
        func t(_ frames: Int64) -> String {
            if frames == 0 { return "0s" }
            let n = frames * den, g = gcd(n, num)
            return num / g == 1 ? "\(n / g)s" : "\(n / g)/\(num / g)s"
        }
        var used: [String] = []
        for sh in doc.shots { if let f = sh.file, !used.contains(f) { used.append(f) } }
        var assetID: [String: String] = [:]
        var x = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE fcpxml>\n<fcpxml version=\"1.10\">\n  <resources>\n"
        x += "    <format id=\"r1\" frameDuration=\"\(t(1))\" width=\"\(doc.format.width)\" height=\"\(doc.format.height)\"/>\n"
        for (i, path) in used.enumerated() {
            let id = "r\(i + 2)"
            assetID[path] = id
            let f = doc.files.first { $0.path == path }
            let dur = max(1, (f?.endFrame ?? doc.durationFrames) - (f?.firstFrame ?? 0))
            let title = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            x += "    <asset id=\"\(id)\" name=\"\(esc(title))\" start=\"0s\" duration=\"\(t(dur))\" hasVideo=\"1\" hasAudio=\"1\""
            x += " format=\"r1\" audioSources=\"1\" audioChannels=\"2\" audioRate=\"48000\">\n"
            x += "      <media-rep kind=\"original-media\" src=\"\(esc(URL(fileURLWithPath: path).absoluteString))\"/>\n    </asset>\n"
        }
        x += "  </resources>\n  <library>\n    <event name=\"\(esc(name))\">\n      <project name=\"\(esc(name))\">\n"
        x += "        <sequence format=\"r1\" duration=\"\(t(doc.durationFrames))\" tcStart=\"0s\" tcFormat=\"NDF\" audioLayout=\"stereo\" audioRate=\"48k\">\n"
        x += "          <spine>\n"
        let markers = doc.events.filter { $0.type == "marker" }
        var pos: Int64 = 0
        for sh in doc.shots {
            if sh.start > pos {   // no program state before the first shot (should not happen) → gap
                x += "            <gap name=\"Gap\" offset=\"\(t(pos))\" start=\"0s\" duration=\"\(t(sh.start - pos))\"/>\n"
            }
            let len = sh.end - sh.start
            let local = sh.file != nil ? (sh.fileFrame ?? 0) : 0
            let ms = markers.filter { $0.frame >= sh.start && $0.frame < sh.end }
                .map { "              <marker start=\"\(t(local + $0.frame - sh.start))\" duration=\"\(t(1))\" value=\"\(esc(($0.text ?? "").isEmpty ? "Marker" : $0.text!))\"/>\n" }
                .joined()
            if let f = sh.file, let id = assetID[f] {
                x += "            <asset-clip ref=\"\(id)\" offset=\"\(t(sh.start))\" start=\"\(t(local))\" duration=\"\(t(len))\""
                x += " name=\"\(esc(sh.name ?? "Input \(sh.number ?? 0)"))\" format=\"r1\" tcFormat=\"NDF\""
                x += ms.isEmpty ? "/>\n" : ">\n" + ms + "            </asset-clip>\n"
            } else {
                x += "            <gap name=\"\(esc(sh.name ?? "Gap"))\" offset=\"\(t(sh.start))\" start=\"0s\" duration=\"\(t(len))\""
                x += ms.isEmpty ? "/>\n" : ">\n" + ms + "            </gap>\n"
            }
            pos = sh.end
        }
        x += "          </spine>\n        </sequence>\n      </project>\n    </event>\n  </library>\n</fcpxml>\n"
        return x
    }

    /// CMX3600 EDL (Premiere and others): one event per shot that has a file, reel = input name (8 chars),
    /// clip name and path as comments, markers as LOC lines. Non-drop-frame frame counts (29.97 counts
    /// 30 per second). nil above 30 fps: CMX3600 timecode has no standard form there.
    static func edl(_ doc: SessionDocument, name: String) -> String? {
        let fps = Double(doc.format.fpsNum) / Double(doc.format.fpsDen)
        guard fps <= 30.5 else { return nil }
        let base = Int64(fps.rounded())
        func tc(_ frames: Int64) -> String {
            let f = max(0, frames)
            return String(format: "%02lld:%02lld:%02lld:%02lld", f / (base * 3600), (f / (base * 60)) % 60, (f / base) % 60, f % base)
        }
        let recStart = base * 3600   // record timecode starts at 01:00:00:00
        var out = "TITLE: \(name)\nFCM: NON-DROP FRAME\n\n"
        var n = 0
        let markers = doc.events.filter { $0.type == "marker" }
        for sh in doc.shots {
            guard let file = sh.file, let ff = sh.fileFrame else { continue }
            n += 1
            let len = sh.end - sh.start
            out += String(format: "%03d  %@ %@ C        %@ %@ %@ %@\n", n, pad(reel(sh.name), 8), pad("AA/V", 5),
                          tc(ff), tc(ff + len), tc(recStart + sh.start), tc(recStart + sh.end))
            out += "* FROM CLIP NAME: \((file as NSString).lastPathComponent)\n"
            out += "* SOURCE FILE: \(file)\n"
            for m in markers where m.frame >= sh.start && m.frame < sh.end {
                let text = (m.text ?? "").replacingOccurrences(of: "\n", with: " ")
                out += "* LOC: \(tc(recStart + m.frame)) BLUE    \(text.isEmpty ? "Marker" : text)\n"
            }
            out += "\n"
        }
        return out
    }

    /// EDL reel: letters, digits and _ only, upper case, at most 8 characters ("AX" when nothing is left).
    static func reel(_ name: String?) -> String {
        let ok = (name ?? "").uppercased().unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "_"
        }
        var collapsed = ""
        for c in ok where !(c == "_" && collapsed.last == "_") { collapsed.append(c) }
        let r = String(collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "_")).prefix(8))
        return r.isEmpty ? "AX" : r
    }

    private static func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

    private static func gcd(_ a: Int64, _ b: Int64) -> Int64 { b == 0 ? max(1, abs(a)) : gcd(b, a % b) }

    static func esc(_ s: String) -> String {
        var o = ""
        for c in s {
            switch c {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            case "'": o += "&apos;"
            case "\n", "\r", "\t": o += " "
            default: o.append(c)
            }
        }
        return o
    }
}

// MARK: - Session log

final class SessionLog {
    /// Called on the main thread with a user-facing message (write errors).
    var onMessage: ((String) -> Void)?
    /// Called on the main thread with the written session file paths (tests, UI).
    var onWritten: (([String]) -> Void)?

    private let queue = DispatchQueue(label: "HongMix.SessionLog", qos: .utility)

    // main thread
    private(set) var isOpen = false
    private var seenFiles: [String: (path: String, firstTick: Int64)] = [:]
    private var seenInputs: [SessionInputInfo] = []

    // queue
    private var session: OpenSession?
    /// Latest program / overlay / fade state while no session is open — the next session starts from it.
    private var latest: [String: SessionRecord] = [:]

    private final class OpenSession {
        let folder: String
        let base: String
        let started: Date
        let originTick: Int64
        let format: SessionFormat
        let cutList: Bool
        var logStarted = false
        var records: [SessionRecord] = []
        var journal: FileHandle?

        init(folder: String, base: String, started: Date, originTick: Int64, format: SessionFormat, cutList: Bool) {
            self.folder = folder
            self.base = base
            self.started = started
            self.originTick = originTick
            self.format = format
            self.cutList = cutList
        }
        func path(_ ext: String) -> String { (folder as NSString).appendingPathComponent("\(base).\(ext)") }
    }

    /// Main thread: tell the log which recorders run now. Opens the session with the first recorder and
    /// closes it after the last one. `tick` = the next frame the render loop will produce.
    func sync(recorders: [SessionRecorder], tick: Int64, format: SessionFormat, inputs: [SessionInputInfo] = [],
              cutList: Bool = false, app: String = "HongMix", now: Date = Date()) {
        if !isOpen, let first = recorders.first(where: { $0.role == .program }) ?? recorders.first {
            isOpen = true
            seenFiles = [:]
            seenInputs = []
            let folder = (first.path as NSString).deletingLastPathComponent
            let s = OpenSession(folder: folder, base: SessionText.baseName(now), started: now,
                                originTick: tick, format: format, cutList: cutList)
            let header = SessionRecord(type: "session", frame: tick, text: app, wall: now.timeIntervalSince1970,
                                       width: format.width, height: format.height, fpsNum: format.fpsNum, fpsDen: format.fpsDen)
            queue.async { self.begin(s, header: header) }
        } else if isOpen && recorders.isEmpty {
            close(tick: tick, now: now)
            return
        }
        guard isOpen else { return }
        if inputs != seenInputs {
            for i in inputs where !seenInputs.contains(i) {
                ingest(SessionRecord(type: "input", frame: tick, input: i.id, number: i.number, text: i.name))
            }
            seenInputs = inputs
        }
        for r in recorders where r.firstTick >= 0 {
            if let s = seenFiles[r.key], s.path == r.path, s.firstTick == r.firstTick { continue }
            seenFiles[r.key] = (r.path, r.firstTick)
            ingest(SessionRecord(type: "file", frame: r.firstTick, input: r.input?.uuidString, path: r.path,
                                 role: r.role.rawValue, recorder: r.key))
        }
        let running = Set(recorders.map(\.key))
        for key in seenFiles.keys where !running.contains(key) {
            seenFiles[key] = nil
            ingest(SessionRecord(type: "fileEnd", frame: tick, recorder: key))
        }
    }

    /// Main thread: closes the session (recording stopped, app quitting). `wait` blocks until written.
    func close(tick: Int64, now: Date = Date(), wait: Bool = false) {
        guard isOpen else { return }
        isOpen = false
        seenFiles = [:]
        if wait { queue.sync { finish(tick: tick, now: now) } } else { queue.async { self.finish(tick: tick, now: now) } }
    }

    /// Any thread (the render thread for program/overlay/fade/stall changes): adds an event. Not open → it
    /// only updates the state the next session starts from.
    func ingest(_ r: SessionRecord) {
        queue.async { self.add(r) }
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
            add(SessionRecord(type: "marker", frame: tick, text: text, wall: now.timeIntervalSince1970))
        }
        return seconds
    }

    /// Main thread: waits for queued file work (tests, quit).
    func flush() { queue.sync {} }

    // MARK: queue

    private func begin(_ s: OpenSession, header: SessionRecord) {
        session = s
        guard s.cutList else { return }
        let path = s.path("session.journal")
        if FileManager.default.createFile(atPath: path, contents: nil) {
            s.journal = FileHandle(forWritingAtPath: path)
        } else {
            report(path)
        }
        add(header)
        // the program, overlays and fade to black as they are at the session start
        for key in latest.keys.sorted() {
            guard var r = latest[key] else { continue }
            if r.type == "overlay" && r.on != true { continue }
            if r.type == "fadeToBlack" && r.on != true { continue }
            r.frame = max(r.frame, s.originTick)
            if r.type == "program" { r.cause = "start"; r.from = nil; r.start = nil }
            add(r)
        }
    }

    private static let stateTypes: Set<String> = ["program", "overlay", "fadeToBlack"]

    private func add(_ r0: SessionRecord) {
        if SessionLog.stateTypes.contains(r0.type) {
            latest[r0.type == "overlay" ? "overlay\(r0.channel ?? 0)" : r0.type] = r0
        }
        guard let s = session, s.cutList else { return }
        var r = r0
        if r.frame < s.originTick && r.type != "file" { r.frame = s.originTick }   // handed over just before the start
        s.records.append(r)
        if let h = s.journal, var line = try? JSONEncoder().encode(r) {
            line.append(UInt8(ascii: "\n"))
            do { try h.write(contentsOf: line) } catch { s.journal = nil; report(s.path("session.journal")) }
        }
    }

    private func finish(tick: Int64, now: Date) {
        guard let s = session else { return }
        if s.logStarted { append(SessionText.vmixStopLine(date: now), to: s.path("log")) }
        var written: [String] = []
        if s.cutList {
            add(SessionRecord(type: "stop", frame: tick))
            try? s.journal?.close()
            s.journal = nil
            if let doc = SessionCutList.document(s.records) {
                written += write(SessionCutList.json(doc), s.path("session.json"))
                written += write(Data(SessionEditorFiles.fcpxml(doc, name: s.base).utf8), s.path("fcpxml"))
                if let edl = SessionEditorFiles.edl(doc, name: s.base) { written += write(Data(edl.utf8), s.path("edl")) }
            }
            // the journal is only needed when the session file could not be written
            if !written.isEmpty { try? FileManager.default.removeItem(atPath: s.path("session.journal")) }
        }
        session = nil
        if !written.isEmpty { DispatchQueue.main.async { self.onWritten?(written) } }
    }

    private func write(_ data: Data?, _ path: String) -> [String] {
        guard let data else { return [] }
        do { try data.write(to: URL(fileURLWithPath: path), options: .atomic); return [path] } catch { report(path); return [] }
    }

    /// Appends one line (CRLF, like vMix on Windows) and closes the file again, so a crash or a pulled
    /// disk never loses more than the line being written.
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
        for o in outputs where o.running && o.config.kind == .record {
            guard let f = o.recordingFile() else { continue }
            out.append(SessionRecorder(key: o.id.uuidString, role: .program, input: nil, path: f.0, firstTick: f.1))
        }
        for (id, path, first) in isoRecorderFiles() {
            out.append(SessionRecorder(key: id.uuidString, role: .iso, input: id, path: path, firstTick: first))
        }
        return out
    }

    var sessionFormat: SessionFormat {
        SessionFormat(width: format.width, height: format.height, fpsNum: format.fpsNum, fpsDen: format.fpsDen)
    }

    /// Opens / closes the session log to match the running recorders (switch events + once a second).
    func syncSessionLog() {
        let ins = inputs.enumerated().map { SessionInputInfo(id: $1.id.uuidString, number: $0 + 1, name: $1.name) }
        sessionLog.sync(recorders: sessionRecorders(), tick: nextRenderTick(), format: sessionFormat, inputs: ins,
                        cutList: sessionCutList, app: "HongMix " + AppInfo.version)
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
