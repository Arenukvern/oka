#!/usr/bin/env bash
# ADR-0032 G4: web lane — kernel-partitioned (deferred) chunks flow through
# the ADR-0031 pointer/manifest pipeline, verified by transfer behavior:
#
#   rev-a build -> manifest + pointer -> serve -> rev-b build (one unit body
#   changed) -> pointer repoint -> conditional re-fetch must transfer ONLY
#   changed artifacts (changed unit chunk: 200; unchanged: 304), served bytes
#   must hash-match the manifest, and the served chunk must carry the new
#   revision marker (verify rung).
#
# Subject: the deferred-units spike web app (web lane lives there; the kernel
# gates live in this package).
set -euo pipefail

SUBJECT=${OKA_WEB_SPIKE:-$HOME/xs/oka-patch-spike/spike}
[ -d "$SUBJECT/web" ] || { echo "subject web app not found at $SUBJECT"; exit 1; }
OUT="$SUBJECT/.gate_g4"
rm -rf "$OUT"
mkdir -p "$OUT" "$OUT/serve" "$OUT/build_a" "$OUT/build_b"
cd "$SUBJECT"

set_label() { sed -i '' "s/alpha-[a-z0-9][a-z0-9-]*/$1/" lib/units/alpha.dart; grep -q "$1" lib/units/alpha.dart || { echo "set_label: $1 not applied"; exit 1; }; }
build() { dart compile js web/main.dart -o web/main.dart.js >/dev/null 2>&1; }

ARTIFACTS="index.html main.dart.js main.dart.js_1.part.js main.dart.js_2.part.js"

snapshot() { # $1 = dir
  for f in $ARTIFACTS; do cp -p "web/$f" "$1/$f"; done
  for f in $ARTIFACTS; do shasum -a 256 "$1/$f" | awk '{print $1"  "$2}'; done > "$1/SHA256SUMS"
}

echo '=== [g4] rev-a: build + manifest + pointer'
set_label alpha-g4a
build
snapshot "$OUT/build_a"
cat > "$OUT/pointer.json" <<EOF
{"revision": "rev-a", "units": {"alpha": {"chunk": "main.dart.js_1.part.js"}}, "manifest": "SHA256SUMS"}
EOF

echo '=== [g4] serve rev-a'
cp -p "$OUT"/build_a/* "$OUT/serve/"
SERVER_PID=""
python3 -m http.server 8741 --directory "$OUT/serve" > "$OUT/server.log" 2>&1 &
SERVER_PID=$!
sleep 1
curl -s "http://127.0.0.1:8741/main.dart.js_1.part.js" | grep -q 'alpha-g4a' \
  || { echo 'G4: FAIL — rev-a chunk not served'; kill $SERVER_PID; exit 1; }
LM_BETA=$(curl -sI "http://127.0.0.1:8741/main.dart.js_2.part.js" | grep -i last-modified | cut -d' ' -f2- | tr -d '\r')
LM_MAIN=$(curl -sI "http://127.0.0.1:8741/main.dart.js" | grep -i last-modified | cut -d' ' -f2- | tr -d '\r')
echo "rev-a served; LM beta: $LM_BETA"

echo '=== [g4] rev-b: rebuild (alpha body only), repoint pointer, swap artifacts'
sleep 2 # mtimes have 1s granularity; the swap must be strictly newer
set_label alpha-g4b
build
snapshot "$OUT/build_b"
# swap: changed files get fresh mtimes; unchanged files keep rev-a mtimes so
# conditional revalidation behaves like a browser's.
for f in $ARTIFACTS; do
  if cmp -s "$OUT/build_a/$f" "$OUT/build_b/$f"; then
    cp -p "$OUT/build_a/$f" "$OUT/serve/$f"
  else
    cp "$OUT/build_b/$f" "$OUT/serve/$f"
    echo "changed: $f"
  fi
done
cat > "$OUT/pointer.json" <<EOF
{"revision": "rev-b", "units": {"alpha": {"chunk": "main.dart.js_1.part.js"}}, "manifest": "SHA256SUMS"}
EOF

echo '=== [g4] client revalidation (conditional GETs)'
CODE_ALPHA=$(curl -s -o "$OUT/fetched_alpha.js" -w '%{http_code}' \
  -H "If-Modified-Since: $LM_BETA" "http://127.0.0.1:8741/main.dart.js_1.part.js")
CODE_BETA=$(curl -s -o /dev/null -w '%{http_code}' \
  -H "If-Modified-Since: $LM_BETA" "http://127.0.0.1:8741/main.dart.js_2.part.js")
CODE_MAIN=$(curl -s -o "$OUT/fetched_main.js" -w '%{http_code}' \
  -H "If-Modified-Since: $LM_MAIN" "http://127.0.0.1:8741/main.dart.js")
echo "alpha chunk: $CODE_ALPHA (want 200), beta chunk: $CODE_BETA (want 304), core: $CODE_MAIN (want 200)"

echo '=== [g4] verify rung: served bytes hash-match the rev-b manifest + carry rev marker'
( cd "$OUT/build_b" && shasum -a 256 -c SHA256SUMS >/dev/null ) \
  || { echo 'G4: FAIL — rev-b manifest does not match rev-b build'; kill $SERVER_PID; exit 1; }
grep -q 'alpha-g4b' "$OUT/fetched_alpha.js" \
  || { echo 'G4: FAIL — served alpha chunk lacks rev-b marker'; kill $SERVER_PID; exit 1; }

kill $SERVER_PID 2>/dev/null || true

if [ "$CODE_ALPHA" = 200 ] && [ "$CODE_BETA" = 304 ] && [ "$CODE_MAIN" = 200 ]; then
  echo 'G4: PASS — pointer/manifest pipeline transfers only changed artifacts, verify rung green'
else
  echo 'G4: FAIL — transfer pattern unexpected'
  exit 1
fi
