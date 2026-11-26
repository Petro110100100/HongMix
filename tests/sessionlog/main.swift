// Standalone test of the session log (Sources/App/Engine/SessionLog.swift, compiled with
// -D SESSIONLOG_STANDALONE so the app glue is left out). Run: bash tests/sessionlog/run.sh
//
// Covers: vMix recording-log text (date, TimeSpan duration, tag clean-up), session open/close with the
// recorders, markers refused without a recording, frame-exact durations at 25, 29.97 and 59.94.
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

var failures = 0
var checks = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    checks += 1
    if ok { print("  ok   \(what)") } else { failures += 1; print("  FAIL \(what)  (line \(line))") }
}

let work = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory() + "hongmix-sessionlog"
try? FileManager.default.removeItem(atPath: work)
try! FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)

func date(_ s: String) -> Date {   // "2026-11-26 18:00:00" local time
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.date(from: s)!
}
let fmt2997 = SessionFormat(width: 1920, height: 1080, fpsNum: 30000, fpsDen: 1001)
let fmt25 = SessionFormat(width: 1920, height: 1080, fpsNum: 25, fpsDen: 1)
let fmt5994 = SessionFormat(width: 1920, height: 1080, fpsNum: 60000, fpsDen: 1001)

print("== vMix text")
check(SessionText.vmixDate(date("2026-11-26 18:03:24")) == "11/26/2026 6:03:24 PM", "date like vMix")
check(SessionText.vmixDate(date("2026-01-05 00:00:09")) == "1/5/2026 12:00:09 AM", "midnight, no leading zeros")
check(SessionText.vmixDuration(16.7) == "00:00:16.7000000", "TimeSpan 16.7 s")
check(SessionText.vmixDuration(3 * 3600 + 25 * 60 + 4.04) == "03:25:04.0400000", "TimeSpan hours")
check(SessionText.vmixDuration(-1) == "00:00:00.0000000", "negative clamps to 0")
check(SessionText.vmixLine(date: date("2020-07-16 15:24:09"), seconds: 16.7, tag: "TOC Timestamp")
      == "7/16/2020 3:24:09 PM, 00:00:16.7000000, TOC Timestamp", "line matches the vMix forum sample")
check(SessionText.vmixLine(date: date("2020-07-16 15:24:09"), seconds: 1, tag: "a\nb")
      == "7/16/2020 3:24:09 PM, 00:00:01.0000000, a b", "line break in tag removed")
check(SessionText.vmixLine(date: date("2020-07-16 15:24:09"), seconds: 1, tag: "")
      == "7/16/2020 3:24:09 PM, 00:00:01.0000000", "empty tag")
check(SessionText.baseName(date("2026-11-26 18:00:00")) == "HongMix_20261126_180000", "base name")

print("== frame-exact durations")
check(fmt2997.seconds(30000) == 1001, "30000 frames at 29.97 = 1001 s")
check(SessionText.vmixDuration(fmt2997.seconds(1)) == "00:00:00.0333667", "1 frame at 29.97")
check(SessionText.vmixDuration(fmt25.seconds(90_000)) == "01:00:00.0000000", "1 h at 25")
check(SessionText.vmixDuration(fmt5994.seconds(60_000)) == "00:16:41.0000000", "60000 frames at 59.94 = 1001 s")

