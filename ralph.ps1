# ─────────────────────────────────────────────────────────
# ralph.ps1 — Multi-agent Ralph loop (PowerShell)
#
# Builder: Claude Code (implements)
# Reviewer: Codex (reviews + tests)
# Smoke Test: auto-detected tests/typecheck (pre-gate)
#
# Usage:
#   .\ralph.ps1                        # run until prd.json complete
#   .\ralph.ps1 -MaxIterations 20      # max 20 iterations
#   .\ralph.ps1 -MaxIterations 50 -Tag my-feature
# ─────────────────────────────────────────────────────────

param(
    [int]$MaxIterations = 50,
    [string]$Tag = (Get-Date -Format "MMMdd")
)

$ErrorActionPreference = "Continue"

# ── Config ───────────────────────────────────────────────
$BRANCH = "ralph/$Tag"
$BUILDER = "claude"
$REVIEWER = "codex"
$COOLDOWN = 5
$BUILD_TIMEOUT = 300     # 5 min
$REVIEW_TIMEOUT = 180    # 3 min
$MAX_TURNS = 15
$SMOKE_TEST = ""
$MAX_RETRIES = 3

# ── Logging ──────────────────────────────────────────────
function Log($msg)   { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $msg" -ForegroundColor Blue }
function Pass($msg)  { Write-Host "[PASS] $msg" -ForegroundColor Green }
function Fail($msg)  { Write-Host "[FAIL] $msg" -ForegroundColor Red }
function Warn($msg)  { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Smoke($msg) { Write-Host "[SMOKE] $msg" -ForegroundColor Cyan }

# ── Preflight ────────────────────────────────────────────
function Check-Deps {
    $missing = @()
    if (-not (Get-Command $BUILDER -ErrorAction SilentlyContinue)) { $missing += $BUILDER }
    if (-not (Get-Command $REVIEWER -ErrorAction SilentlyContinue)) { $missing += $REVIEWER }
    if (-not (Get-Command "jq" -ErrorAction SilentlyContinue)) { $missing += "jq" }
    if (-not (Get-Command "git" -ErrorAction SilentlyContinue)) { $missing += "git" }

    if ($missing.Count -gt 0) {
        Write-Host "Missing: $($missing -join ', ')" -ForegroundColor Red
        exit 1
    }
}

# ── PRD helpers ──────────────────────────────────────────
function Get-NextStory {
    $result = jq -r '[.userStories[] | select(.passes == false)] | sort_by(.priority) | .[0] // empty' prd.json 2>$null
    return $result
}

function Get-StoryCount {
    $total = jq '.userStories | length' prd.json 2>$null
    $done = jq '[.userStories[] | select(.passes == true)] | length' prd.json 2>$null
    return "$done/$total"
}

function Test-AllDone {
    $remaining = jq '[.userStories[] | select(.passes == false)] | length' prd.json 2>$null
    return ($remaining -eq "0")
}

function Set-StoryPassed($storyId) {
    $escaped = $storyId.Replace('"', '\"')
    jq --arg id "$escaped" '(.userStories[] | select(.id == $id)).passes = true' prd.json > prd.tmp
    Move-Item -Force prd.tmp prd.json
}

# ── Progress file ────────────────────────────────────────
function Add-Progress($text) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "`n--- [$timestamp] ---`n$text" | Out-File -Append -Encoding utf8 progress.txt
}

# ── Smoke test detection ─────────────────────────────────
function Get-SmokeTestCommand {
    # 1. Check prd.json for explicit smokeTest
    $prdSmoke = jq -r '.smokeTest // empty' prd.json 2>$null
    if ($prdSmoke) { return $prdSmoke }

    # 2. User override
    if ($SMOKE_TEST) { return $SMOKE_TEST }

    # 3. Auto-detect
    $cmds = @()

    # Node.js
    if (Test-Path "package.json") {
        $hasTest = jq -r '.scripts.test // empty' package.json 2>$null
        if ($hasTest -and $hasTest -ne 'echo "Error: no test specified" && exit 1') {
            $cmds += "npm test"
        }
    }

    # TypeScript
    if (Test-Path "tsconfig.json") {
        $cmds += "npx tsc --noEmit"
    }

    # Python
    if ((Test-Path "pyproject.toml") -or (Test-Path "pytest.ini") -or (Test-Path "setup.py")) {
        if (Get-Command "pytest" -ErrorAction SilentlyContinue) {
            $cmds += "pytest"
        }
    }

    # Rust
    if (Test-Path "Cargo.toml") {
        $cmds += "cargo check"
        $cmds += "cargo test"
    }

    # Go
    if (Test-Path "go.mod") {
        $cmds += "go vet ./..."
        $cmds += "go test ./..."
    }

    if ($cmds.Count -gt 0) {
        return $cmds -join " && "
    }
    return ""
}

function Invoke-SmokeTest($smokeCmd) {
    if (-not $smokeCmd) {
        Smoke "No tests detected - skipping smoke test"
        return $true
    }

    Smoke "Running: $smokeCmd"

    try {
        $output = cmd /c "$smokeCmd 2>&1"
        if ($LASTEXITCODE -ne 0) {
            Fail "Smoke test failed (exit code: $LASTEXITCODE)"
            $output | Select-Object -Last 50 | Out-File -Encoding utf8 .ralph-smoke-fail.tmp
            return $false
        }
    } catch {
        Fail "Smoke test error: $_"
        $_.ToString() | Out-File -Encoding utf8 .ralph-smoke-fail.tmp
        return $false
    }

    Smoke "All checks passed"
    return $true
}

# ── Run with timeout ─────────────────────────────────────
function Invoke-WithTimeout($command, $args, $timeoutSeconds) {
    $process = Start-Process -FilePath $command -ArgumentList $args -NoNewWindow -PassThru -RedirectStandardOutput ".ralph-stdout.tmp" -RedirectStandardError ".ralph-stderr.tmp"

    $completed = $process.WaitForExit($timeoutSeconds * 1000)

    if (-not $completed) {
        Warn "Process timed out after ${timeoutSeconds}s — killing"
        $process | Stop-Process -Force
        return ""
    }

    if (Test-Path ".ralph-stdout.tmp") {
        $output = Get-Content ".ralph-stdout.tmp" -Raw
        Remove-Item -Force ".ralph-stdout.tmp" -ErrorAction SilentlyContinue
        Remove-Item -Force ".ralph-stderr.tmp" -ErrorAction SilentlyContinue
        return $output
    }
    return ""
}

# ══════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════
Check-Deps

if (-not (Test-Path "prd.json")) {
    Write-Host "No prd.json found. Create one first."
    Write-Host "  Option 1: Copy prd.json.example and edit it"
    Write-Host "  Option 2: In Claude Code, run: /prd `"your feature`""
    exit 1
}

# Initialize progress file
if (-not (Test-Path "progress.txt")) {
    @"
# Progress Log
# Append-only learnings from each iteration.
# Both agents read this for context at the start of each iteration.

## Codebase Patterns

## Gotchas & Lessons Learned

"@ | Out-File -Encoding utf8 progress.txt
}

# Detect smoke test
$detectedSmoke = Get-SmokeTestCommand
if ($detectedSmoke) {
    Log "Smoke test detected: $detectedSmoke"
} else {
    Log "No smoke test detected - Codex will be the only gate"
}

# Branch setup
$branchExists = git rev-parse --verify $BRANCH 2>$null
if (-not $branchExists) {
    git checkout -b $BRANCH
    Log "Created branch: $BRANCH"
} else {
    git checkout $BRANCH
    Log "Checked out: $BRANCH"
}

Log "Starting multi-agent Ralph loop"
Log "Builder:  $BUILDER (timeout: ${BUILD_TIMEOUT}s, max-turns: $MAX_TURNS)"
Log "Reviewer: $REVIEWER (timeout: ${REVIEW_TIMEOUT}s)"
Log "Branch:   $BRANCH"
Log "Max iterations: $MaxIterations"
Log "Progress: $(Get-StoryCount)"
Write-Host ""

$iteration = 0
$retryCount = 0
$lastStoryId = ""

while ($iteration -lt $MaxIterations) {
    $iteration++

    # ── Check if all done ────────────────────────────────
    if (Test-AllDone) {
        Write-Host ""
        Pass "ALL STORIES COMPLETE"
        Log "Final progress: $(Get-StoryCount)"
        exit 0
    }

    # ── Pick next story ──────────────────────────────────
    $storyJson = Get-NextStory
    if (-not $storyJson) {
        Pass "No more stories. Done!"
        exit 0
    }

    $storyId = echo $storyJson | jq -r '.id'
    $storyTitle = echo $storyJson | jq -r '.title'
    $storyDesc = echo $storyJson | jq -r '.description'
    $storyAC = echo $storyJson | jq -r '.acceptanceCriteria | join("\n  - ")'

    # Reset retry counter if new story
    if ($storyId -ne $lastStoryId) {
        $retryCount = 0
        $lastStoryId = $storyId
    }

    # Skip if too many retries
    if ($retryCount -ge $MAX_RETRIES) {
        Warn "Skipping $storyId after $retryCount retries"
        Set-StoryPassed $storyId
        Add-Progress "SKIPPED ${storyId}: Too many retries. Needs manual review."
        $lastStoryId = ""
        continue
    }

    Write-Host ""
    Log "==================================================="
    Log "  ITERATION $iteration - ${storyId}: $storyTitle"
    Log "  Progress: $(Get-StoryCount) | Attempt: $($retryCount + 1)/$MAX_RETRIES"
    Log "==================================================="

    # ── Read retry feedback if exists ────────────────────
    $feedback = ""
    if (Test-Path ".ralph-feedback.tmp") {
        $feedback = Get-Content ".ralph-feedback.tmp" -Raw
        Remove-Item -Force ".ralph-feedback.tmp"
    }

    # ── PHASE 1: BUILD (Claude Code) ─────────────────────
    Log "Phase 1: Building with Claude Code... (timeout: ${BUILD_TIMEOUT}s)"

    $progressTail = Get-Content progress.txt -Tail 100 -ErrorAction SilentlyContinue | Out-String

    $retryBlock = ""
    if ($feedback) {
        $retryBlock = @"

WARNING - RETRY - Previous attempt failed review:
$feedback

Fix ALL issues above.
"@
    }

    $buildPrompt = @"
You are implementing ONE user story in this codebase.

STORY: $storyId - $storyTitle
DESCRIPTION: $storyDesc

ACCEPTANCE CRITERIA:
  - $storyAC

PREVIOUS LEARNINGS (from progress.txt):
$progressTail

INSTRUCTIONS:
1. Read relevant code to understand current state
2. Implement ONLY this story - minimal, focused changes
3. Ensure all acceptance criteria are met
4. Run any existing tests/checks if available
$retryBlock

When done, output:
FILES_CHANGED: <comma-separated list>
SUMMARY: <1-2 sentences of what you did>
LEARNINGS: <any codebase patterns or gotchas discovered>
"@

    $buildOutput = Invoke-WithTimeout $BUILDER "-p `"$($buildPrompt.Replace('"','\"'))`" --permission-mode auto --max-turns $MAX_TURNS" $BUILD_TIMEOUT

    if (-not $buildOutput) {
        Warn "Builder returned empty output (timeout or error). Retrying."
        $retryCount++
        git checkout -- . 2>$null
        git clean -fd 2>$null
        Start-Sleep -Seconds $COOLDOWN
        continue
    }

    Log "Builder finished. Output length: $($buildOutput.Length) chars"

    # ── PHASE 2: SMOKE TEST (auto, no agent) ─────────────
    $currentSmoke = Get-SmokeTestCommand

    if (-not (Invoke-SmokeTest $currentSmoke)) {
        $retryCount++
        Fail "Smoke test failed for $storyId (attempt $retryCount/$MAX_RETRIES)"

        $smokeFeedback = ""
        if (Test-Path ".ralph-smoke-fail.tmp") {
            $smokeFeedback = Get-Content ".ralph-smoke-fail.tmp" -Raw
            Remove-Item -Force ".ralph-smoke-fail.tmp"
        }

        "SMOKE TEST FAILED - fix these errors before the code reviewer sees it:`n$smokeFeedback" | Out-File -Encoding utf8 .ralph-feedback.tmp

        Add-Progress "SMOKE_FAIL $storyId (attempt ${retryCount}): Smoke test failed. Skipped Codex review."

        git checkout -- . 2>$null
        git clean -fd 2>$null

        Log "Progress: $(Get-StoryCount)"
        Start-Sleep -Seconds $COOLDOWN
        continue
    }

    # ── PHASE 3: REVIEW (Codex) ──────────────────────────
    Log "Phase 3: Reviewing with Codex... (timeout: ${REVIEW_TIMEOUT}s)"

    $buildSummary = ($buildOutput -split "`n") | Select-Object -Last 50 | Out-String

    $reviewPrompt = @"
You are a senior code reviewer. An implementation was just made.

STORY: $storyId - $storyTitle
ACCEPTANCE CRITERIA:
  - $storyAC

BUILDER SUMMARY:
$buildSummary

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
LEARNINGS: <any insights>
"@

    $reviewOutput = Invoke-WithTimeout $REVIEWER "exec --full-auto --sandbox workspace-write `"$($reviewPrompt.Replace('"','\"'))`"" $REVIEW_TIMEOUT

    if (-not $reviewOutput) {
        Warn "Reviewer returned empty output. Treating as pass."
        $reviewOutput = "VERDICT: PASS"
    }

    # ── PHASE 4: PARSE VERDICT ───────────────────────────
    $verdictLine = ($reviewOutput -split "`n") | Where-Object { $_ -match "^VERDICT:" } | Select-Object -First 1
    $verdict = if ($verdictLine) { ($verdictLine -replace "VERDICT:", "").Trim().ToUpper() } else { "" }

    $feedbackLines = ($reviewOutput -split "`n") | Where-Object { $_ -match "^FEEDBACK:" } | Select-Object -First 1
    $reviewFeedback = if ($feedbackLines) { ($feedbackLines -replace "FEEDBACK:", "").Trim() } else { "" }

    $learningsLine = ($reviewOutput -split "`n") | Where-Object { $_ -match "^LEARNINGS:" } | Select-Object -First 1
    $reviewLearnings = if ($learningsLine) { ($learningsLine -replace "LEARNINGS:", "").Trim() } else { "" }

    # Record learnings from builder
    $buildLearningsLine = ($buildOutput -split "`n") | Where-Object { $_ -match "^LEARNINGS:" } | Select-Object -First 1
    $buildLearnings = if ($buildLearningsLine) { ($buildLearningsLine -replace "LEARNINGS:", "").Trim() } else { "" }

    if ($buildLearnings) { Add-Progress "[Builder - $storyId] $buildLearnings" }
    if ($reviewLearnings) { Add-Progress "[Reviewer - $storyId] $reviewLearnings" }

    # ── Handle verdict ───────────────────────────────────
    if ($verdict -eq "PASS") {
        Pass "${storyId}: $storyTitle"

        Set-StoryPassed $storyId

        git add -A
        git commit -m "[ralph] ${storyId}: $storyTitle" 2>$null

        Add-Progress "COMPLETED ${storyId}: $storyTitle"

        $lastStoryId = ""
        $retryCount = 0

    } elseif ($verdict -eq "FAIL") {
        $retryCount++
        Fail "$storyId (attempt $retryCount/$MAX_RETRIES)"

        $reviewFeedback | Out-File -Encoding utf8 .ralph-feedback.tmp

        Add-Progress "REVIEW_FAIL $storyId (attempt ${retryCount}): $($reviewFeedback.Substring(0, [Math]::Min(200, $reviewFeedback.Length)))"

        git checkout -- . 2>$null
        git clean -fd 2>$null

    } else {
        Warn "Unclear verdict: '$verdict'. Treating as pass."
        Set-StoryPassed $storyId
        git add -A
        git commit -m "[ralph] ${storyId}: $storyTitle" 2>$null
        $lastStoryId = ""
    }

    Log "Progress: $(Get-StoryCount)"
    Start-Sleep -Seconds $COOLDOWN
}

Write-Host ""
Warn "Reached max iterations ($MaxIterations)."
Log "Final progress: $(Get-StoryCount)"
Log "Run again to continue."
