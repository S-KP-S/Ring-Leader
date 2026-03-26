# ClaudeCodexLoop Skill Design

**Date:** 2026-03-26
**Status:** Approved

## Overview

A conversational skill that lets you describe an app idea (especially via Telegram on the go) and have it interview you, generate a PRD, set up the project, create a GitHub repo, and kick off the ralph build loop — all from a chat message.

## Intent Detection

When invoked, classifies the user's message as:
- **New project** — "build me a...", "I have an idea for...", "create a..."
- **Existing project** — "keep working on...", "continue the...", "run ralph on..."
- **Status check** — "how's the build going?", "what's the status of..."

## New Project Flow

### Interview (5-7 questions, one at a time)
1. What does the app do?
2. Who's it for?
3. What's the core feature — the one thing it must do?
4. Any secondary features? (optional)
5. Stack preference? (Python/FastAPI, Node/Express, Next.js fullstack, or "you pick")
6. Anything else I should know? (optional)

### Setup
1. Create folder: `C:\Users\spenc\Documents\<slugified-name>\`
2. `git init` + initial commit
3. `gh repo create <name> --private --source . --push`
4. Copy ralph files from `C:\Users\spenc\Documents\Ring-Leader\`
5. Generate `prd.json` with 5-8 right-sized user stories
6. Confirm: "Ready to build?"
7. Run `ralph.ps1` in background
8. Report progress as stories complete
9. `git push` after each passing story

### Telegram Integration
- After each passing story, message progress update
- If a story fails 3 times, ask user for guidance instead of silently skipping
- Status checks read `prd.json` + `progress.txt` and report

## Existing Project Flow

Scans `C:\Users\spenc\Documents\` for directories containing `prd.json` or `ralph.ps1`. Fuzzy-matches user description against folder names and PRD descriptions.

- One match → confirm and proceed
- Multiple matches → "Did you mean X or Y?"
- Stories remain → "X has 3 stories left. Want me to keep building?"
- All done → show summary

## File Location

```
Ring-Leader/
  skills/
    ClaudeCodexLoop.md
```
