#!/usr/bin/env bash
# asana-get-context.sh
# Fetch concise context from an Asana task for implementation or PR creation.
#
# Usage:
#   asana-get-context.sh <task_gid_or_url>
#   asana-get-context.sh --task-url <url>
#   asana-get-context.sh --task <task_gid>
#
# Accepts a raw task GID or a full Asana URL. URL formats supported:
#   https://app.asana.com/0/<project_gid>/<task_gid>[/f]
#   https://app.asana.com/1/<project_gid>/task/<task_gid>[/f]
#
# Requires env var: ASANA_TOKEN
#
# Output (compact, agent-friendly):
#   TASK_NAME: <name>
#   TASK_DESCRIPTION: <notes, full text; over TEXT_CEILING chars it is cut with a
#                     marker naming the total size and the full-text file>
#   PRIORITY: <value>
#   STATUS: <value>
#   IMPLEMENTOR: <name>
#   REVIEWER: <name>
#   COMMENTS: <count> (ALL comments, oldest first, full text; newest kept inline
#             when the thread exceeds TEXT_CEILING, older ones elided with a marker
#             pointing at the full-thread file)
#   PARENT: <gid> <name>                           [if task has a parent]
#   SUBTASKS: <count>                              [if any; then per subtask a "<gid> [open|done] <name>" line + an indented "DESC: <notes>" line (eager body, truncated)]
#   DEPENDENCIES: / DEPENDENTS:                    [if any; same per-line format]
#   DESCRIPTION_FILE: / COMMENTS_FILE: <path>   [always; full text on disk for grep/Read]
#   ATTACHMENTS: <count> files
#   DOWNLOADED: <count> files to <dir>
#   UNPACKED: <zip> -> <dir> (<count> files)     [if ZIPs present]
#   PDF_TEXT: <path> (from <file>, <chars> chars)  [if PDF has text]
#   PDF_PAGES: <dir> (<count> pages from <file>)   [if PDF is image-based]
#   RTF_TEXT: <path> (from <file>, <chars> chars)  [if RTFs present]
set -euo pipefail

# Parse arguments: accept positional, --task, or --task-url
RAW_INPUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-url|--task)
      RAW_INPUT="${2:-}"
      shift 2
      ;;
    -*)
      echo "Unknown flag: $1" >&2
      exit 1
      ;;
    *)
      RAW_INPUT="$1"
      shift
      ;;
  esac
done

if [[ -z "$RAW_INPUT" ]]; then
  echo "Usage: asana-get-context.sh <task_gid_or_url>" >&2
  exit 1
fi

# Extract task GID: accept a raw numeric GID or any Asana URL containing one.
# Strips trailing path segments (/f, /subtask/…) and query strings.
if [[ "$RAW_INPUT" =~ /task/([0-9]+) ]]; then
  TASK_GID="${BASH_REMATCH[1]}"
