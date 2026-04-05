# yanfu

> Give every AI coder a strict father.

**yanfu** is a Claude Code template that automatically triggers an E2E validation agent every time your coding agent tries to say "Done." Not a code reviewer -- a QA engineer that opens the browser, submits forms, hits APIs, and queries your database.

## The Problem

AI coding agents (Claude Code, Codex, Cursor) write code, run unit tests, and declare victory. But "code compiles + tests pass" does not mean "feature works."

A real developer adding a phone number field would:
1. Open the page, check it renders correctly
2. Fill the form, submit, see if it works
3. Check the API received the data
4. Query the database to confirm persistence
5. Refresh the page to verify data loads back

**AI skips all of this 90% of the time.** Not because it can't -- it has Playwright MCP, terminal access, database tools. It skips because nobody told it that "Done" means all of the above.

yanfu fixes this by intercepting every "Done" and forcing a real QA pass.

## How It Works

```
Coder Agent (Claude Code) writes code
        |
        v tries to stop
   +---------+
   | Stop Hook| <-- yanfu intercepts here
   +----+----+
        v
  +---------------------------+
  |   yanfu QA Agent          |
  |                           |
  | 1. Reads task + git diff  |
  | 2. Determines what to     |
  |    validate (dynamic,     |
  |    not hardcoded rules)   |
  | 3. Executes validations:  |
  |    - Playwright -> render  |
  |    - Playwright -> interact|
  |    - curl -> API verify    |
  |    - SQL -> DB check       |
  | 4. Collects evidence      |
  | 5. Verdict: PASS or FAIL  |
  +---------------------------+
              |
    PASS -> exit 0 -> truly done
    FAIL -> exit 2 -> coder must fix, then retry
```

The QA agent is not a linter. It's not reading your diff and guessing. It **runs your application and checks it works**, the same way a human QA engineer would.

## What Makes yanfu Different

| | Code Review Tools | Smoke Tests | **yanfu** |
|---|---|---|---|
| How it validates | Reads diff | Fixed checks | **Dynamic E2E based on task semantics** |
| Who decides what to check | Hardcoded rules | Hardcoded rules | **AI infers from task + diff** |
| Opens a browser | No | Yes (basic) | **Yes -- simulates real user flows** |
| Queries database | No | No | **Yes -- when changes touch data layer** |
| Hits APIs | No | No | **Yes -- when changes touch API layer** |
| Adapts per task | No | No | **Yes -- every validation plan is unique** |

## Quick Start

### Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI installed
- [Playwright MCP](https://github.com/microsoft/playwright-mcp) configured (for browser validation)
- Your project's dev server runnable locally

### Install

```bash
# From your project root:
curl -sSL https://raw.githubusercontent.com/spytensor/yanfu/main/install.sh | bash
```

Or manually:

```bash
# 1. Copy the hook configuration
cp yanfu/.claude/settings.json .claude/settings.json
# (merge with existing settings.json if you have one)

# 2. Copy the hook script
cp yanfu/.claude/hooks/yanfu-gate.sh .claude/hooks/yanfu-gate.sh
chmod +x .claude/hooks/yanfu-gate.sh

# 3. Copy the QA agent definition
mkdir -p .claude/agents
cp yanfu/agents/yanfu-qa.md .claude/agents/yanfu-qa.md

# 4. Add yanfu rules to your CLAUDE.md (optional but recommended)
cat yanfu/CLAUDE.md.template >> CLAUDE.md
```

### Configure for Your Project

Edit `.claude/hooks/yanfu-gate.sh` to set your project-specific values:

```bash
# Your dev server URL
DEV_SERVER_URL="http://localhost:3000"

# Database query command (optional)
DB_QUERY_CMD="psql -U postgres -d myapp -c"
```

### Configure Playwright MCP

yanfu's QA agent uses Playwright MCP for browser validation. The `claude -p` subagent inherits MCP servers from your project or user-level settings. Add Playwright MCP to `.claude/settings.json`:

```json
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["@anthropic-ai/playwright-mcp@latest"]
    }
  },
  "hooks": {
    "...": "..."
  }
}
```

Or add it to `~/.claude/settings.json` to make it available across all projects.

## Architecture

### The Stop Hook

When Claude Code's coder agent finishes work and tries to hand control back to you, yanfu's Stop hook intercepts. It reads the JSON payload from stdin (provided by Claude Code) and collects five pieces of context:

1. **Original user task** -- extracted from the session transcript (the first user message)
2. **Coder agent's completion message** -- what the agent claims it did (`last_assistant_message` from the Stop hook input)
3. **Git diff** -- what actually changed in the code
4. **Change scope** -- which layers were affected (frontend, backend, database, config)
5. **Project context** -- framework type, CLAUDE.md contents, dev server URL

All of this is passed to the QA agent, so it knows both what was asked and what was done. This is critical -- without the task context, the QA agent would only see the diff and have to guess the intent.

**Dependency**: `jq` is recommended for reliable JSON parsing. Without it, the hook uses a regex fallback that handles simple cases but may miss multiline messages.

### The QA Agent

The QA agent is a separate Claude instance with a strict QA persona. It has access to:

- **Playwright MCP** -- browser control (navigate, click, fill forms, screenshot)
- **Terminal** -- run commands (curl, database queries, test suites)
- **File system** -- read configs, check file existence

The agent:

1. Analyzes the task + diff to determine which layers were affected (UI, API, DB, all)
2. Generates a dynamic validation plan (not hardcoded -- inferred from context)
3. Executes each validation step, collecting evidence (screenshots, responses, query results)
4. Returns PASS (exit 0) or FAIL with specific feedback (exit 2)

If FAIL, the feedback is injected back into the coder agent's context, forcing it to address the issues before trying to complete again.

### Validation Layers

yanfu validates across the full stack, but only the layers that are relevant to each change:

```
+---------------------------------------------+
| Layer 4: Data Persistence                   |
| Database queries, file system checks,       |
| cache verification                          |
+---------------------------------------------+
| Layer 3: API / Backend                      |
| HTTP requests, response schema validation,  |
| error handling, auth flows                  |
+---------------------------------------------+
| Layer 2: User Interaction                   |
| Form submission, button clicks, navigation, |
| error states, loading states                |
+---------------------------------------------+
| Layer 1: Visual Rendering                   |
| Page loads, component renders, no console   |
| errors, layout correctness                  |
+---------------------------------------------+
| Layer 0: Build & Types (always runs)        |
| TypeScript, linting, unit tests, build      |
+---------------------------------------------+
```

The QA agent determines which layers to validate based on the git diff:

- Changed `.tsx`/`.vue`/`.svelte` -> Layers 0-2 minimum
- Changed API routes/handlers -> Layers 0, 3
- Changed migrations/schema -> Layers 0, 3-4
- Changed form + API + migration -> All layers (full-stack change)

## Examples

See the `examples/` directory for project-specific configurations:

- **[Next.js + Prisma](examples/nextjs-prisma.md)** -- Full-stack React with database
- **[Express + PostgreSQL](examples/express-postgres.md)** -- REST API with SQL database
- **[Django + DRF](examples/django-drf.md)** -- Python full-stack
- **[Astro + Supabase](examples/astro-supabase.md)** -- Static site with backend-as-a-service

## Configuration

### Adjusting Strictness

In `.claude/agents/yanfu-qa.md`, you can adjust the QA agent's strictness:

```markdown
## Strictness Level: strict (default)

- strict: Validate ALL affected layers. Any failure blocks completion.
- moderate: Validate critical paths only. Warnings don't block.
- smoke: Quick checks only -- page loads, no console errors, types pass.
```

### Skipping Validation

For trivial changes (typos, comments, formatting), the QA agent automatically detects low-risk diffs and fast-tracks with a smoke check only.

To manually skip yanfu for a session:

```bash
YANFU_SKIP=1 claude
```

### Cost Considerations

yanfu spawns a separate Claude instance for each validation pass. Typical cost:

- Simple frontend change: ~5K tokens (Layer 0-1 only)
- Full-stack feature: ~15-25K tokens (all layers)
- Average across mixed workload: ~10K tokens per validation

The QA agent is designed to be efficient -- it validates only what changed, not the entire application.

## How This Relates to Existing Tools

yanfu builds on top of the existing ecosystem:

| Tool | Role in yanfu |
|------|--------------|
| [Playwright MCP](https://github.com/microsoft/playwright-mcp) | Browser control for the QA agent |
| [Claude Code Hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) | Stop hook mechanism for interception |
| Claude Code subagents | The QA agent runs as a subagent |

Inspired by:

- [claude-review-loop](https://github.com/hamelsmu/claude-review-loop) -- Stop hook + cross-model code review (but review only, no E2E)
- [super-smoke-test](https://github.com/nchemb/super-smoke-test) -- Stop hook + Playwright smoke (but shallow, no data flow validation)
- [Meta-Harness](https://arxiv.org/abs/2603.28052) -- The insight that `Agent = Model + Harness` and harness determines performance
- [Ralph](https://github.com/snarktank/ralph) -- Autonomous implement-verify-commit loop

yanfu fills the gap: **automated, dynamic, full-stack E2E validation as a Stop hook.**

## The Math

Why 90% of AI coding sessions fail to complete the full validation loop:

If the AI has an 85% chance of completing each validation step:
- 1 step: 85% success
- 3 steps: 61% success
- 5 steps: 44% success
- 10 steps: 20% success

The compound failure rate explains why AI agents that seem capable on individual tasks consistently fail at end-to-end workflows. yanfu breaks this by making validation **mandatory and automated** rather than optional and manual.

Source: [Verification Debt (ACM)](https://cacm.acm.org/blogcacm/verification-debt-when-generative-ai-speeds-change-faster-than-proof/)

## Philosophy

> "Everyone has a plan until they get punched in the mouth." -- Mike Tyson

Every AI coder has a plan until the strict father checks their homework.

The name yanfu (yan fu) means "strict father" in Chinese. In Chinese internet culture, it refers to the parent who never accepts "trust me, it works" -- they check everything themselves.

Your AI coder is the child. yanfu is the father. The child cannot leave the table until the father has verified the homework is actually correct.

## Contributing

This is an early-stage project. Contributions welcome:

- More framework examples (Vue, SvelteKit, Rails, Spring Boot, Go)
- Validation evidence report generation
- Cross-session learning (remember validation patterns per project)
- Integration with CI/CD pipelines
- Support for Codex and other coding agents

## License

MIT

## References

1. [Meta-Harness: End-to-End Optimization of Model Harnesses](https://arxiv.org/abs/2603.28052) -- Stanford IRIS Lab, 2026
2. [Verification Debt: When Generative AI Speeds Change Faster Than Proof](https://cacm.acm.org/blogcacm/verification-debt-when-generative-ai-speeds-change-faster-than-proof/) -- ACM, 2026
3. [The 80% Problem in Agentic Coding](https://addyo.substack.com/p/the-80-problem-in-agentic-coding) -- Addy Osmani
4. [Auto-Reviewing Claude's Code](https://www.oreilly.com/radar/auto-reviewing-claudes-code/) -- O'Reilly
5. [Spotify: Feedback Loops for Background Coding Agents](https://engineering.atspotify.com/2025/12/feedback-loops-background-coding-agents-part-3)
6. [Playwright MCP](https://github.com/microsoft/playwright-mcp) -- Microsoft
7. [claude-review-loop](https://github.com/hamelsmu/claude-review-loop) -- Hamel Husain
8. [super-smoke-test](https://github.com/nchemb/super-smoke-test)
