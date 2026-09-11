#!/usr/bin/env bash
# mermaid-png.sh — render one mermaid diagram to a PNG that any viewer shows
# inline (the Claude Code desktop markdown viewer does not render mermaid
# fences, so a CLI session sends the picture, not the source).
# Usage: mermaid-png.sh <diagram.md | diagram.mmd> [out.png]
#   .md  : the FIRST ```mermaid fence is rendered
#   .mmd : the whole file is the diagram
#   out  : default <input basename>.png next to the input
# Prints the PNG path. Rendering: headless Chrome (Google Chrome.app, else the
# Playwright chromium under ~/Library/Caches/ms-playwright) over a page that
# inlines mermaid.min.js from ~/.cache/mermaid (fetched from jsdelivr once).
# Two passes: dump the DOM to read the rendered SVG's size, then screenshot at
# that size (2x scale) so the image is cropped to the diagram. A diagram that
# fails to render leaves the mermaid error text in the PNG; exit 1 then, and
# exit 2 when no browser or library is available.
set -euo pipefail
IN="${1:?diagram file}"; OUT="${2:-${IN%.*}.png}"
[ -r "$IN" ] || { echo "mermaid-png: cannot read $IN" >&2; exit 1; }
CACHE="${MERMAID_CACHE:-$HOME/.cache/mermaid}"; LIB="$CACHE/mermaid.min.js"
if [ ! -s "$LIB" ] || [ "$(wc -c <"$LIB")" -lt 100000 ]; then
  mkdir -p "$CACHE"
  curl -fsSL -o "$LIB" "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js" || { echo "mermaid-png: could not fetch mermaid.min.js" >&2; exit 2; }
fi
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ ! -x "$CHROME" ]; then
  CHROME=$(ls -d "$HOME"/Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-mac*/chrome-headless-shell 2>/dev/null | tail -1 || true)
  [ -n "$CHROME" ] && [ -x "$CHROME" ] || { echo "mermaid-png: no headless browser (Google Chrome or Playwright chromium)" >&2; exit 2; }
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mermaid-png.XXXXXX"); trap "rm -rf '$WORK'" EXIT
node -e '
  const fs=require("fs"); const [inp,lib,out]=process.argv.slice(1);
  let src=fs.readFileSync(inp,"utf8");
  if(/\.md$/i.test(inp)){ const m=src.match(/```mermaid[^\n]*\n([\s\S]*?)```/); if(!m){console.error("mermaid-png: no ```mermaid fence in "+inp);process.exit(1)} src=m[1]; }
  const esc=src.replace(/&/g,"&amp;").replace(/</g,"&lt;");
  fs.writeFileSync(out,`<!doctype html><meta charset="utf-8"><body style="margin:0;background:#fff"><div id="w" style="display:inline-block;padding:16px"><pre class="mermaid" style="margin:0">${esc}</pre></div><script>${fs.readFileSync(lib,"utf8")}</script><script>mermaid.initialize({startOnLoad:true,theme:"neutral",flowchart:{useMaxWidth:false},sequence:{useMaxWidth:false},gantt:{useMaxWidth:false}});</script></body>`);
' "$IN" "$LIB" "$WORK/d.html"
# --run-all-compositor-stages-before-draw and a private --user-data-dir both
# hang the --dump-dom pass on Chrome 140; keep the flag set minimal.
FLAGS=(--headless=new --disable-gpu --hide-scrollbars --virtual-time-budget=20000)
DOM=$(timeout 60 "$CHROME" "${FLAGS[@]}" --window-size=4000,4000 --dump-dom "file://$WORK/d.html" 2>/dev/null || true)
# Read the rendered SVG size from the DOM with the inlined library stripped
# (the library source itself contains mermaid's error strings).
SIZE=$(printf '%s' "$DOM" | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    s=s.replace(/<script[\s\S]*?<\/script>/g,"");
    if(/Syntax error in text|aria-roledescription="error"/.test(s)||!/<svg/.test(s)){console.log("ERR");return}
    const m=s.match(/<svg[^>]*viewBox="[^"]*?\s([\d.]+)\s([\d.]+)"/);
    const w=m?Math.ceil(+m[1]):1200, h=m?Math.ceil(+m[2]):800;
    console.log((w+32)+" "+(h+32));
  });')
[ "$SIZE" != "ERR" ] || { echo "mermaid-png: mermaid failed to render $IN (syntax error or empty diagram)" >&2; exit 1; }
read -r W H <<<"$SIZE"
timeout 60 "$CHROME" "${FLAGS[@]}" --force-device-scale-factor=2 --window-size="$W,$H" --screenshot="$OUT" "file://$WORK/d.html" 2>/dev/null
[ -s "$OUT" ] || { echo "mermaid-png: screenshot failed" >&2; exit 1; }
echo "$OUT"
