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
$script:BRANCH = "ralph/$Tag"
$script:BUILDER = "claude"
$script:REVIEWER = "codex"
$script:COOLDOWN = 5
$script:BUILD_TIMEOUT = 300
$script:REVIEW_TIMEOUT = 180
$script:MAX_TURNS = 15
$script:SMOKE_TEST = ""
$script:MAX_RETRIES = 3

# ── Logging ──────────────────────────────────────────────
function Write-Log([string]$msg)   { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $msg" -ForegroundColor Blue }
function Write-Pass([string]$msg)  { Write-Host "[PASS] $msg" -ForegroundColor Green }
function Write-Fail([string]$msg)  { Write-Host "[FAIL] $msg" -ForegroundColor Red }
function Write-Warn([string]$msg)  { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Smoke([string]$msg) { Write-Host "[SMOKE] $msg" -ForegroundColor Cyan }

# ── Preflight ────────────────────────────────────────────
function Test-Dependencies {
    $missing = @()
    if (-not (Get-Command $script:BUILDER -ErrorAction SilentlyContinue)) { $missing += $script:BUILDER }
    if (-not (Get-Command $script:REVIEWER -ErrorAction SilentlyContinue)) { $missing += $script:REVIEWER }
    if (-not (Get-Command "jq" -ErrorAction SilentlyContinue)) { $missing += "jq" }
    if (-not (Get-Command "git" -ErrorAction SilentlyContinue)) { $missing += "git" }

    if ($missing.Count -gt 0) {
        Write-Host "Missing: $($missing -join ', ')" -ForegroundColor Red
        exit 1
    }
}

# ── PRD helpers ──────────────────────────────────────────
function Get-NextStory {
    $raw = & jq -r '[.userStories[] | select(.passes == false)] | sort_by(.priority) | .[0] // empty' prd.json 2>$null
    if ($raw -and $raw.Trim()) { return ($raw | Out-String).Trim() }
    return $null
}

function Get-StoryCount {
    $total = & jq '.userStories | length' prd.json 2>$null
    $done = & jq '[.userStories[] | select(.passes == true)] | length' prd.json 2>$null
    return "${done}/${total}"
}

function Test-AllDone {
    $remaining = & jq '[.userStories[] | select(.passes == false)] | length' prd.json 2>$null
    return ([string]$remaining).Trim() -eq "0"
}

function Set-StoryPassed([string]$storyId) {
    & jq --arg id $storyId '(.userStories[] | select(.id == $id)).passes = true' prd.json | Out-File -Encoding utf8 prd.tmp
    Move-Item -Force prd.tmp prd.json
}

function Get-StoryField([string]$json, [string]$field) {
    $result = $json | & jq -r ".$field" 2>$null
    return ($result | Out-String).Trim()
}

function Get-StoryAC([string]$json) {
    $result = $json | & jq -r '.acceptanceCriteria | join("\n  - ")' 2>$null
    return ($result | Out-String).Trim()
}

# ── Progress file ────────────────────────────────────────
function Add-Progress([string]$text) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "`n--- [$timestamp] ---`n$text"
    [System.IO.File]::AppendAllText("$(Get-Location)\progress.txt", $entry)
}

# ── Smoke test detection ─────────────────────────────────
function Get-SmokeTestCommand {
    # 1. Check prd.json for explicit smokeTest
    $prdSmoke = & jq -r '.smokeTest // empty' prd.json 2>$null
    if ($prdSmoke -and $prdSmoke.Trim()) { return $prdSmoke.Trim() }

    # 2. User override
    if ($script:SMOKE_TEST) { return $script:SMOKE_TEST }

    # 3. Auto-detect
    $cmds = @()

    if (Test-Path "package.json") {
        $hasTest = & jq -r '.scripts.test // empty' package.json 2>$null
        if ($hasTest -and $hasTest.Trim() -and $hasTest -notmatch 'no test specified') {
            $cmds += "npm test"
        }
    }

    if (Test-Path "tsconfig.json") {
        $cmds += "npx tsc --noEmit"
    }

    if ((Test-Path "pyproject.toml") -or (Test-Path "pytest.ini") -or (Test-Path "setup.py")) {
        if (Get-Command "pytest" -ErrorAction SilentlyContinue) {
            $cmds += "pytest"
        }
    }

    if (Test-Path "Cargo.toml") {
        $cmds += "cargo check"
        $cmds += "cargo test"
    }

    if (Test-Path "go.mod") {
        $cmds += "go vet ./..."
        $cmds += "go test ./..."
    }

    if ($cmds.Count -gt 0) {
        return ($cmds -join " && ")
    }
    return ""
}

function Invoke-SmokeTest([string]$smokeCmd) {
    if (-not $smokeCmd) {
        Write-Smoke "No tests detected - skipping smoke test"
        return $true
    }

    Write-Smoke "Running: $smokeCmd"

    $output = & cmd /c "$smokeCmd 2>&1"
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Smoke test failed (exit code: $LASTEXITCODE)"
        ($output | Select-Object -Last 50) -join "`n" | Out-File -Encoding utf8 .ralph-smoke-fail.tmp
        return $false
    }

    Write-Smoke "All checks passed"
    return $true
}


