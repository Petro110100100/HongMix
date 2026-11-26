#!/bin/bash
# End-to-end session log test of the built app (no cameras): three generated clips as inputs, Record +
# MultiCorder, a scripted run of cuts, a fade, an overlay and two WriteDurationToRecordingLog markers,
# then checks what HongMix wrote:
#   • every hard cut in session.json lands on the frame where the program recording changes input
#     (program frame at the cut matches the new input's ISO frame, the frame before matches the old one);
#   • each ISO position is frame-exact (the matching ISO frame beats its neighbours ±1);
#   • .log lines, .fcpxml (well-formed, one clip per shot) and .edl (≤ 30 fps) are there.
# Usage: tests/sessionlog/app-cut-test.sh [1080p2997|1080p25|1080p5994] [path/to/HongMix.app]
# Uses the app's normal preferences and ~/Movies/HongMix — run it on a test account or CI runner.
set -u
cd "$(dirname "$0")/../.."
FMT=${1:-1080p2997}
APP=${2:-build/cli/HongMix.app}
case "$FMT" in
  1080p25) RATE=25 ;;
  1080p2997) RATE=30000/1001 ;;
  1080p5994) RATE=60000/1001 ;;
  *) echo "unknown format $FMT"; exit 2 ;;
esac
for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$p" ] && eval "$("$p" shellenv)" && break; done
FFP="$(brew --prefix 2>/dev/null)/opt/ffmpeg-full/bin"; [ -x "$FFP/ffmpeg" ] || FFP="$(brew --prefix 2>/dev/null)/opt/ffmpeg/bin"
FFMPEG="$FFP/ffmpeg"; [ -x "$FFMPEG" ] || FFMPEG=ffmpeg
FFPROBE="$FFP/ffprobe"; [ -x "$FFPROBE" ] || FFPROBE=ffprobe
W="${TMPDIR:-/tmp}/hm-cut-$FMT"; rm -rf "$W"; mkdir -p "$W/media" "$W/iso"
API=http://127.0.0.1:8088/api/
x() {   # x Function [Input] [Value] [Duration]
  local a=(-s -m 5 -G "$API" --data-urlencode "Function=$1")
  [ -n "${2:-}" ] && a+=(--data-urlencode "Input=$2")
  [ -n "${3:-}" ] && a+=(--data-urlencode "Value=$3")
  [ -n "${4:-}" ] && a+=(--data-urlencode "Duration=$4")
  curl "${a[@]}"; echo " <- $1 ${2:-} ${3:-}" >> "$W/api.log"
}

echo "== media ($FMT)"
i=0
for src in "testsrc2=size=1920x1080:rate=$RATE" "testsrc=size=1920x1080:rate=$RATE" "rgbtestsrc=size=1920x1080:rate=$RATE,hue=H=t*2"; do
  i=$((i+1))
  # a big block jumps 37 px per frame, so neighbouring frames differ clearly even at 48x27
  "$FFMPEG" -hide_banner -v error -y -f lavfi -i "$src" -f lavfi -i "sine=frequency=$((200*i)):sample_rate=48000" \
    -f lavfi -i "color=white:size=200x480:rate=$RATE" -t 60 \
    -filter_complex "[0:v][2:v]overlay=x='mod(n*137,1700)':y=300:shortest=1[v]" -map "[v]" -map 1:a \
    -c:v libx264 -preset ultrafast -g 1 -pix_fmt yuv420p -c:a aac "$W/media/cam$i.mp4" || exit 1
done

echo "== launch"
pkill -f "MacOS/HongMix" 2>/dev/null; sleep 1
D=com.hongseunghoon.HongMix
defaults write $D apiEnabled -bool true
defaults write $D apiAccessMode local
defaults write $D sessionCutList -bool true
SUP="$HOME/Library/Application Support/HongMix"; mkdir -p "$SUP"
cat > "$SUP/last-session.bmix" <<JSON
{"version":4,"formatID":"$FMT","inputs":[],"outputs":[],"masterVolume":1,
 "multiCorder":{"folder":"$W/iso","videoCodec":"h264","container":"mov","videoKbps":8000,"audioFromMaster":false,"splitMinutes":0}}
