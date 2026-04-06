#!/bin/bash
# UserPromptSubmit hook — detect pending OneZero1 matches and inject triage context
#
# Install: add to ~/.claude/settings.json hooks.UserPromptSubmit
# The server.ts writes pending-matches.jsonl when introduction messages arrive.
# This hook reads that file and injects triage instructions into the next prompt.

CONFIG_DIR="${ONEZERO1_CONFIG_DIR:-$HOME/.onezero1}"
PENDING_FILE="$CONFIG_DIR/pending-matches.jsonl"

[[ -f "$PENDING_FILE" ]] || exit 0
[[ -s "$PENDING_FILE" ]] || exit 0

# Rate limit: don't inject more than once per 60 seconds
RATE_FILE="$CONFIG_DIR/.last-triage-inject-ts"
NOW=$(date +%s)
if [[ -f "$RATE_FILE" ]]; then
  LAST=$(cat "$RATE_FILE" 2>/dev/null || echo 0)
  DIFF=$((NOW - LAST))
  [[ $DIFF -lt 60 ]] && exit 0
fi

COUNT=$(wc -l < "$PENDING_FILE" | tr -d ' ')
[[ "$COUNT" -eq 0 ]] && exit 0

MATCHES_JSON=$(PENDING_FILE="$PENDING_FILE" python3 <<'PYEOF'
import json, sys, os

pending_file = os.environ.get('PENDING_FILE', '')
if not pending_file: sys.exit(0)

matches = []
try:
    with open(pending_file) as f:
        for line in f:
            line = line.strip()
            if line:
                try: matches.append(json.loads(line))
                except: pass
except FileNotFoundError: sys.exit(0)
if not matches: sys.exit(0)

triage_blocks = []
for m in matches:
    block = f"""## Pending Match: {m.get('from', 'unknown')}
- **Subject**: {m.get('subject', '')}
- **Message ID**: {m.get('message_id', '')}
- **From ID**: {m.get('from_id', '')}
- **Content**: {m.get('content', '')[:500]}

Spawn a background triage agent for this match. Score (domain/tech/problem 0-3).
>= 7: ENGAGE (auto-reply). 4-6: BOOKMARK. <= 3: SKIP."""
    triage_blocks.append(block)

print(json.dumps({
    "type": "onezero1_pending_matches",
    "count": len(matches),
    "instruction": "Pending OneZero1 matches need triage. Spawn a background Agent for each. Read CLAUDE.md + gh issue list for context.",
    "matches": triage_blocks
}))
PYEOF
)

if [[ -n "$MATCHES_JSON" && "$MATCHES_JSON" != "null" ]]; then
  # Archive processed matches
  cat "$PENDING_FILE" >> "$CONFIG_DIR/processed-matches.jsonl" 2>/dev/null
  rm -f "$PENDING_FILE"
  echo "$NOW" > "$RATE_FILE"
  echo "$MATCHES_JSON"
fi