elif [[ "$RAW_INPUT" =~ /([0-9]+)(/f)?([?#].*)?$ ]]; then
  TASK_GID="${BASH_REMATCH[1]}"
elif [[ "$RAW_INPUT" =~ ^[0-9]+$ ]]; then
  TASK_GID="$RAW_INPUT"
else
  echo "Error: could not extract task GID from: $RAW_INPUT" >&2
  exit 1
fi
# Token: prefer $ASANA_TOKEN, else fall back to credentials.json (.asana_token),
# the same source update-status.sh uses — spawned agent shells lack the env var.
if [[ -z "${ASANA_TOKEN:-}" ]]; then
  CRED="$HOME/.config/agent-watcher/credentials.json"
  [[ -f "$CRED" ]] && ASANA_TOKEN="$(jq -r '.asana_token // empty' "$CRED" 2>/dev/null)"
fi
if [[ -z "${ASANA_TOKEN:-}" ]]; then
  echo "Error: ASANA_TOKEN not set and not found in credentials.json (.asana_token)" >&2
  exit 1
fi

API="https://app.asana.com/api/1.0"
AUTH="Authorization: Bearer $ASANA_TOKEN"
DOWNLOAD_DIR="/tmp/asana-task-$TASK_GID"
mkdir -p "$DOWNLOAD_DIR"
# Inline text ceiling. Task text is ingested in FULL (a capped description or
# comment is the top cause of runs planning from a partial spec and hand-rolling
# raw API fetches to recover the rest). The ceiling only guards against a pasted
# log dump; the full text is always on disk regardless.
TEXT_CEILING="${ASANA_TEXT_CEILING:-60000}"

# Fetch task + custom fields + relationship pointers. Parent/dependencies/
# dependents ride the same call. Pointers are gid + state + name ONLY — this
# script never fetches related-task content and never recurses; the calling
# skill decides what (if anything) to walk.
TASK_JSON=$(curl -s "$API/tasks/$TASK_GID?opt_fields=name,notes,num_subtasks,parent.name,dependencies.name,dependencies.completed,dependents.name,dependents.completed,custom_fields.gid,custom_fields.name,custom_fields.display_value" \
  -H "$AUTH")
printf '%s' "$TASK_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)['data']

print(f\"TASK_NAME: {data['name']}\")

notes = (data.get('notes') or '').strip()
ceiling = int('$TEXT_CEILING')
desc_path = '$DOWNLOAD_DIR/description.txt'
with open(desc_path, 'w') as fh:
    fh.write(notes)
if len(notes) > ceiling:
    notes = notes[:ceiling] + f\"\\n[TRUNCATED at {ceiling} of {len(notes)} chars; full text: {desc_path}]\"
print(f\"TASK_DESCRIPTION: {notes or '(empty)'}\")
print(f\"DESCRIPTION_FILE: {desc_path}\")

FIELDS = {
    '795866930204488': 'PRIORITY',
    '1190660107346181': 'STATUS',
    '1203334386796983': 'IMPLEMENTOR',
    '1203334388004673': 'REVIEWER',
    '1213939602865824': 'RELEASE',   # Release (4.x.x): CHANGELOG placement signal
    '1213928707858644': 'BUILD',     # Build (staging/cheese): placement + routing
}
for f in data.get('custom_fields', []):
    label = FIELDS.get(f['gid'])
    if label:
        val = f.get('display_value') or '(not set)'
        print(f'{label}: {val}')

# Relationship pointers — lines omitted entirely when empty so the common
# single-task case adds zero output.
parent = data.get('parent')
if parent:
    print(f\"PARENT: {parent['gid']} {(parent.get('name') or '')[:80]}\")
for label, key in (('DEPENDENCIES', 'dependencies'), ('DEPENDENTS', 'dependents')):
    rows = data.get(key) or []
    if rows:
        print(f'{label}:')
        for t in rows:
            state = 'done' if t.get('completed') else 'open'
            print(f\"  {t['gid']} [{state}] {(t.get('name') or '')[:80]}\")
"

# Subtasks (separate endpoint). Skipped entirely when the task has none. Bodies are
# fetched EAGERLY (notes inline via opt_fields, one call, no extra round-trips) because
# subtasks hold split-out requirements/context for related (often other-repo) work — the
# active run needs them, not just the pointer. Each DESC is truncated with the gid to walk
# via asana-get-context.sh for the full content (comments/attachments/nested subtasks).
SUBTASK_COUNT=$(printf '%s' "$TASK_JSON" | python3 -c "import sys, json; print(json.load(sys.stdin)['data'].get('num_subtasks') or 0)")
if [[ "$SUBTASK_COUNT" -gt 0 ]]; then
  curl -s "$API/tasks/$TASK_GID/subtasks?opt_fields=name,completed,notes" \
    -H "$AUTH" | python3 -c "
import sys, json
rows = json.load(sys.stdin)['data']
if rows:
    print(f'SUBTASKS: {len(rows)}')
    for t in rows:
        state = 'done' if t.get('completed') else 'open'
        print(f\"  {t['gid']} [{state}] {(t.get('name') or '')[:80]}\")
        notes = (t.get('notes') or '').strip().replace('\n', ' ')
        if notes:
            if len(notes) > 1000:
                notes = notes[:1000] + f\"... (truncated; asana-get-context.sh {t['gid']} for full)\"
            print(f'    DESC: {notes}')
"
fi

# Comments: ALL of them, oldest first, full text. Newlines inside a comment are
# kept (continuation lines indented) so bullet lists written by the operator
# survive. The full thread is always written to COMMENTS_FILE; when the inline
# thread would exceed TEXT_CEILING the OLDEST comments are elided first, since
# followup scope lives in the newest ones.
curl -s "$API/tasks/$TASK_GID/stories?opt_fields=resource_subtype,text,created_by.name,created_at&limit=100" \
  -H "$AUTH" | python3 -c "
import sys, json
data = json.load(sys.stdin)['data']
comments = [s for s in data if s.get('resource_subtype') == 'comment_added']
ceiling = int('$TEXT_CEILING')
path = '$DOWNLOAD_DIR/comments.txt'
def fmt(c):
    author = (c.get('created_by') or {}).get('name', 'unknown')
    text = (c.get('text') or '').strip().replace('\\n', '\\n    ')
    date = c.get('created_at', '')[:10]
    return f'  [{date}] {author}: {text}'
blocks = [fmt(c) for c in comments]
with open(path, 'w') as fh:
    fh.write('\\n'.join(blocks))
if not comments:
    print('COMMENTS: (none)')
else:
    total = sum(len(b) for b in blocks)
    keep = blocks
    omitted = 0
    if total > ceiling:
        keep, used = [], 0
        for b in reversed(blocks):
            if used + len(b) > ceiling: break
            keep.insert(0, b); used += len(b)
        omitted = len(blocks) - len(keep)
    print(f'COMMENTS: {len(comments)}')
    if omitted:
        print(f'  [{omitted} older comment(s), {total - sum(len(b) for b in keep)} chars, elided; full thread: {path}]')
    for b in keep:
        print(b)
print(f'COMMENTS_FILE: {path}')
"

# Fetch attachments — download all supported types, then post-process

# Ingestion marker, written UNCONDITIONALLY (attachments or not): proof this
# script ran for the gid. require-plan-before-developing.sh gates the
# Developing transition on it — a run that hand-rolls its own task fetch
# (raw curl with notes-only opt_fields) never sees attachments and never
# writes this marker (2026-08-24, task 1217796671374968: planned from a
# one-line notes field while two repro screenshots sat on the task).
date -u +%Y-%m-%dT%H:%M:%SZ > "$DOWNLOAD_DIR/.context-fetched"

# Phase 1: Download all supported attachments
curl -s "$API/tasks/$TASK_GID/attachments?opt_fields=name,resource_subtype,download_url" \
  -H "$AUTH" | python3 -c "
import sys, json, os, urllib.request

data = json.load(sys.stdin)['data']
if not data:
    print('ATTACHMENTS: (none)')
    sys.exit(0)

DOWNLOAD_EXTS = {
    '.md', '.txt', '.json', '.csv', '.log', '.yaml', '.yml',
    '.pdf',
    '.rtf',
    '.zip',
    '.png', '.jpg', '.jpeg', '.gif', '.webp',
}
download_dir = '$DOWNLOAD_DIR'
downloaded = []

print(f'ATTACHMENTS: {len(data)} files')
for a in data:
    name = a.get('name', 'unnamed')
    url = a.get('download_url')
    ext = os.path.splitext(name)[1].lower()
    if ext in DOWNLOAD_EXTS and url:
        os.makedirs(download_dir, exist_ok=True)
        dest = os.path.join(download_dir, name)
        try:
            urllib.request.urlretrieve(url, dest)
            downloaded.append(dest)
            print(f'  - {name} (downloaded)')
        except Exception as e:
            print(f'  - {name} (download failed: {e})')
    else:
        print(f'  - {name}')

if downloaded:
    print(f'DOWNLOADED: {len(downloaded)} files to {download_dir}')
    for d in downloaded:
        print(f'  {d}')
"

# Phase 2: Unpack ZIP archives (may produce more files to process)
shopt -s nullglob
for zip_file in "$DOWNLOAD_DIR"/*.zip; do
  subdir="$DOWNLOAD_DIR/$(basename "$zip_file" .zip)"
  if unzip -o -q "$zip_file" -d "$subdir" 2>/dev/null; then
    file_count=$(find "$subdir" -type f 2>/dev/null | wc -l | tr -d ' ')
    echo "UNPACKED: $(basename "$zip_file") -> $subdir ($file_count files)"
    rm "$zip_file"
  else
    echo "UNPACK_FAILED: $(basename "$zip_file")"
  fi
done
shopt -u nullglob

# Phase 3: Process PDFs (text extraction first, image fallback)
process_pdf() {
  local pdf="$1"
  local base="${pdf%.pdf}"
  local fname
  fname="$(basename "$pdf")"

  if command -v pdftotext &>/dev/null; then
    local text
    text=$(pdftotext "$pdf" - 2>/dev/null || true)
    local char_count
    char_count=$(printf '%s' "$text" | tr -d '[:space:]' | wc -c | tr -d ' ')
    if [[ "$char_count" -gt 100 ]]; then
      printf '%s' "$text" > "${base}.txt"
      echo "PDF_TEXT: ${base}.txt (from $fname, ${char_count} chars)"
      return
    fi
  fi

  if command -v pdftoppm &>/dev/null; then
    local pages_dir="${base}_pages"
    mkdir -p "$pages_dir"
    pdftoppm -png -r 150 "$pdf" "$pages_dir/page" 2>/dev/null
    local page_count
    page_count=$(find "$pages_dir" -name 'page-*.png' 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$page_count" -gt 0 ]]; then
      echo "PDF_PAGES: $pages_dir ($page_count pages from $fname)"
    else
      echo "PDF_CONVERT_FAILED: $fname"
    fi
  else
    echo "PDF_SKIPPED: $fname (install poppler-utils for text/image extraction)"
  fi
}

if [[ -d "$DOWNLOAD_DIR" ]]; then
  while IFS= read -r pdf; do
    process_pdf "$pdf"
  done < <(find "$DOWNLOAD_DIR" -name '*.pdf' -type f 2>/dev/null)
fi

# Phase 4: Convert RTFs to plain text (macOS textutil)
process_rtf() {
  local rtf="$1"
  local base="${rtf%.rtf}"
  local fname
  fname="$(basename "$rtf")"

  if command -v textutil &>/dev/null; then
    if textutil -convert txt "$rtf" -output "${base}.txt" 2>/dev/null; then
      local char_count
      char_count=$(wc -c < "${base}.txt" | tr -d ' ')
      echo "RTF_TEXT: ${base}.txt (from $fname, ${char_count} chars)"
    else
      echo "RTF_CONVERT_FAILED: $fname"
    fi
  else
    echo "RTF_SKIPPED: $fname (textutil not available)"
  fi
}

if [[ -d "$DOWNLOAD_DIR" ]]; then
  while IFS= read -r rtf; do
    process_rtf "$rtf"
  done < <(find "$DOWNLOAD_DIR" -name '*.rtf' -type f 2>/dev/null)
fi