JSON
mark=$(mktemp); sleep 1
"$APP/Contents/MacOS/HongMix" > "$W/app.log" 2>&1 &
APID=$!
for k in $(seq 1 90); do curl -s -m 2 "$API" | grep -q "<vmix>" && break; sleep 1; done
curl -s -m 2 "$API" | grep -q "<vmix>" || { echo "FAIL: API did not come up"; tail -50 "$W/app.log"; kill $APID; exit 1; }
curl -s -m 2 "$API" | grep -oE '<version>[^<]*|<preset>[^<]*' | head -3

for n in 1 2 3; do x AddInput "" "Video|$W/media/cam$n.mp4" >/dev/null; done
sleep 4
for n in 1 2 3; do x LoopOn $n >/dev/null; x SetMultiCorder $n on >/dev/null; x Play $n >/dev/null; done
x CutDirect 1 >/dev/null; sleep 2
x WriteDurationToRecordingLog "" "refused" > "$W/refused.txt"

echo "== record"
x StartRecording >/dev/null; x StartMultiCorder >/dev/null; sleep 3
x CutDirect 2 >/dev/null; sleep 2.3
x WriteDurationToRecordingLog "" "mark one" >/dev/null; sleep 0.4
x CutDirect 3 >/dev/null; sleep 1.7
x Fade 1 "" 500 >/dev/null; sleep 2.2
x CutDirect 2 >/dev/null; sleep 1.1
x CutDirect 1 >/dev/null; sleep 1.5
x OverlayInput1In 3 >/dev/null; sleep 1.2; x OverlayInput1Out >/dev/null; sleep 1.5
x CutDirect 3 >/dev/null; sleep 2.5
x WriteDurationToRecordingLog "" "mark two" >/dev/null; sleep 0.3
x CutDirect 2 >/dev/null; sleep 0.9
x CutDirect 1 >/dev/null; sleep 2
curl -s -m 5 "$API" | grep -oE '<renderStats [^>]*>' | tee "$W/renderstats.txt"
x StopMultiCorder >/dev/null; x StopRecording >/dev/null
for k in $(seq 1 30); do
  J=$(find "$HOME/Movies/HongMix" "$W/iso" -maxdepth 1 -name '*.session.json' -newer "$mark" 2>/dev/null | head -1)
  [ -n "$J" ] && break; sleep 1
done
sleep 2
kill -TERM $APID 2>/dev/null; sleep 3; kill -9 $APID 2>/dev/null
[ -n "${J:-}" ] || { echo "FAIL: no session.json"; tail -40 "$W/app.log"; ls -la "$HOME/Movies/HongMix" "$W/iso"; exit 1; }
B="${J%.session.json}"
echo "session: $J"; ls -la "$(dirname "$J")" "$W/iso"
cp "$B".* "$W/" 2>/dev/null

echo "== check"
python3 -I - "$J" "$FFMPEG" "$FFPROBE" "$W" <<'PY'
import json, os, subprocess, sys, xml.dom.minidom
J, FF, FP, W = sys.argv[1:5]
doc = json.load(open(J))
num, den = doc['format']['fpsNum'], doc['format']['fpsDen']
fps = num / den
ok = True
def check(c, m):
    global ok
    print(("  ok    " if c else "  FAIL  ") + m); ok = ok and c