print("== session")
func readLines(_ p: String) -> [String] {
    ((try? String(contentsOfFile: p, encoding: .utf8)) ?? "").components(separatedBy: "\r\n").filter { !$0.isEmpty }
}
do {
    let log = SessionLog()
    let start = date("2026-11-26 18:00:00")
    check(log.marker("too early", tick: 10, now: start) == nil, "marker refused without a recording")
    let isoA = SessionRecorder(key: "A", role: .iso, input: UUID(), path: work + "/1_Cam A_20261126_180000.mov")
    let pgm = SessionRecorder(key: "P", role: .program, input: nil, path: work + "/pgm/rec.mp4")
    try! FileManager.default.createDirectory(atPath: work + "/pgm", withIntermediateDirectories: true)
    log.sync(recorders: [isoA, pgm], tick: 1000, format: fmt25, now: start)
    check(log.isOpen, "session opens with the first recorders")
    let d = log.marker("good line", tick: 1000 + 25 * 75, now: date("2026-11-26 18:01:15"))
    check(d == 75, "marker duration from the session start (75 s)")
    log.sync(recorders: [isoA], tick: 3000, format: fmt25, now: start)   // Record stops, ISO goes on
    check(log.isOpen, "stays open while one recorder runs")
    _ = log.marker("", tick: 3000, now: date("2026-11-26 18:01:20"))
    log.sync(recorders: [], tick: 3100, format: fmt25, now: date("2026-11-26 18:02:04"))
    check(!log.isOpen, "closes after the last recorder")
    log.flush()
    let lines = readLines(work + "/pgm/HongMix_20261126_180000.log")
    check(lines == ["11/26/2026 6:00:00 PM, StartRecording",
                    "11/26/2026 6:01:15 PM, 00:01:15.0000000, good line",
                    "11/26/2026 6:01:20 PM, 00:01:20.0000000",
                    "11/26/2026 6:02:04 PM, StopRecording"], "log next to the program recording: \(lines)")
    check(log.marker("late", tick: 4000) == nil, "marker refused after the session")
}
do {   // no marker → no log file
    let log = SessionLog()
    let start = date("2026-11-26 19:00:00")
    log.sync(recorders: [SessionRecorder(key: "A", role: .iso, input: nil, path: work + "/2_B.mov")], tick: 0, format: fmt2997, now: start)
    log.close(tick: 100, wait: true)
    check(!FileManager.default.fileExists(atPath: work + "/HongMix_20261126_190000.log"), "no log file without markers")
}


