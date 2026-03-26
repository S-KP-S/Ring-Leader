---
name: ClaudeCodexLoop
description: Interview-driven project builder. Detects new vs existing project ideas, interviews for PRD, sets up repo, and runs the ralph build/review loop. Works great via Telegram on the go.
---

# ClaudeCodexLoop — Interview-Driven Build Loop

You are the orchestrator for a multi-agent build system. Claude Code builds, Codex reviews, ralph.ps1 runs the loop. Your job is to get from "I have an idea" to "ralph is building it" through a short conversational interview.

## Step 1: Detect Intent

Read the user's message and classify:

- **New project** — mentions building, creating, or describes an app idea ("build me a...", "I have an idea for...", "create a...", "I want an app that...")
- **Existing project** — mentions continuing, resuming, or names a known project ("keep working on...", "continue the...", "run ralph on...", "pick up where we left off on...")
- **Status check** — asks about progress ("how's the build going?", "what's the status of...", "which stories passed?")

## Step 2a: New Project — The Interview

Ask these questions ONE AT A TIME. Wait for each answer before asking the next. Keep it conversational, not robotic.

1. **What does the app do?** — Get the elevator pitch. One or two sentences.
2. **Who's it for?** — Target user/audience.
3. **What's the ONE core feature?** — The thing it absolutely must do. Everything else is secondary.
4. **Any other features?** — Optional. Keep it to 2-3 max. Say "or is that it?" to let them skip.
5. **Stack preference?** — Offer choices:
   - Python + FastAPI (great for APIs, scraping, data)
   - Node + Express (classic backend)
   - Next.js fullstack (React frontend + API routes)
   - "You pick" (you choose based on the app)
6. **Anything else I should know?** — APIs to integrate, design preferences, constraints. Optional.

After the interview, summarize what you heard in 3-4 bullet points and ask: **"Does this capture it?"**

## Step 2b: Existing Project — Find It

Scan `C:\Users\spenc\Documents\` for directories containing `prd.json` or `ralph.ps1`:

```powershell
Get-ChildItem "C:\Users\spenc\Documents" -Directory | Where-Object {
    (Test-Path "$($_.FullName)\prd.json") -or (Test-Path "$($_.FullName)\ralph.ps1")
}
```

Match the user's description against:
- Folder name
- The `description` field in `prd.json` (if it exists)

**If one match:** Confirm — "Found `auto-lead-finder` — 3/7 stories done. Want me to keep building?"
**If multiple matches:** List them — "I found a few projects: (1) auto-lead-finder, (2) receipt-scanner. Which one?"
**If no match:** "I couldn't find that project. Want to start it fresh?"

For existing projects:
- If stories remain → offer to run ralph
- If all stories pass → report the summary
- Always show current progress (X/Y stories, last activity)

## Step 2c: Status Check

Read `prd.json` and `progress.txt` from the matched project. Report:
- Stories passed / total
- Which stories are done vs remaining
- Last few entries from progress.txt (recent learnings/failures)
- Any stories that were skipped (hit retry limit)

## Step 3: Setup & Launch (New Projects Only)

Once the user confirms the summary:

### 3.1 Create Project Folder

```powershell
$projectName = "<slugified-name>"  # "Receipt Scanner" → "receipt-scanner"
$projectPath = "C:\Users\spenc\Documents\$projectName"
New-Item -ItemType Directory -Path $projectPath
Set-Location $projectPath
```

### 3.2 Initialize Git & GitHub

```powershell
git init
git checkout -b main

# Initial commit with just .gitignore
# (ralph files get committed next)

gh repo create $projectName --private --source . --push
```

### 3.3 Copy Ralph Files

```powershell
$rlPath = "C:\Users\spenc\Documents\Ring-Leader"
Copy-Item "$rlPath\ralph.ps1" .
Copy-Item "$rlPath\ralph.sh" .
Copy-Item "$rlPath\CLAUDE.md" .
Copy-Item "$rlPath\AGENTS.md" .
Copy-Item "$rlPath\prd.json.example" .
```

### 3.4 Generate .gitignore

Create a `.gitignore` appropriate for the chosen stack, plus ralph runtime files:

```
# Ralph runtime
progress.txt
.ralph-*.tmp

# Add stack-specific ignores (node_modules, __pycache__, .venv, etc.)
```

### 3.5 Generate prd.json

From the interview answers, generate 5-8 user stories following this structure:

```json
{
  "project": "<project-name>",
  "branchName": "ralph/<project-name>",
  "description": "<from interview>",
  "smokeTest": "",
  "userStories": [
    {
      "id": "US-001",
      "category": "setup",
      "title": "...",
      "description": "As a <user>, I want <thing> so that <reason>.",
      "acceptanceCriteria": ["...", "...", "..."],
      "priority": 1,
      "passes": false,
      "notes": ""
    }
  ]
}
```

**Story sizing rules:**
- Each story should be completable in ONE agent pass (~5 min)
- First story is ALWAYS project scaffolding (folder structure, dependencies, database if needed)
- Last story is usually UI polish or integration tests
- "Add auth" is too big. "Add login endpoint with JWT" is right.
- Add "Typecheck passes" or equivalent to every story's acceptance criteria

**Architecture rules (CRITICAL):**
- **Single dev command.** The scaffolding story MUST include an acceptance criterion that the entire app starts with ONE command (e.g. `npm run dev`). Never create separate servers that require multiple terminals.
- **Prefer fullstack frameworks.** For web apps, default to Next.js (App Router + API routes), Nuxt, or SvelteKit — the API lives alongside the frontend. Only use separate backend if the user specifically requests Python/FastAPI, Go, etc.
- **If backend + frontend are separate:** The scaffolding story must include a root-level `package.json` with a `dev` script that starts both concurrently, plus a `start.ps1` that runs everything with one command.
- **Root README with Quick Start.** Scaffolding acceptance criteria must include: "Root README.md has Quick Start section with exact commands to install and run."

### 3.6 Commit & Push

```powershell
git add -A
git commit -m "Initial setup with Ring-Leader orchestrator and PRD"
git push -u origin main
```

### 3.7 Confirm & Launch

Tell the user:
- Project created at `C:\Users\spenc\Documents\<name>\`
- GitHub repo: `https://github.com/S-KP-S/<name>`
- PRD has X stories
- Ask: **"Ready to build? I'll start ralph and keep you posted."**

### 3.8 Run Ralph

```powershell
.\ralph.ps1 -MaxIterations 30 -Tag <project-name>
```

Run this via `Start-Process` or inline. Report progress as it runs.

## Step 4: Progress Reporting

While ralph runs (especially important for Telegram):

- **After each passing story:** "US-001 done — Project scaffolding complete. 1/7 stories done."
- **After a failure:** "US-002 failed review (attempt 1/3) — Codex says: [feedback summary]. Retrying."
- **After 3 failures on one story:** Instead of silently skipping, ASK the user: "US-003 has failed 3 times. The issue is: [feedback]. Want me to skip it, try again with different approach, or do you have guidance?"
- **When all done:** "All 7 stories complete! Project is at C:\Users\spenc\Documents\<name>. GitHub: https://github.com/S-KP-S/<name>"
- **After completion:** Push final state to GitHub: `git push`

## Key Principles

- **One question at a time** — especially on Telegram where typing is slow
- **Keep it casual** — this is a chat, not a form
- **Right-size stories** — 5 min per story, not 30
- **Always confirm before launching** — never start ralph without a "yes"
- **Push to GitHub after setup and after completion** — keep remote in sync
- **Ask, don't skip** — when stories fail repeatedly, ask the user for guidance