base = J[:-len('.session.json')]
inputs = {i['id']: i for i in doc['inputs']}
files = doc['files']
pgm = [f for f in files if f['role'] == 'program']
iso = {f['input']: f for f in files if f['role'] == 'iso'}
check(len(pgm) >= 1 and len(iso) == 3, f"files: {len(pgm)} program, {len(iso)} ISO")
SW, SH = 96, 54
def frames(path):
    """file frame index (by timestamp) -> small RGB picture"""
    raw = subprocess.run([FF, '-v', 'error', '-i', path, '-vf', f'scale={SW}:{SH}:flags=area,format=rgb24',
                          '-fps_mode', 'passthrough', '-f', 'rawvideo', '-'], capture_output=True).stdout
    ts = subprocess.run([FP, '-v', 'error', '-select_streams', 'v', '-show_entries', 'frame=best_effort_timestamp_time',
                         '-of', 'csv=p=0', path], capture_output=True, text=True).stdout.split()
    ts = [t.split(',')[0] for t in ts if t.split(',')[0]]
    n = SW * SH * 3
    out = {}
    for k, t in enumerate(ts):
        if (k + 1) * n > len(raw) or t in ('N/A', ''): break
        out[round(float(t) * fps)] = raw[k * n:(k + 1) * n]
    return out
def mad(a, b):
    if a is None or b is None: return 1e9
    return sum(abs(x - y) for x, y in zip(a, b)) / len(a)
P = frames(pgm[0]['path']); p0 = pgm[0]['firstFrame']
I = {k: frames(v['path']) for k, v in iso.items()}
check(len(P) > 10 and all(len(v) > 10 for v in I.values()), f"decoded {len(P)} program frames, ISO {[len(v) for v in I.values()]}")
def pf(s): return P.get(s - p0)
def isf(inp, s): return I[inp].get(s - iso[inp]['firstFrame'])
busy = [e['frame'] for e in doc['events'] if e['type'] in ('overlay', 'transition')]
cuts = [e for e in doc['events'] if e['type'] == 'program' and e.get('cause') == 'cut' and e.get('from')]
check(len(cuts) >= 6, f"{len(cuts)} hard cuts logged")
exact = 0; tested = 0; rows = []
for e in cuts:
    c, new, old = e['frame'], e['input'], e['from']
    if any(abs(c - b) < fps * 1.0 for b in busy): continue
    tested += 1
    at = pf(c); before = pf(c - 1)
    m_new, m_old = mad(at, isf(new, c)), mad(at, isf(old, c))
    b_old, b_new = mad(before, isf(old, c - 1)), mad(before, isf(new, c - 1))
    nb = min(mad(at, isf(new, c - 1)), mad(at, isf(new, c + 1)))
    good = m_new < m_old and b_old < b_new and m_new <= nb
    exact += good
    rows.append(f"    cut @{c:5d} {inputs[old]['name']}→{inputs[new]['name']}: pgm@c≈new {m_new:.1f} (old {m_old:.1f}), "
                f"pgm@c-1≈old {b_old:.1f} (new {b_new:.1f}), new ±1 {nb:.1f} {'EXACT' if good else 'OFF'}")
print("\n".join(rows))
# diagnostics: alignment of program vs ISO inside shots, and where the program really changes at each cut
def best_offset(inp, f):
    sc = [(mad(pf(f), isf(inp, f + o)), o) for o in range(-12, 13)]
    return min(sc)
aligns = []
for shot in doc["shots"]:
    if shot.get('input') in iso and shot['end'] - shot['start'] > 20:
        mid = (shot['start'] + shot['end']) // 2
        m, o = best_offset(shot['input'], mid)
        aligns.append(o)
print(f"    program vs ISO alignment inside shots (ISO frame offset that matches best): {aligns}")
delays = []
for e in cuts:
    c, new, old = e['frame'], e['input'], e['from']
    first_new = next((k for k in range(c - 12, c + 13) if mad(pf(k), isf(new, k)) < mad(pf(k), isf(old, k))), None)
    delays.append(None if first_new is None else first_new - c)
