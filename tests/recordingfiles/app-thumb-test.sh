#!/bin/bash
# Recording list test of the built app (no cameras): records two short takes of a colour input, then renders
# the Recording Settings rows (API SnapshotView "recordings") in Korean and English and checks that the
# row shows a thumbnail of the newest file. Also moves the file away and checks the row falls back to
# the record symbol instead of failing.
# Usage: tests/recordingfiles/app-thumb-test.sh [path/to/HongMix.app]
# Uses the app's normal preferences and ~/Movies/HongMix — run it on a test account or CI runner.
set -u
cd "$(dirname "$0")/../.."
APP=${1:-build/cli/HongMix.app}
W="${TMPDIR:-/tmp}/hm-recfiles"; rm -rf "$W"; mkdir -p "$W/rec" "$W/shots"
API=http://127.0.0.1:8088/api/
x() { curl -s -m 8 -G "$API" --data-urlencode "Function=$1" ${2:+--data-urlencode "Value=$2"}; echo " <- $1 ${2:-}" >> "$W/api.log"; }

pkill -f "MacOS/HongMix" 2>/dev/null; sleep 1
D=com.hongseunghoon.HongMix
defaults write $D apiEnabled -bool true
defaults write $D apiAccessMode local
SUP="$HOME/Library/Application Support/HongMix"; mkdir -p "$SUP"
cat > "$SUP/last-session.bmix" <<JSON
{"version":4,"formatID":"1080p2997","inputs":[],"outputs":[],"masterVolume":1}
JSON
"$APP/Contents/MacOS/HongMix" > "$W/app.log" 2>&1 &
APID=$!
for k in $(seq 1 90); do curl -s -m 2 "$API" | grep -q "<vmix>" && break; sleep 1; done
curl -s -m 2 "$API" | grep -q "<vmix>" || { echo "FAIL: API did not come up"; tail -50 "$W/app.log"; kill $APID; exit 1; }

x AddInput "Colour|#2E8B57" >/dev/null; sleep 2
curl -s -m 3 -G "$API" --data-urlencode "Function=CutDirect" --data-urlencode "Input=1" >/dev/null
sleep 1
mark=$(mktemp); sleep 1
for take in 1 2; do
  x StartRecording >/dev/null; sleep 4; x StopRecording >/dev/null; sleep 3
done
FILES=$(find "$HOME/Movies/HongMix" -maxdepth 1 -type f -newer "$mark" \( -name '*.mov' -o -name '*.mp4' -o -name '*.mkv' \) | sort)
echo "recorded:"; echo "$FILES"
N=$(echo "$FILES" | grep -c . || true)

shot() { x SnapshotView "recordings,$W/shots/$1.png"; sleep 3; }
x SnapshotView "lang-ko" >/dev/null
shot warm-ko; shot rows-ko          # first render starts the Quick Look thumbnail, second uses the cache
x SnapshotView "lang-en" >/dev/null
shot rows-en
LAST=$(echo "$FILES" | tail -1)
[ -n "$LAST" ] && mv "$LAST" "$W/rec/"
sleep 1; shot rows-missing-en
x SnapshotView "lang-ko" >/dev/null
kill -TERM $APID 2>/dev/null; sleep 3; kill -9 $APID 2>/dev/null
ls -la "$W/shots"

python3 -I - "$W/shots" "$N" <<'PY'
import os, sys, zlib, struct
d, n = sys.argv[1], int(sys.argv[2])
ok = True
def check(c, m):
    global ok
    print(("  ok    " if c else "  FAIL  ") + m); ok = ok and c
def png(path):
    b = open(path, 'rb').read()
    assert b[:8] == b'\x89PNG\r\n\x1a\n'
    i, idat, w = 8, b'', 0
    while i < len(b):
        ln, = struct.unpack('>I', b[i:i+4]); t = b[i+4:i+8]; c = b[i+8:i+8+ln]
        if t == b'IHDR': w, h, depth, ct = struct.unpack('>IIBB', c[:10])
        if t == b'IDAT': idat += c
        i += 12 + ln
    bpp = {2: 3, 6: 4}[ct]
    raw = zlib.decompress(idat); stride = w * bpp; rows = []; prev = bytearray(stride); p = 0
    for y in range(h):
        f = raw[p]; line = bytearray(raw[p+1:p+1+stride]); p += 1 + stride
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0; up = prev[x]; c = prev[x-bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + up) & 255
            elif f == 3: line[x] = (line[x] + (a + up) // 2) & 255
            elif f == 4:
                pa, pb, pc = abs(up - c), abs(a - c), abs(a + up - 2 * c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else up if pb <= pc else c)) & 255
        rows.append(bytes(line)); prev = line
    return w, h, bpp, rows
def green_px(path):
    """pixels close to the recorded colour #2E8B57 (sea green) = the thumbnail"""
    w, h, bpp, rows = png(path)
    return sum(1 for r in rows for x in range(0, w * bpp, bpp)
               if abs(r[x] - 0x2E) < 30 and abs(r[x+1] - 0x8B) < 30 and abs(r[x+2] - 0x57) < 30)
check(n >= 2, f"{n} recorded files")
for name in ("rows-ko", "rows-en", "rows-missing-en"):
    check(os.path.exists(os.path.join(d, name + ".png")), f"{name}.png written")
if ok:
    g_ko, g_en, g_miss = (green_px(os.path.join(d, f + ".png")) for f in ("rows-ko", "rows-en", "rows-missing-en"))
    print(f"  green pixels: ko {g_ko}, en {g_en}, missing {g_miss}")
    check(g_ko > 400, "Korean row shows the thumbnail")
    check(g_en > 400, "English row shows the thumbnail")
    check(g_miss < 50, "moved file: row falls back to the symbol")
print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
PY