print("== cut list")
func rec(_ type: String, _ frame: Int64, input: String? = nil, cause: String? = nil, start: Int64? = nil) -> SessionRecord {
    SessionRecord(type: type, frame: frame, input: input, cause: cause, start: start)
}
do {
    // session at tick 5000, 29.97; Cam A and Cam B have ISO files, Cam C only shows in the program file
    let header = SessionRecord(type: "session", frame: 5000, text: "HongMix test", wall: 1_800_000_000,
                               width: 1920, height: 1080, fpsNum: 30000, fpsDen: 1001)
    var r: [SessionRecord] = [header]
    for (i, n) in ["A", "B", "C"].enumerated() {
        r.append(SessionRecord(type: "input", frame: 5000, input: n, number: i + 1, text: "Cam \(n)"))
    }
    r.append(rec("program", 5000, input: "A", cause: "start"))
    r.append(SessionRecord(type: "file", frame: 5003, path: "/r/pgm.mp4", role: "program", recorder: "P"))
    r.append(SessionRecord(type: "file", frame: 5002, input: "A", path: "/r/1_A.mov", role: "iso", recorder: "A"))
    r.append(SessionRecord(type: "file", frame: 5002, input: "B", path: "/r/2_B.mov", role: "iso", recorder: "B"))
    r.append(rec("program", 5300, input: "B", cause: "cut"))
    r.append(SessionRecord(type: "transition", frame: 5600, input: "A", from: "B", transition: "fade"))
    r.append(rec("program", 5630, input: "A", cause: "transition", start: 5600))   // cut at 5615
    r.append(SessionRecord(type: "marker", frame: 5700, text: "good line", wall: 1_800_000_023))
    r.append(rec("program", 5900, input: "C", cause: "cut"))                       // no ISO → program file
    r.append(SessionRecord(type: "file", frame: 6000, input: "A", path: "/r/1_A_2.mov", role: "iso", recorder: "A"))  // split
    r.append(rec("program", 6100, input: "A", cause: "stinger"))
    r.append(SessionRecord(type: "stall", frame: 6150, lostMs: 140))
    r.append(SessionRecord(type: "stop", frame: 6200))
    let doc = SessionCutList.document(r)!
    check(doc.startTick == 5000 && doc.durationFrames == 1200, "frame 0 = session start, 1200 frames")
    check(doc.format.frameRate == "30000/1001", "exact rate 30000/1001")
    check(doc.inputs.map(\.name) == ["Cam A", "Cam B", "Cam C"], "inputs by number")
    check(doc.files.count == 4, "4 files")
    let a1 = doc.files.first { $0.path == "/r/1_A.mov" }!
    check(a1.firstFrame == 2 && a1.endFrame == 1000, "ISO A file 1: frames 2…1000 (split at 1000)")
    let s = doc.shots.map { "\($0.start)-\($0.end) \($0.name ?? "-") \($0.source ?? "-") \($0.file.map { ($0 as NSString).lastPathComponent } ?? "-")@\($0.fileFrame ?? -1)" }
    let expected = [
        "0-2 Cam A - -@-1",                         // ISO not started yet, program file neither
        "2-300 Cam A iso 1_A.mov@0",
        "300-615 Cam B iso 2_B.mov@298",            // fade 600…630 cut at its midpoint
        "615-900 Cam A iso 1_A.mov@613",
        "900-1100 Cam C program pgm.mp4@897",       // Cam C has no ISO: program file (started at 3)
        "1100-1200 Cam A iso 1_A_2.mov@100",        // stinger cut, after the split
    ]
    check(s == expected, "shots:\n      " + s.joined(separator: "\n      "))
    let m = doc.events.first { $0.type == "marker" }!
    check(m.frame == 700 && m.text == "good line", "marker at session frame 700")
    check(doc.events.contains { $0.type == "stall" && $0.frame == 1150 && $0.lostMs == 140 }, "stall kept")
    check(!doc.events.contains { ["session", "input", "file", "stop"].contains($0.type) }, "header/inputs/files not in events")
    // JSON round trip
    let data = SessionCutList.json(doc)!
    let back = try! JSONDecoder().decode(SessionDocument.self, from: data)
    check(back == doc, "session.json decodes to the same document")
    let text = String(decoding: data, as: UTF8.self)
    check(!text.contains("\"lostMs\" : null") && text.contains("\"frameRate\" : \"30000\\/1001\"") == false
          && text.contains("\"frameRate\" : \"30000/1001\""), "no nulls, slashes not escaped")
    // crash: journal without stop → ends at the last record
    let crashed = SessionCutList.document(Array(r.dropLast()))!
    check(crashed.durationFrames == 1150, "journal without stop ends at the last event")
}
do {   // the same cut at 59.94 and 25: frames stay frames
    for (num, den) in [(60000, 1001), (25, 1)] {
        let r: [SessionRecord] = [
            SessionRecord(type: "session", frame: 0, wall: 0, width: 1920, height: 1080, fpsNum: num, fpsDen: den),
            SessionRecord(type: "file", frame: 1, input: "A", path: "/a.mov", role: "iso", recorder: "A"),
            SessionRecord(type: "file", frame: 1, input: "B", path: "/b.mov", role: "iso", recorder: "B"),
            rec("program", 0, input: "A", cause: "start"), rec("program", 1234, input: "B", cause: "cut"),
            rec("program", 4321, input: "A", cause: "cut"), SessionRecord(type: "stop", frame: 9000)]
        let d = SessionCutList.document(r)!
        check(d.shots.map(\.start) == [0, 1, 1234, 4321] && d.shots[2].fileFrame == 1233, "cuts at \(num)/\(den) land on their frames")
    }
}