print(f"    program shows the new input from cut frame + {delays}")
for f in [pgm[0]] + list(iso.values()):
    st = subprocess.run([FP, '-v', 'error', '-select_streams', 'v', '-show_entries', 'stream=start_time,nb_frames,r_frame_rate,avg_frame_rate:format=start_time',
                         '-of', 'compact', f['path']], capture_output=True, text=True).stdout.strip().replace('\n', ' ')
    print(f"    {os.path.basename(f['path'])}: firstFrame {f['firstFrame']} | {st}")
for f in [pgm[0]] + list(iso.values()):
    pk = subprocess.run([FP, '-v', 'error', '-select_streams', 'v', '-show_entries', 'packet=pts,dts,pts_time,flags:stream=time_base',
                         '-read_intervals', '%+#4', '-of', 'compact', f['path']], capture_output=True, text=True).stdout.strip().replace('\n', ' ; ')
    print(f"    {os.path.basename(f['path'])} packets: {pk}")
    ks = sorted(I[f['input']].keys()) if f['role'] == 'iso' else sorted(P.keys())
    print(f"      decoded idx {ks[0]}..{ks[-1]} n={len(ks)} gaps={[k for a, k in zip(ks, ks[1:]) if k != a + 1][:10]}")
print("    SLDBG lines:"); os.system(f"grep SLDBG '{W}/app.log' | head -80")
check(tested >= 5 and exact == tested, f"{exact} of {tested} cuts frame-exact against the program recording")
# shots cover the session
sh = doc['shots']
check(sh and sh[0]['start'] == 0 and sh[-1]['end'] == doc['durationFrames'] and all(a['end'] == b['start'] for a, b in zip(sh, sh[1:])),
      f"{len(sh)} shots cover 0…{doc['durationFrames']}")
marks = [e for e in doc['events'] if e['type'] == 'marker']
check([m.get('text') for m in marks] == ['mark one', 'mark two'], f"markers {[m.get('text') for m in marks]}")
# .log
log = open(base + '.log', encoding='utf-8', newline='').read().split('\r\n')
lines = [l for l in log if l]
check(len(lines) == 4 and lines[0].endswith('StartRecording') and lines[-1].endswith('StopRecording')
      and lines[1].endswith('mark one') and lines[2].endswith('mark two'), f".log: {lines}")
def secs(l):
    h, m, s = l.split(', ')[1].split(':'); return int(h) * 3600 + int(m) * 60 + float(s)
if len(lines) == 4:
    for l, m in zip(lines[1:3], marks):
        check(abs(secs(l) - m['frame'] / fps) < 0.5, f"log duration {secs(l):.3f} s ≈ marker frame {m['frame']} / fps")
refused = open(os.path.join(W, 'refused.txt')).read()
check('No recording running' in refused, f"marker without recording refused: {refused.strip()[:60]}")
# fcpxml / edl
try:
    d = xml.dom.minidom.parse(base + '.fcpxml')
    clips = d.getElementsByTagName('asset-clip'); gaps = d.getElementsByTagName('gap')
    check(len(clips) + len(gaps) == len(sh), f".fcpxml: {len(clips)} clips + {len(gaps)} gaps = {len(sh)} shots")
    check(len(d.getElementsByTagName('marker')) == 2, ".fcpxml: 2 markers")
except Exception as ex:
    check(False, f".fcpxml parse: {ex}")
if fps <= 30.5:
    edl = open(base + '.edl').read()
    check(edl.startswith('TITLE:') and edl.count('* FROM CLIP NAME:') == sum(1 for s in sh if s.get('file')), ".edl: one event per shot with a file")
else:
    check(not os.path.exists(base + '.edl'), "no .edl above 30 fps")
check(not os.path.exists(base + '.session.journal'), "journal removed after the clean stop")
stats = open(os.path.join(W, 'renderstats.txt')).read().strip()
print("  render:", stats)
sys.exit(0 if ok else 1)
PY
rc=$?
[ $rc -eq 0 ] && echo "PASS ($FMT)" || echo "FAIL ($FMT)"
exit $rc
