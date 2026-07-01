# Project: {project-name}

## Pipeline Status

```yaml
stage: idle          # idle | idea-discovery | implementation | training | review | paper
idea: ""             # Current idea title (one line)
contract: ""         # Path to research_contract.md (e.g., idea-stage/docs/research_contract.md)
current_branch: ""   # Git branch for this idea
baseline: ""         # Baseline numbers for comparison
training_status: idle  # idle | running | complete | failed
language: en         # en | zh — controls skill output language (see shared-references/output-language.md)
active_tasks: []
next: ""             # Concrete next step
last_updated: ""     # YYYY-MM-DD HH:mm — auto-updated by skills on every output write
```

## Project Constraints

- {constraint 1}
- {constraint 2}

## Non-Goals

- {non-goal 1}

## Compute Budget

- {budget details, e.g., "8x A100 for 24h via vast.ai"}

## ARIS Paseo

> Optional. Controls the paseo parent-child agent execution substrate. If
> omitted, the pipeline falls back to in-process `Skill` + `mcp__codex__codex`
> with no change to the verdict or audit chain. Paste the full block from
> [`templates/CLAUDE_MD_PASEO_SECTION.md`](../templates/CLAUDE_MD_PASEO_SECTION.md)
> and edit the values; see that file for per-variable detail.

```yaml
orchestrator_provider: claude/sonnet-4-6
executor_provider:     claude/sonnet-4-6
executor_mode:          auto
reviewer_provider:      codex/gpt-5.5
reviewer_mode:          full-access
reviewer_thinking:      xhigh
notify_on_finish:       true
fanout_subagents:       true
subagent_workspace:     current
heartbeat_cron:         off
```
