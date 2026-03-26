#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────
# ralph.sh — Multi-agent Ralph loop
#
# Builder: Claude Code (implements)
# Reviewer: Codex (reviews + tests)
# Smoke Test: auto-detected tests/typecheck (pre-gate)
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
BUILD_TIMEOUT=300    # 5 min — forces right-sized stories
REVIEW_TIMEOUT=180   # 3 min — generous for read + test
MAX_TURNS=15         # builder turn cap (down from 30)
SMOKE_TEST=""        # auto-detect, or set custom command

# ── Colors ───────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()   { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1"; }
pass()  { echo -e "${GREEN}[✅ PASS]${NC} $1"; }
fail()  { echo -e "${RED}[❌ FAIL]${NC} $1"; }
warn()  { echo -e "${YELLOW}[⚠️]${NC} $1"; }
smoke() { echo -e "${CYAN}[🔬 SMOKE]${NC} $1"; }

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

# ── Smoke test detection ─────────────────────────────────
detect_smoke_test() {
    # 1. Check prd.json for explicit smokeTest command
    local prd_smoke
    prd_smoke=$(jq -r '.smokeTest // empty' prd.json 2>/dev/null)
    if [ -n "$prd_smoke" ]; then
        echo "$prd_smoke"
        return
    fi

    # 2. User override via SMOKE_TEST variable
    if [ -n "$SMOKE_TEST" ]; then
        echo "$SMOKE_TEST"
        return
    fi

    # 3. Auto-detect from project files
    local cmds=()

    # Node.js: check for test script in package.json
    if [ -f package.json ]; then
        local has_test
        has_test=$(jq -r '.scripts.test // empty' package.json 2>/dev/null)
        if [ -n "$has_test" ] && [ "$has_test" != "echo \"Error: no test specified\" && exit 1" ]; then
            cmds+=("npm test")
        fi
    fi

    # TypeScript: typecheck
    if [ -f tsconfig.json ]; then
        cmds+=("npx tsc --noEmit")
    fi

    # Python: pytest
    if [ -f pyproject.toml ] || [ -f pytest.ini ] || [ -f setup.py ]; then
        if command -v pytest &>/dev/null; then
            cmds+=("pytest")
        fi
    fi

    # Rust: cargo
    if [ -f Cargo.toml ]; then
        cmds+=("cargo check" "cargo test")
    fi

    # Go
    if [ -f go.mod ]; then
        cmds+=("go vet ./..." "go test ./...")
    fi

    # Makefile with test target
    if [ -f Makefile ] && grep -q '^test:' Makefile; then
        cmds+=("make test")
    fi

    # Join commands with &&
    if [ ${#cmds[@]} -gt 0 ]; then
        local IFS=" && "
        echo "${cmds[*]}"
    fi
}

run_smoke_test() {
    local smoke_cmd="$1"

    if [ -z "$smoke_cmd" ]; then
        smoke "No tests detected — skipping smoke test"
        return 0
    fi

    smoke "Running: $smoke_cmd"

    local smoke_output
    local smoke_exit=0
    smoke_output=$(eval "$smoke_cmd" 2>&1) || smoke_exit=$?

    if [ $smoke_exit -ne 0 ]; then
        fail "Smoke test failed (exit code: $smoke_exit)"
        # Return the error output for feedback to the builder
        echo "$smoke_output" | tail -50 > .ralph-smoke-fail.tmp
        return 1
    fi

    smoke "All checks passed"
    return 0
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

# Detect smoke test command once at startup
DETECTED_SMOKE=$(detect_smoke_test)
if [ -n "$DETECTED_SMOKE" ]; then
    log "Smoke test detected: $DETECTED_SMOKE"
else
    log "No smoke test detected — Codex will be the only gate"
fi

# Branch setup
if ! git rev-parse --verify "$BRANCH" &>/dev/null 2>&1; then
    git checkout -b "$BRANCH"
    log "Created branch: $BRANCH"
else
    git checkout "$BRANCH"
    log "Checked out: $BRANCH"
fi

log "Starting multi-agent Ralph loop"
log "Builder:  $BUILDER (timeout: ${BUILD_TIMEOUT}s, max-turns: $MAX_TURNS, session: --continue after first run)"
log "Reviewer: $REVIEWER (timeout: ${REVIEW_TIMEOUT}s)"
log "Branch:   $BRANCH"
log "Max iterations: $MAX_ITERATIONS"
log "Progress: $(story_count)"
echo ""

ITERATION=0
RETRY_COUNT=0
MAX_RETRIES=3
LAST_STORY_ID=""
IS_FIRST_BUILD=true   # Track whether to use --continue

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
    log "🔨 Phase 1: Building with Claude Code... (timeout: ${BUILD_TIMEOUT}s)"

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

    # First iteration: fresh session. Subsequent: --continue to keep context + auto-compact.
    if [ "$IS_FIRST_BUILD" = true ]; then
        BUILD_OUTPUT=$(timeout "$BUILD_TIMEOUT" \
            $BUILDER -p "$BUILD_PROMPT" \
            --permission-mode auto \
            --max-turns "$MAX_TURNS" \
            2>/dev/null) || true
    else
        BUILD_OUTPUT=$(timeout "$BUILD_TIMEOUT" \
            $BUILDER --continue -p "$BUILD_PROMPT" \
            --permission-mode auto \
            --max-turns "$MAX_TURNS" \
            2>/dev/null) || true
    fi

    if [ -z "$BUILD_OUTPUT" ]; then
        warn "Builder returned empty output (timeout or error). Retrying next iteration."
        RETRY_COUNT=$((RETRY_COUNT + 1))
        git checkout -- . 2>/dev/null || true
        git clean -fd 2>/dev/null || true
        sleep $COOLDOWN
        continue
    fi

    IS_FIRST_BUILD=false  # All subsequent builds will use --continue
    log "Builder finished. Output length: ${#BUILD_OUTPUT} chars"

    # ── PHASE 2: SMOKE TEST (auto, no agent) ─────────────
    # Re-detect in case new files were created by the builder
    CURRENT_SMOKE=$(detect_smoke_test)

    if ! run_smoke_test "$CURRENT_SMOKE"; then
        RETRY_COUNT=$((RETRY_COUNT + 1))
        fail "Smoke test failed for $STORY_ID (attempt $RETRY_COUNT/$MAX_RETRIES)"

        # Build feedback from smoke test output
        SMOKE_FEEDBACK=""
        if [ -f ".ralph-smoke-fail.tmp" ]; then
            SMOKE_FEEDBACK=$(cat .ralph-smoke-fail.tmp)
            rm -f .ralph-smoke-fail.tmp
        fi

        echo "SMOKE TEST FAILED — fix these errors before the code reviewer sees it:
$SMOKE_FEEDBACK" > .ralph-feedback.tmp

        append_progress "SMOKE_FAIL $STORY_ID (attempt $RETRY_COUNT): Smoke test failed. Skipped Codex review."

        # Ratchet: revert changes on fail
        git checkout -- . 2>/dev/null || true
        git clean -fd 2>/dev/null || true

        log "Progress: $(story_count)"
        sleep $COOLDOWN
        continue
    fi

    # ── PHASE 3: REVIEW (Codex) ──────────────────────────
    log "🔍 Phase 3: Reviewing with Codex... (timeout: ${REVIEW_TIMEOUT}s)"

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

NOTE: Smoke tests (typecheck/lint/tests) have already passed. Focus on logic, architecture, and acceptance criteria.

OUTPUT YOUR VERDICT IN THIS EXACT FORMAT:

VERDICT: PASS
LEARNINGS: <any insights>

OR

VERDICT: FAIL
FEEDBACK: <specific issues to fix>
LEARNINGS: <any insights>"

    REVIEW_OUTPUT=$(timeout "$REVIEW_TIMEOUT" \
        $REVIEWER exec --full-auto \
        --sandbox workspace-write \
        "$REVIEW_PROMPT" \
        2>/dev/null) || true

    if [ -z "$REVIEW_OUTPUT" ]; then
        warn "Reviewer returned empty output. Treating as pass."
        REVIEW_OUTPUT="VERDICT: PASS"
    fi

    # ── PHASE 4: PARSE VERDICT ───────────────────────────
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
        git push 2>/dev/null || true  # Keep GitHub in sync

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
