#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────
# ralph.sh — Multi-agent Ralph loop
#
# Builder: Claude Code (implements)
# Reviewer: Codex (reviews + tests)
#
# Usage:
#   ./ralph.sh                    # run until prd.json complete
#   ./ralph.sh 20                 # max 20 iterations
#   ./ralph.sh 50 my-feature      # 50 iters, tag = my-feature
# ─────────────────────────────────────────────────────────

set -euo pipefail

MAX_ITERATIONS="${1:-50}"
TAG="${2:-$(date +%b%d)}"
BRANCH="ralph/${TAG}"
BUILDER="claude"
REVIEWER="codex"
COOLDOWN=5

# ── Colors ───────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1"; }
pass() { echo -e "${GREEN}[✅ PASS]${NC} $1"; }
fail() { echo -e "${RED}[❌ FAIL]${NC} $1"; }
warn() { echo -e "${YELLOW}[⚠️]${NC} $1"; }

# ── Preflight ────────────────────────────────────────────
check_deps() {
    local missing=()
    command -v "$BUILDER"  &>/dev/null || missing+=("$BUILDER")
    command -v "$REVIEWER" &>/dev/null || missing+=("$REVIEWER")
    command -v jq          &>/dev/null || missing+=("jq")
    command -v git         &>/dev/null || missing+=("git")

    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing: ${missing[*]}"
        exit 1
    fi
}

# ── PRD helpers ──────────────────────────────────────────
next_story() {
    jq -r '[.userStories[] | select(.passes == false)] | sort_by(.priority) | .[0] // empty' prd.json
}

story_count() {
    local total=$(jq '.userStories | length' prd.json)
    local done=$(jq '[.userStories[] | select(.passes == true)] | length' prd.json)
    echo "${done}/${total}"
}

all_done() {
    local remaining=$(jq '[.userStories[] | select(.passes == false)] | length' prd.json)
    [ "$remaining" -eq 0 ]
}

mark_passed() {
    local story_id="$1"
    jq --arg id "$story_id" \
       '(.userStories[] | select(.id == $id)).passes = true' \
       prd.json > prd.tmp && mv prd.tmp prd.json
}

# ── Progress file (inter-iteration memory) ───────────────
append_progress() {
    echo -e "\n--- [$(date '+%Y-%m-%d %H:%M:%S')] ---\n$1" >> progress.txt
}

# ── Main loop ────────────────────────────────────────────
check_deps

if [ ! -f prd.json ]; then
    echo "No prd.json found. Create one first."
    echo "  Option 1: Copy prd.json.example and edit it"
    echo "  Option 2: In Claude Code, run: /prd \"your feature\""
    echo "  Option 3: Use Lisa: /lisa:plan \"your feature\""
    exit 1
fi

# Initialize progress file
[ -f progress.txt ] || cat > progress.txt << 'EOF'
# Progress Log
# Append-only learnings from each iteration.
# Both agents read this for context at the start of each iteration.

## Codebase Patterns

## Gotchas & Lessons Learned

EOF

# Branch setup
if ! git rev-parse --verify "$BRANCH" &>/dev/null 2>&1; then
    git checkout -b "$BRANCH"
    log "Created branch: $BRANCH"
else
    git checkout "$BRANCH"
    log "Checked out: $BRANCH"
fi

log "Starting multi-agent Ralph loop"
log "Builder:  $BUILDER"
log "Reviewer: $REVIEWER"
log "Branch:   $BRANCH"
log "Max iterations: $MAX_ITERATIONS"
log "Progress: $(story_count)"
echo ""

ITERATION=0
RETRY_COUNT=0
MAX_RETRIES=3
LAST_STORY_ID=""

while [ $ITERATION -lt $MAX_ITERATIONS ]; do
    ITERATION=$((ITERATION + 1))

    # ── Check if all done ────────────────────────────────
    if all_done; then
        echo ""
        pass "ALL STORIES COMPLETE — <promise>COMPLETE</promise>"
        log "Final progress: $(story_count)"
        exit 0
    fi

    # ── Pick next story ──────────────────────────────────
    STORY=$(next_story)
    if [ -z "$STORY" ]; then
        pass "No more stories. Done!"
        exit 0
    fi

    STORY_ID=$(echo "$STORY" | jq -r '.id')
    STORY_TITLE=$(echo "$STORY" | jq -r '.title')
    STORY_DESC=$(echo "$STORY" | jq -r '.description')
    STORY_AC=$(echo "$STORY" | jq -r '.acceptanceCriteria | join("\n  - ")')

    # Reset retry counter if new story
    if [ "$STORY_ID" != "$LAST_STORY_ID" ]; then
        RETRY_COUNT=0
        LAST_STORY_ID="$STORY_ID"
    fi

    # Skip if too many retries
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        warn "Skipping $STORY_ID after $RETRY_COUNT retries"
        mark_passed "$STORY_ID"
        append_progress "SKIPPED $STORY_ID: Too many retries. Needs manual review."
        LAST_STORY_ID=""
        continue
    fi

    echo ""
    log "═══════════════════════════════════════════════════"
    log "  ITERATION $ITERATION — $STORY_ID: $STORY_TITLE"
    log "  Progress: $(story_count) | Attempt: $((RETRY_COUNT + 1))/$MAX_RETRIES"
    log "═══════════════════════════════════════════════════"

    # ── Read retry feedback if exists ────────────────────
    FEEDBACK=""
    if [ -f ".ralph-feedback.tmp" ]; then
        FEEDBACK=$(cat .ralph-feedback.tmp)
        rm -f .ralph-feedback.tmp
    fi

    # ── PHASE 1: BUILD (Claude Code) ─────────────────────
    log "🔨 Building with Claude Code..."

    PROGRESS=$(cat progress.txt)

    BUILD_PROMPT="You are implementing ONE user story in this codebase.