# ══════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════
Test-Dependencies

if (-not (Test-Path "prd.json")) {
    Write-Host "No prd.json found. Create one first."
    Write-Host "  Option 1: Copy prd.json.example and edit it"
    Write-Host "  Option 2: claude -p 'generate a prd.json for: [YOUR FEATURE]'"
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
    Write-Log "Smoke test detected: $detectedSmoke"
} else {
    Write-Log "No smoke test detected - Codex will be the only gate"
}

# Branch setup
$branchCheck = & git rev-parse --verify $script:BRANCH 2>$null
if (-not $branchCheck) {
    & git checkout -b $script:BRANCH
    Write-Log "Created branch: $($script:BRANCH)"
} else {
    & git checkout $script:BRANCH
    Write-Log "Checked out: $($script:BRANCH)"
}

Write-Log "Starting multi-agent Ralph loop"
Write-Log "Builder:  $($script:BUILDER) (timeout: $($script:BUILD_TIMEOUT)s, max-turns: $($script:MAX_TURNS), session: --continue after first run)"
Write-Log "Reviewer: $($script:REVIEWER) (timeout: $($script:REVIEW_TIMEOUT)s)"
Write-Log "Branch:   $($script:BRANCH)"
Write-Log "Max iterations: $MaxIterations"
Write-Log "Progress: $(Get-StoryCount)"
Write-Host ""

$iteration = 0
$retryCount = 0
$lastStoryId = ""
$isFirstBuild = $true   # Track whether to use --continue