print("== editor files")
do {
    let header = SessionRecord(type: "session", frame: 0, text: "t", wall: 0, width: 1920, height: 1080, fpsNum: 30000, fpsDen: 1001)
    let r: [SessionRecord] = [header,
        SessionRecord(type: "input", frame: 0, input: "A", number: 1, text: "Host & Co"),
        SessionRecord(type: "input", frame: 0, input: "B", number: 2, text: "Gość"),
        SessionRecord(type: "file", frame: 0, input: "A", path: "/Rec/1_Host & Co.mov", role: "iso", recorder: "A"),
        SessionRecord(type: "file", frame: 0, input: "B", path: "/Rec/2_Gość.mov", role: "iso", recorder: "B"),
        rec("program", 0, input: "A", cause: "start"), rec("program", 300, input: "B", cause: "cut"),
        SessionRecord(type: "marker", frame: 450, text: "<laugh> \"1\""),
        rec("program", 1800, input: "A", cause: "cut"), SessionRecord(type: "stop", frame: 2000)]
    let doc = SessionCutList.document(r)!
    let x = SessionEditorFiles.fcpxml(doc, name: "HongMix_test")
    let xml = try? XMLDocument(xmlString: x, options: [])
    check(xml != nil, "FCPXML is well-formed XML")
    if let root = xml?.rootElement() {
        check(root.attribute(forName: "version")?.stringValue == "1.10", "fcpxml version 1.10")
        let fmt = (try? root.nodes(forXPath: "//format"))?.first as? XMLElement
        check(fmt?.attribute(forName: "frameDuration")?.stringValue == "1001/30000s", "frameDuration 1001/30000s")
        let clips = ((try? root.nodes(forXPath: "//spine/asset-clip")) ?? []).compactMap { $0 as? XMLElement }
        let rows = clips.map { c in ["offset", "start", "duration", "name"].map { c.attribute(forName: $0)?.stringValue ?? "?" }.joined(separator: " ") }
        check(rows == ["0s 0s 1001/100s Host & Co", "1001/100s 1001/100s 1001/20s Gość", "3003/50s 3003/50s 1001/150s Host & Co"],
              "clips: \(rows)")
        let mk = ((try? root.nodes(forXPath: "//asset-clip/marker")) ?? []).compactMap { $0 as? XMLElement }
        check(mk.count == 1 && mk[0].attribute(forName: "start")?.stringValue == "3003/200s"
              && mk[0].attribute(forName: "value")?.stringValue == "<laugh> \"1\"", "marker at frame 450 on the Gość clip, text escaped")
        let src = ((try? root.nodes(forXPath: "//media-rep/@src")) ?? []).map { $0.stringValue ?? "" }
        check(src.contains("file:///Rec/1_Host%20&%20Co.mov") || src.contains("file:///Rec/1_Host%20%26%20Co.mov"), "file URL encoded: \(src)")
        let seq = (try? root.nodes(forXPath: "//sequence"))?.first as? XMLElement
        check(seq?.attribute(forName: "duration")?.stringValue == "2002/30s" || seq?.attribute(forName: "duration")?.stringValue == "1001/15s", "sequence 2000 frames")
    }
    let e = SessionEditorFiles.edl(doc, name: "HongMix_test")!
    let lines = e.components(separatedBy: "\n")
    check(lines[0] == "TITLE: HongMix_test" && lines[1] == "FCM: NON-DROP FRAME", "EDL header")
    check(lines.contains("001  HOST_CO  AA/V  C        00:00:00:00 00:00:10:00 01:00:00:00 01:00:10:00"), "event 1 (reel from name): \n" + e)
    check(lines.contains("002  GO       AA/V  C        00:00:10:00 00:01:00:00 01:00:10:00 01:01:00:00")
          || lines.contains { $0.hasPrefix("002  ") && $0.hasSuffix("00:00:10:00 00:01:00:00 01:00:10:00 01:01:00:00") }, "event 2 at 29.97 NDF counts 30/s")
    check(lines.contains("* LOC: 01:00:15:00 BLUE    <laugh> \"1\""), "marker as LOC")
    check(lines.contains("* FROM CLIP NAME: 2_Gość.mov"), "clip name comment")
    check(SessionEditorFiles.reel("Cam A") == "CAM_A" && SessionEditorFiles.reel("ąę") == "AX", "reel names")
    var d60 = doc; d60.format.fpsNum = 60000
    check(SessionEditorFiles.edl(d60, name: "x") == nil, "no EDL above 30 fps")
    var d25 = doc; d25.format = .init(width: 1920, height: 1080, fpsNum: 25, fpsDen: 1, frameRate: "25/1")
    let x25 = SessionEditorFiles.fcpxml(d25, name: "x")
    check(x25.contains("frameDuration=\"1/25s\"") && x25.contains("offset=\"12s\""), "25p times reduce (300 frames = 12s)")
}

