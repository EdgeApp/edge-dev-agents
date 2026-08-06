#!/usr/bin/env bash
# harvest-flow-proposals.sh — zero-LLM sweep feeding eval-run's flow
# consolidation, so flow capture stops gating on the eval backlog.
#
# Two passes, both idempotent:
#   1. TRANSCRIPT YAML  re-harvest maestro yaml (inline MCP `yaml:` payloads and
#      Write-tool .yaml creations) from Claude transcripts newer than the
#      corpus's last harvest into ~/maestro-flow-corpus/flows/ + index.tsv
#      (same columns as the 2026-07-24 one-off: content-hash, session, kind,
#      filename, first action line). Dedup by content hash.
#   2. REPORT TAGS  sweep agent-run-report attachments on tasks the orch ran
#      (gids from the watcher's versions/ stamps) for [playbook] / [flow] /
#      [flow-update] bullets, into ~/maestro-flow-corpus/proposals/<gid>.md
#      plus proposals/index.tsv (gid, tag, first line). Tasks are re-fetched
#      only when a newer report attachment exists than the saved copy.
#
# Usage: harvest-flow-proposals.sh [--days N]   (default 14; transcript window)
# Read-only outside ~/maestro-flow-corpus. Safe to re-run; safe while sessions
# run (writes only corpus files, single flat dir).
set -euo pipefail

DAYS=14
while [ $# -gt 0 ]; do case "$1" in
  --days) DAYS="$2"; shift 2 ;;
  *) echo "usage: harvest-flow-proposals.sh [--days N]" >&2; exit 2 ;;
esac; done

CORPUS="$HOME/maestro-flow-corpus"
mkdir -p "$CORPUS/flows" "$CORPUS/proposals"
INDEX="$CORPUS/index.tsv"
touch "$INDEX"

# ---- pass 1: transcript yaml ------------------------------------------------
NEW_FLOWS=0 NEW_OCC=0
while IFS= read -r f; do
  sess=$(basename "$f" .jsonl | cut -c1-8)
  # Extract candidate yaml payloads with node (JSONL-safe; bash regex is not).
  # Emits base64 chunks: KIND<TAB>NAME<TAB>B64 per flow.
  node -e '
    const fs = require("fs")
    const lines = fs.readFileSync(process.argv[1], "utf8").split("\n")
    const out = []
    for (const l of lines) {
      if (!l.includes("yaml")) continue
      let j; try { j = JSON.parse(l) } catch { continue }
      const content = j?.message?.content
      if (!Array.isArray(content)) continue
      for (const c of content) {
        if (c?.type !== "tool_use") continue
        // inline probes under 3 lines are single-tap pokes, not reusable flows
        if (/^mcp__maestro__/.test(c.name || "") && typeof c.input?.yaml === "string" && c.input.yaml.trim().split("\n").length >= 3) {
          out.push(["inline", "inline.yaml", Buffer.from(c.input.yaml).toString("base64")])
        } else if (c.name === "Write" && /\.ya?ml$/.test(c.input?.file_path || "") && typeof c.input?.content === "string") {
          const body = c.input.content
          if (/tapOn|launchApp|runFlow|assertVisible|inputText/.test(body))
            out.push(["file", require("path").basename(c.input.file_path), Buffer.from(body).toString("base64")])
        }
      }
    }
    console.log(out.map(r => r.join("\t")).join("\n"))
  ' "$f" 2>/dev/null | while IFS=$'\t' read -r kind name b64; do
    [ -n "${b64:-}" ] || continue
    body=$(printf '%s' "$b64" | base64 -d 2>/dev/null) || continue
    hash=$(printf '%s' "$body" | shasum -a 256 | cut -c1-12)
    first=$(printf '%s' "$body" | grep -m1 -E '^- ' || printf '%s' "$body" | sed -n '1p')
    if ! grep -q "^$hash	" "$INDEX"; then
      printf '%s' "$body" > "$CORPUS/flows/$hash-$name"
      NEW_FLOWS=$((NEW_FLOWS+1))
    fi
    if ! grep -qE "^$hash	$sess	" "$INDEX"; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$hash" "$sess" "$kind" "$name" "$first" >> "$INDEX"
      echo "OCC"
    fi
  done | grep -c OCC | { read -r n; NEW_OCC=$((NEW_OCC + n)); } || true
done < <(find "$HOME/.claude/projects" -name "*.jsonl" -mtime "-$DAYS" -size +50k 2>/dev/null)
# Recount from the index (subshell counters do not propagate).
TOTAL_FLOWS=$(ls "$CORPUS/flows" | wc -l | tr -d ' ')
TOTAL_OCC=$(wc -l < "$INDEX" | tr -d ' ')

# ---- pass 2: report tags ----------------------------------------------------
TOKEN="${ASANA_TOKEN:-$(jq -r '.asana_token // empty' "$HOME/.config/agent-watcher/credentials.json" 2>/dev/null)}"
PIDX="$CORPUS/proposals/index.tsv"
touch "$PIDX"
NEW_PROPS=0
if [ -n "$TOKEN" ]; then
  for vf in "${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/versions"/*.jsonl; do
    [ -f "$vf" ] || continue
    gid=$(basename "$vf" .jsonl)
    resp=$(curl -sf --max-time 20 \
      "https://app.asana.com/api/1.0/tasks/$gid/attachments?opt_fields=name,created_at,download_url" \
      -H "Authorization: Bearer $TOKEN" 2>/dev/null) || continue
    read -r url created < <(echo "$resp" | jq -r '[.data[] | select(.name | startswith("agent-run-report"))] | sort_by(.created_at) | last | "\(.download_url) \(.created_at)"' 2>/dev/null) || true
    [ -n "${url:-}" ] && [ "$url" != "null" ] || continue
    out="$CORPUS/proposals/$gid.md"
    # skip when we already harvested this attachment vintage
    if [ -f "$out" ] && grep -qF "harvested-from: $created" "$out"; then continue; fi
    report=$(curl -sfL --max-time 30 "$url" 2>/dev/null) || continue
    # tagged bullets + their continuation lines (indented or fenced yaml)
    tagged=$(printf '%s\n' "$report" | awk '
      /^[-*] *`?\[(playbook|flow|flow-update)\]`?/ { grab=1; print; next }
      grab && (/^[[:space:]]/ || /^```/) { print; if (/^```$/ && fence) { grab=0; fence=0 }; if (/^```/ && !/^```$/) fence=1; next }
      grab { grab=0 }
    ')
    [ -n "$tagged" ] || { printf '<!-- harvested-from: %s -->\n<!-- no tagged bullets -->\n' "$created" > "$out"; continue; }
    { printf '<!-- harvested-from: %s -->\n# %s\n\n%s\n' "$created" "$gid" "$tagged"; } > "$out"
    printf '%s\n' "$tagged" | grep -E '^[-*] *`?\[' | while IFS= read -r line; do
      tag=$(printf '%s' "$line" | sed -E 's/^[-*] *\[([a-z-]+)\].*/\1/')
      printf '%s\t%s\t%s\n' "$gid" "$tag" "$(printf '%s' "$line" | cut -c1-120)" >> "$PIDX"
    done
    NEW_PROPS=$((NEW_PROPS+1))
  done
  sort -u "$PIDX" -o "$PIDX"
else
  echo "WARN: no ASANA_TOKEN — report-tag pass skipped" >&2
fi

echo "HARVEST_OK flows_total=$TOTAL_FLOWS occurrences_total=$TOTAL_OCC reports_updated=$NEW_PROPS proposals_index=$(wc -l < "$PIDX" | tr -d ' ')"
