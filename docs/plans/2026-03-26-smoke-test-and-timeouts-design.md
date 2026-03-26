# Smoke Test Pre-Gate & Time-Boxed Iterations

**Date:** 2026-03-26
**Status:** Approved
**Inspiration:** [karpathy/autoresearch](https://github.com/karpathy/autoresearch) — objective metrics as gatekeeper, time-boxed experiments

## Problem

1. When Claude Code writes code that doesn't pass typecheck/tests, Codex still spins up to review it — wasting an agent call on obviously broken code.
2. The builder has no time cap. A complex story can burn tokens for 30+ minutes going down a rabbit hole.

## Solution

### Phase 2.5: Automated Smoke Test

Insert an automated check between Build and Review. No agent involved — just bash running tests/typecheck/lint.

- If smoke test fails → revert changes, feed error output back to builder as retry feedback, skip Codex entirely
- If smoke test passes → proceed to Codex review

**Detection logic** (checked in order, first match wins):
- `prd.json` has `"smokeTest"` field → use that command
- `package.json` with `test` script → `npm test`
- `tsconfig.json` exists → `npx tsc --noEmit`
- `pyproject.toml` or `pytest.ini` → `pytest`
- `Cargo.toml` → `cargo check && cargo test`
- `Makefile` with `test` target → `make test`
- Nothing found → skip smoke test, proceed to Codex

### Time-Boxed Iterations

Wrap builder and reviewer calls in `timeout` commands.

- `BUILD_TIMEOUT=300` (5 min) — forces right-sized stories
- `REVIEW_TIMEOUT=180` (3 min) — generous for read + test
- `MAX_TURNS=15` (down from 30) — tighter turn budget
- Timeout treated as empty output → revert + retry

### Updated Loop

```
ralph.sh
  ├─ Pick next story from prd.json
  ├─ PHASE 1: BUILD (Claude Code, 5 min timeout, 15 max turns)
  ├─ PHASE 2: SMOKE TEST (auto, no agent)
  │     FAIL → revert, feed errors to builder, skip Codex
  │     PASS → continue
  ├─ PHASE 3: REVIEW (Codex, 3 min timeout)
  │     PASS → commit, mark done
  │     FAIL → revert, save feedback, retry
  └─ Next iteration
```

### New Config Vars

```bash
BUILD_TIMEOUT=300
REVIEW_TIMEOUT=180
MAX_TURNS=15
SMOKE_TEST=""  # auto-detect or custom
```

### New prd.json Field (optional)

```json
"smokeTest": "npm test && npx tsc --noEmit"
```

## Iteration Timing

- Build: ~5 min | Smoke test: ~30s-2min | Review: ~3 min | Overhead: ~30s
- Per iteration: ~9-10 min
- 5-story PRD: ~50-90 min
- Overnight (50 iterations): ~8 hours