print("== session with journal")
do {
    let dir = work + "/cut"
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let log = SessionLog()
    let start = date("2026-11-26 20:00:00")
    let A = UUID(), B = UUID()
    log.ingest(SessionRecord(type: "program", frame: 10, input: A.uuidString, cause: "start"))   // before the session
    log.ingest(SessionRecord(type: "overlay", frame: 20, input: B.uuidString, channel: 1, on: true))
    let ins = [SessionInputInfo(id: A.uuidString, number: 1, name: "Host"), SessionInputInfo(id: B.uuidString, number: 2, name: "Guest")]
    var isoA = SessionRecorder(key: A.uuidString, role: .iso, input: A, path: dir + "/1_Host.mov")
    log.sync(recorders: [isoA], tick: 100, format: fmt25, inputs: ins, cutList: true, now: start)
    isoA.firstTick = 101
    log.sync(recorders: [isoA], tick: 130, format: fmt25, inputs: ins, cutList: true, now: start)
    log.ingest(SessionRecord(type: "program", frame: 150, input: B.uuidString, from: A.uuidString, cause: "cut"))
    _ = log.marker("laugh", tick: 175, now: date("2026-11-26 20:00:03"))
    log.flush()
    let journal = dir + "/HongMix_20261126_200000.session.journal"
    let jr = SessionCutList.records(journal: (try? Data(contentsOf: URL(fileURLWithPath: journal))) ?? Data())
    check(jr.first?.type == "session" && jr.contains { $0.type == "marker" }, "journal written while recording (\(jr.count) lines)")
    var written: [String] = []
    log.onWritten = { written = $0 }
    log.sync(recorders: [], tick: 200, format: fmt25, inputs: ins, cutList: true, now: date("2026-11-26 20:00:04"))
    log.flush()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))   // onWritten comes on the main queue
    let json = dir + "/HongMix_20261126_200000.session.json"
    let doc = (try? Data(contentsOf: URL(fileURLWithPath: json))).flatMap { try? JSONDecoder().decode(SessionDocument.self, from: $0) }
    check(doc != nil, "session.json written")
    check(!FileManager.default.fileExists(atPath: journal), "journal removed after a clean stop")
    if let doc {
        check(doc.startTick == 100 && doc.durationFrames == 100, "session 100…200")
        let shots = doc.shots.map { "\($0.start)-\($0.end) \($0.name ?? "")@\($0.fileFrame ?? -1)" }
        check(shots == ["0-1 Host@-1", "1-50 Host@0", "50-100 Guest@-1"], "shots from the state before the session + the cut: \(shots)")
        check(written.map { ($0 as NSString).lastPathComponent } == ["session.json", "fcpxml", "edl"].map { "HongMix_20261126_200000." + $0 }, "onWritten reports session.json, .fcpxml, .edl: \(written)")
        check(doc.shots.first?.file == nil && doc.shots.first?.start == 0, "Host shot starts at 0")
        check(doc.events.contains { $0.type == "overlay" && $0.frame == 0 && $0.on == true }, "overlay that was on at the start is logged at frame 0")
        check(doc.events.contains { $0.type == "marker" && $0.frame == 75 }, "marker at frame 75")
        check(doc.files.first?.firstFrame == 1, "ISO file first frame 1")
    }
}
do {   // cut list off: no journal, no session.json, log still works
    let dir = work + "/off"
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let log = SessionLog()
    log.sync(recorders: [SessionRecorder(key: "P", role: .program, input: nil, path: dir + "/r.mp4", firstTick: 5)],
             tick: 5, format: fmt25, cutList: false, now: date("2026-11-26 21:00:00"))
    _ = log.marker("x", tick: 30)
    log.close(tick: 50, wait: true)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    check(names == ["HongMix_20261126_210000.log"], "cut list off: only the .log (\(names))")
}

print(failures == 0 ? "PASS (\(checks) checks)" : "FAIL (\(failures) of \(checks))")
exit(failures == 0 ? 0 : 1)
