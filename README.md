# Multi-Agent Ralph Loop

Drop these files into any project. Claude Code builds, Codex reviews, `ralph.sh` orchestrates.

## Setup (2 minutes)

```bash
# 1. Copy these files into your project root
cp ralph.sh CLAUDE.md AGENTS.md prd.json.example /path/to/your/project/
cd /path/to/your/project
chmod +x ralph.sh

# 2. Create your PRD (pick one method)

# Method A: Copy and edit the example
cp prd.json.example prd.json
# Edit prd.json with your actual stories

# Method B: Have Claude Code generate it
claude -p "Read this codebase and generate a prd.json with 5-8 user stories for: [YOUR FEATURE]. Use the format from prd.json.example. Each story should be small enough to implement in one pass."

# Method C: Interactive PRD interview (if you have Lisa installed)
# /lisa:plan "your feature description"

# 3. Make sure both agents are authenticated
claude    # follow login prompts if needed
codex login  # follow login prompts if needed
```

## Run

```bash
# Run until all stories pass
./ralph.sh

# Run max 20 iterations
./ralph.sh 20

# Run with a tag (creates branch ralph/auth-feature)
./ralph.sh 50 auth-feature

# Run in background with tmux
tmux new-session -d -s ralph './ralph.sh 50; read'
tmux attach -t ralph    # to watch
```

## Monitor

```bash
# Which stories are done?
cat prd.json | jq '.userStories[] | {id, title, passes}'

# What has the system learned?
cat progress.txt

# Git history of changes
git log --oneline -20

# Live watch the log
# (just watch the terminal — ralph.sh logs everything inline)
```

## How It Works

```
ralph.sh (bash while loop)
  │
  ├─ reads prd.json → picks next story where passes: false
  │
  ├─ PHASE 1: claude -p "implement this story..."
  │     Claude Code reads CLAUDE.md + progress.txt + codebase
  │     Writes code, outputs structured summary
  │
  ├─ PHASE 2: codex exec "review this implementation..."
  │     Codex reads AGENTS.md + progress.txt + codebase (with Claude's changes)
  │     Reviews, runs tests, outputs VERDICT: PASS or FAIL
  │
  ├─ If PASS → git commit → mark story done → next story
  ├─ If FAIL → git revert → save feedback → retry same story
  │
  └─ All stories done? → exit
```

**Agents never talk directly.** They communicate through files:
- `prd.json` — what to do (state machine)
- `progress.txt` — what was learned (memory)
- `git history` — what changed (diffs)
- `.ralph-feedback.tmp` — review feedback (ephemeral)

## File Reference

| File | Who reads | Who writes | Purpose |
|------|-----------|------------|---------|
| `ralph.sh` | — | You (once) | The orchestrator loop |
| `CLAUDE.md` | Claude Code | You | Builder instructions |
| `AGENTS.md` | Codex | You | Reviewer instructions |
| `prd.json` | Both agents | ralph.sh | Stories + passes status |
| `progress.txt` | Both agents | ralph.sh | Learnings between iterations |
| `prd.json.example` | — | — | Reference format |

## Tips

**Right-size your stories.** Each story should be completable in one context window. "Add auth" is too big. "Add login endpoint with JWT" is right.

**Add "Typecheck passes" to every story.** This gives the reviewer an objective pass/fail check beyond code review.

**Edit prd.json mid-run.** The loop re-reads it every iteration. Add stories, fix acceptance criteria, adjust priorities — all live.

**Edit progress.txt manually.** If the agents keep making the same mistake, add a gotcha: "IMPORTANT: This project uses pnpm, not npm. Run pnpm test."

**Git is your undo button.** Every passing story is its own commit. `git revert` any one without touching the rest.

**Overnight runs.** `./ralph.sh 100` will run ~100 iterations. At ~10 min per iteration (build + review), that's ~16 hours. Set `MAX_ITERATIONS` accordingly.

## Customization

Edit the top of `ralph.sh`:

```bash
BUILDER="claude"      # swap to: aider, cursor, etc.
REVIEWER="codex"      # swap to: claude (yes, Claude can review too)
MAX_RETRIES=3         # retries per story before skipping
COOLDOWN=5            # seconds between iterations
```

## Cost Awareness

Each iteration makes 2 agent calls (1 builder + 1 reviewer). On subscription plans (Claude Max, ChatGPT Pro), this uses your quota. On API billing, budget accordingly. A typical overnight run of 50 iterations = 100 agent calls.