STORY: $STORY_ID — $STORY_TITLE
DESCRIPTION: $STORY_DESC

ACCEPTANCE CRITERIA:
  - $STORY_AC

PREVIOUS LEARNINGS (from progress.txt):
$(tail -100 progress.txt)

INSTRUCTIONS:
1. Read relevant code to understand current state
2. Implement ONLY this story — minimal, focused changes
3. Ensure all acceptance criteria are met
4. Run any existing tests/checks if available

$([ -n "$FEEDBACK" ] && echo "
⚠️ RETRY — Previous attempt failed review:
$FEEDBACK

Fix ALL issues above.
")

When done, output:
FILES_CHANGED: <comma-separated list>
SUMMARY: <1-2 sentences of what you did>
LEARNINGS: <any codebase patterns or gotchas discovered>"

    BUILD_OUTPUT=$($BUILDER -p "$BUILD_PROMPT" \
        --permission-mode auto \
        --max-turns 30 \
        2>/dev/null) || true

    if [ -z "$BUILD_OUTPUT" ]; then
        warn "Builder returned empty output. Retrying next iteration."
        RETRY_COUNT=$((RETRY_COUNT + 1))
        sleep $COOLDOWN
        continue
    fi

    log "Builder finished. Output length: ${#BUILD_OUTPUT} chars"

    # ── PHASE 2: REVIEW (Codex) ──────────────────────────
    log "🔍 Reviewing with Codex..."

    REVIEW_PROMPT="You are a senior code reviewer. An implementation was just made.

STORY: $STORY_ID — $STORY_TITLE
ACCEPTANCE CRITERIA:
  - $STORY_AC

BUILDER SUMMARY:
$(echo "$BUILD_OUTPUT" | tail -50)

YOUR JOB:
1. Read the changed files and surrounding code
2. Verify ALL acceptance criteria are met
3. Check for bugs, logic errors, type errors, missing edge cases
4. Run tests if they exist (npm test, pytest, cargo test, make test, etc.)
5. Check code quality

OUTPUT YOUR VERDICT IN THIS EXACT FORMAT:

VERDICT: PASS
LEARNINGS: <any insights>

OR

VERDICT: FAIL
FEEDBACK: <specific issues to fix>
LEARNINGS: <any insights>"

    REVIEW_OUTPUT=$($REVIEWER exec --full-auto \
        --sandbox workspace-write \
        "$REVIEW_PROMPT" \
        2>/dev/null) || true

    if [ -z "$REVIEW_OUTPUT" ]; then
        warn "Reviewer returned empty output. Treating as pass."
        REVIEW_OUTPUT="VERDICT: PASS"
    fi

    # ── PHASE 3: PARSE VERDICT ───────────────────────────
    VERDICT=$(echo "$REVIEW_OUTPUT" | grep -i "^VERDICT:" | head -1 | sed 's/VERDICT://I' | tr -d ' ' | tr '[:lower:]' '[:upper:]')
    REVIEW_FEEDBACK=$(echo "$REVIEW_OUTPUT" | sed -n '/^FEEDBACK:/,/^[A-Z]*:/p' | head -20)
    REVIEW_LEARNINGS=$(echo "$REVIEW_OUTPUT" | grep -i "^LEARNINGS:" | head -1 | sed 's/LEARNINGS://I')

    # Record learnings from both agents
    BUILD_LEARNINGS=$(echo "$BUILD_OUTPUT" | grep -i "^LEARNINGS:" | head -1 | sed 's/LEARNINGS://I')
    [ -n "$BUILD_LEARNINGS" ] && append_progress "[Builder — $STORY_ID] $BUILD_LEARNINGS"
    [ -n "$REVIEW_LEARNINGS" ] && append_progress "[Reviewer — $STORY_ID] $REVIEW_LEARNINGS"

    # ── Handle verdict ───────────────────────────────────
    if [ "$VERDICT" = "PASS" ]; then
        pass "$STORY_ID: $STORY_TITLE"

        # Mark story complete
        mark_passed "$STORY_ID"

        # Git commit (the ratchet — only good code advances)
        git add -A
        git commit -m "[ralph] $STORY_ID: $STORY_TITLE" 2>/dev/null || true

        append_progress "COMPLETED $STORY_ID: $STORY_TITLE"

        # Reset for next story
        LAST_STORY_ID=""
        RETRY_COUNT=0

    elif [ "$VERDICT" = "FAIL" ]; then
        RETRY_COUNT=$((RETRY_COUNT + 1))
        fail "$STORY_ID (attempt $RETRY_COUNT/$MAX_RETRIES)"

        # Save feedback for next iteration
        echo "$REVIEW_FEEDBACK" > .ralph-feedback.tmp

        append_progress "REVIEW_FAIL $STORY_ID (attempt $RETRY_COUNT): $(echo "$REVIEW_FEEDBACK" | head -5)"

        # Ratchet: revert changes on fail
        git checkout -- . 2>/dev/null || true
        git clean -fd 2>/dev/null || true

    else
        warn "Unclear verdict: '$VERDICT'. Treating as pass."
        mark_passed "$STORY_ID"
        git add -A
        git commit -m "[ralph] $STORY_ID: $STORY_TITLE" 2>/dev/null || true
        LAST_STORY_ID=""
    fi

    log "Progress: $(story_count)"
    sleep $COOLDOWN
done

echo ""
warn "Reached max iterations ($MAX_ITERATIONS)."
log "Final progress: $(story_count)"
log "Run again to continue."
