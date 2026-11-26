// Standalone test of the session log (Sources/App/Engine/SessionLog.swift, compiled with
// -D SESSIONLOG_STANDALONE so the app glue is left out). Run: bash tests/sessionlog/run.sh
//
// Covers: vMix recording-log text (date, TimeSpan duration, tag clean-up), session open/close with the
// recorders, markers refused without a recording, frame-exact durations at 25, 29.97 and 59.94.
import Foundation

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

print(failures == 0 ? "PASS (\(checks) checks)" : "FAIL (\(failures) of \(checks))")
exit(failures == 0 ? 0 : 1)