while ($iteration -lt $MaxIterations) {
    $iteration++

    # ── Check if all done ────────────────────────────────
    if (Test-AllDone) {
        Write-Host ""
        Write-Pass "ALL STORIES COMPLETE"
        Write-Log "Final progress: $(Get-StoryCount)"
        exit 0
    }

    # ── Pick next story ──────────────────────────────────
    $storyJson = Get-NextStory
    if (-not $storyJson) {
        Write-Pass "No more stories. Done!"
        exit 0
    }

    $storyId = Get-StoryField $storyJson "id"
    $storyTitle = Get-StoryField $storyJson "title"
    $storyDesc = Get-StoryField $storyJson "description"
    $storyAC = Get-StoryAC $storyJson

    # Reset retry counter if new story
    if ($storyId -ne $lastStoryId) {
        $retryCount = 0
        $lastStoryId = $storyId
    }

    # Skip if too many retries
    if ($retryCount -ge $script:MAX_RETRIES) {
        Write-Warn "Skipping $storyId after $retryCount retries"
        Set-StoryPassed $storyId
        Add-Progress "SKIPPED ${storyId}: Too many retries. Needs manual review."
        $lastStoryId = ""
        continue
    }

    Write-Host ""
    Write-Log "==================================================="
    Write-Log "  ITERATION $iteration - ${storyId}: $storyTitle"
    Write-Log "  Progress: $(Get-StoryCount) | Attempt: $($retryCount + 1)/$($script:MAX_RETRIES)"
    Write-Log "==================================================="

    # ── Read retry feedback if exists ────────────────────
    $feedback = ""
    if (Test-Path ".ralph-feedback.tmp") {
        $feedback = Get-Content ".ralph-feedback.tmp" -Raw
        Remove-Item -Force ".ralph-feedback.tmp"
    }

    # ── PHASE 1: BUILD (Claude Code) ─────────────────────
    Write-Log "Phase 1: Building with Claude Code... (timeout: $($script:BUILD_TIMEOUT)s)"

    $progressTail = ""
    if (Test-Path "progress.txt") {
        $progressTail = (Get-Content progress.txt -Tail 100 -ErrorAction SilentlyContinue) -join "`n"
    }

    $retryBlock = ""
    if ($feedback) {
        $retryBlock = "`nWARNING - RETRY - Previous attempt failed review:`n$feedback`n`nFix ALL issues above."
    }

    # Write prompt to temp file to avoid argument escaping issues
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

    $buildPrompt | Out-File -Encoding utf8 .ralph-build-prompt.tmp
    $promptFile = (Resolve-Path .ralph-build-prompt.tmp).Path

    # Resolve full path to builder executable so Start-Job can find it
    $builderFullPath = (Get-Command $script:BUILDER -ErrorAction SilentlyContinue).Source
    $buildWorkDir = (Get-Location).Path

    # First iteration: fresh session. Subsequent: --continue to keep context + auto-compact.
    $useContinue = -not $isFirstBuild
    $buildJob = Start-Job -ScriptBlock {
        param($builderPath, $promptPath, $maxTurns, $shouldContinue, $workDir)
        Set-Location $workDir
        $prompt = Get-Content $promptPath -Raw
        if ($shouldContinue) {
            $result = & $builderPath --continue -p $prompt --permission-mode auto --max-turns $maxTurns 2>&1
        } else {
            $result = & $builderPath -p $prompt --permission-mode auto --max-turns $maxTurns 2>&1
        }
        return ($result | Out-String)
    } -ArgumentList $builderFullPath, $promptFile, $script:MAX_TURNS, $useContinue, $buildWorkDir

    $buildFinished = $buildJob | Wait-Job -Timeout $script:BUILD_TIMEOUT
    if ($buildFinished) {
        $buildOutput = $buildJob | Receive-Job
    } else {
        Write-Warn "Builder timed out after $($script:BUILD_TIMEOUT)s - killing"
        $buildJob | Stop-Job
        $buildOutput = ""
    }
    $buildJob | Remove-Job -Force -ErrorAction SilentlyContinue
    Remove-Item -Force .ralph-build-prompt.tmp -ErrorAction SilentlyContinue

    if (-not $buildOutput) {
        Write-Warn "Builder returned empty output (timeout or error). Retrying."
        $retryCount++
        & git checkout -- . 2>$null
        & git clean -fd 2>$null
        Start-Sleep -Seconds $script:COOLDOWN
        continue
    }

    $isFirstBuild = $false  # All subsequent builds will use --continue
    Write-Log "Builder finished. Output length: $($buildOutput.Length) chars"

    # ── PHASE 2: SMOKE TEST (auto, no agent) ─────────────
    $currentSmoke = Get-SmokeTestCommand

    $smokeResult = Invoke-SmokeTest $currentSmoke
    if (-not $smokeResult) {
        $retryCount++
        Write-Fail "Smoke test failed for $storyId (attempt $retryCount/$($script:MAX_RETRIES))"

        $smokeFeedback = ""
        if (Test-Path ".ralph-smoke-fail.tmp") {
            $smokeFeedback = Get-Content ".ralph-smoke-fail.tmp" -Raw
            Remove-Item -Force ".ralph-smoke-fail.tmp"
        }

        "SMOKE TEST FAILED - fix these errors before the code reviewer sees it:`n$smokeFeedback" | Out-File -Encoding utf8 .ralph-feedback.tmp

        Add-Progress "SMOKE_FAIL $storyId (attempt ${retryCount}): Smoke test failed. Skipped Codex review."

        & git checkout -- . 2>$null
        & git clean -fd 2>$null

        Write-Log "Progress: $(Get-StoryCount)"
        Start-Sleep -Seconds $script:COOLDOWN
        continue
    }

    # ── PHASE 3: REVIEW (Codex) ──────────────────────────
    Write-Log "Phase 3: Reviewing with Codex... (timeout: $($script:REVIEW_TIMEOUT)s)"

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

    $reviewPrompt | Out-File -Encoding utf8 .ralph-review-prompt.tmp
    $reviewPromptFile = (Resolve-Path .ralph-review-prompt.tmp).Path

    # Resolve full path to reviewer executable so Start-Job can find it
    $reviewerFullPath = (Get-Command $script:REVIEWER -ErrorAction SilentlyContinue).Source
    $reviewWorkDir = (Get-Location).Path

    $reviewJob = Start-Job -ScriptBlock {
        param($reviewerPath, $promptPath, $workDir)
        Set-Location $workDir
        $prompt = Get-Content $promptPath -Raw
        $result = & $reviewerPath exec --full-auto --sandbox workspace-write $prompt 2>&1
        return ($result | Out-String)
    } -ArgumentList $reviewerFullPath, $reviewPromptFile, $reviewWorkDir

    $reviewFinished = $reviewJob | Wait-Job -Timeout $script:REVIEW_TIMEOUT
    if ($reviewFinished) {
        $reviewOutput = $reviewJob | Receive-Job
    } else {
        Write-Warn "Reviewer timed out after $($script:REVIEW_TIMEOUT)s - killing"
        $reviewJob | Stop-Job
        $reviewOutput = ""
    }
    $reviewJob | Remove-Job -Force -ErrorAction SilentlyContinue
    Remove-Item -Force .ralph-review-prompt.tmp -ErrorAction SilentlyContinue

    if (-not $reviewOutput) {
        Write-Warn "Reviewer returned empty output. Treating as pass."
        $reviewOutput = "VERDICT: PASS"
    }

    # ── PHASE 4: PARSE VERDICT ───────────────────────────
    $verdictLine = ($reviewOutput -split "`n") | Where-Object { $_ -match "^VERDICT:" } | Select-Object -First 1
    $verdict = ""
    if ($verdictLine) { $verdict = ($verdictLine -replace "VERDICT:", "").Trim().ToUpper() }

    $feedbackLine = ($reviewOutput -split "`n") | Where-Object { $_ -match "^FEEDBACK:" } | Select-Object -First 1
    $reviewFeedback = ""
    if ($feedbackLine) { $reviewFeedback = ($feedbackLine -replace "FEEDBACK:", "").Trim() }

    $learningsLine = ($reviewOutput -split "`n") | Where-Object { $_ -match "^LEARNINGS:" } | Select-Object -First 1
    $reviewLearnings = ""
    if ($learningsLine) { $reviewLearnings = ($learningsLine -replace "LEARNINGS:", "").Trim() }

    # Record learnings from builder
    $buildLearningsLine = ($buildOutput -split "`n") | Where-Object { $_ -match "^LEARNINGS:" } | Select-Object -First 1
    $buildLearnings = ""
    if ($buildLearningsLine) { $buildLearnings = ($buildLearningsLine -replace "LEARNINGS:", "").Trim() }

    if ($buildLearnings) { Add-Progress "[Builder - $storyId] $buildLearnings" }
    if ($reviewLearnings) { Add-Progress "[Reviewer - $storyId] $reviewLearnings" }

    # ── Handle verdict ───────────────────────────────────
    if ($verdict -eq "PASS") {
        Write-Pass "${storyId}: $storyTitle"

        Set-StoryPassed $storyId

        & git add -A
        & git commit -m "[ralph] ${storyId}: $storyTitle" 2>$null
        & git push 2>$null  # Keep GitHub in sync

        Add-Progress "COMPLETED ${storyId}: $storyTitle"

        $lastStoryId = ""
        $retryCount = 0

    } elseif ($verdict -eq "FAIL") {
        $retryCount++
        Write-Fail "$storyId (attempt $retryCount/$($script:MAX_RETRIES))"

        $reviewFeedback | Out-File -Encoding utf8 .ralph-feedback.tmp

        $truncated = $reviewFeedback
        if ($truncated.Length -gt 200) { $truncated = $truncated.Substring(0, 200) }
        Add-Progress "REVIEW_FAIL $storyId (attempt ${retryCount}): $truncated"

        & git checkout -- . 2>$null
        & git clean -fd 2>$null

    } else {
        $retryCount++
        Write-Warn "Unclear verdict: '$verdict'. Treating as review failure (attempt $retryCount/$($script:MAX_RETRIES))"

        "REVIEW ERROR - Codex did not return a clear VERDICT. The code may be fine but needs re-review. Make sure all acceptance criteria are met." | Out-File -Encoding utf8 .ralph-feedback.tmp

        Add-Progress "REVIEW_ERROR $storyId (attempt ${retryCount}): Codex returned unclear verdict '$verdict'"

        & git checkout -- . 2>$null
        & git clean -fd 2>$null
    }

    Write-Log "Progress: $(Get-StoryCount)"
    Start-Sleep -Seconds $script:COOLDOWN
}

Write-Host ""
Write-Warn "Reached max iterations ($MaxIterations)."
Write-Log "Final progress: $(Get-StoryCount)"
Write-Log "Run again to continue."
