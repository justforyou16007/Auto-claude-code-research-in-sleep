# Paseo Sub-Agent Dispatch

When an ARIS workflow skill needs to delegate a unit of work — a sub-skill,
a workflow phase, an audit, a fan-out shard — it does so by **spawning a
paseo child agent** rather than by making an in-process `Skill`-tool call.
This document is the canonical convention for doing that **without**
weakening the cross-model jury, the acceptance gate, the reviewer
independence, or the run-state machine that the entire ARIS design rests on.

Rule of thumb: **a parent agent dispatches the unit; it never dispatches the
verdict.** Fan out sub-skills (independent units of work). Never fan out the
loop iterations of a verdict-bearing skill — keep those inside one
long-lived agent (see `external-cadence.md`, the fence).

This is the **executor** dispatch pattern (claude parent → claude child).
The **reviewer** dispatch pattern (claude parent → codex child, GPT-5.5) is
the cross-model jury step and lives in its own doc:
[`paseo-reviewer-dispatch.md`](paseo-reviewer-dispatch.md). The two share
the lifecycle / continuity / fanout discipline below; only the provider and
independence rules differ.

## Why this contract exists

ARIS today chains sub-skills inside one Claude session via synchronous
`Skill`-tool calls. That works, but it (a) holds the whole workflow in one
context window, (b) gives the orchestrator no survival across a session
crash, and (c) fuses the executor and the reviewer onto one substrate.
Paseo parent-child agents replace the synchronous `Skill` call with a
durable, observable agent boundary: the child runs in its own context, the
parent is notified on completion, and either layer can crash and resume
without losing the other.

The risk this contract guards against is the same one
`integration-contract.md` and `fan-out-pattern.md` already name: **prose
can describe an integration; it cannot guarantee one.** "MUST invoke X via
paseo" without a canonical spawn shape, a continuity rule, and a lifecycle
policy will drift the moment a workflow author is under context pressure.
So this document fixes the shape once.

## Verified paseo semantics (load-bearing)

These were read from `third_parties/paseo/` (untouched) and are the
foundation everything below rests on:

- **`create_agent` = fresh context; `send_agent_prompt` to the SAME agent =
  continuation.** A paseo agent holds its own conversation thread. First
  prompt opens it; subsequent prompts to the same `agentId` continue it.
  This is the exact analog of `mcp__codex__codex` (fresh) vs
  `codex-reply` (continuation).
- **`relationship: {kind: "subagent"}` cascade-archives.** A subagent is
  owned by its parent; archiving the parent archives its children. Use
  `subagent` for every workflow child (W-agents, sub-skills, reviewers) so
  the tree prunes cleanly.
- **`workspace: {kind: "current"}` shares the project dir.** All children
  read/write the same `paper/`, `idea-stage/`, `.aris/runs/`,
  `.aris/traces/` paths the parent uses. Use `current` unless a child
  needs isolation (experiments that mutate the repo — see `subagent_workspace`).
- **`notifyOnFinish: true` is push.** The parent does NOT call
  `wait_for_agent` on a notify agent (that re-blocks the parent and
  defeats the point). It continues other work and reacts to the child's
  `<paseo-system>` notification when it lands.
- **`replaceRunning: true` on notifications.** A child's
  `notifyOnFinish` turn can preempt the parent's in-flight turn. So the
  parent's notification-handling turn must be SHORT (read the artifact
  file, append to results, return) and the authoritative payload must be a
  FILE the child writes — not the `<agent-response>` text (which is only
  the last contiguous assistant run and can be lost to preemption).
- **Cross-provider spawn needs explicit `settings.modeId`.** A claude
  parent spawning a codex child MUST pass `modeId` — cross-provider mode
  inheritance throws. See the reviewer doc.

## The executor sub-agent spawn shape

Every workflow SKILL that delegates a sub-skill or a phase spawns it with
this canonical shape. The variables come from the user project's CLAUDE.md
`## ARIS Paseo` block (see `templates/CLAUDE_MD_PASEO_SECTION.md`); defaults
are shown.

```
mcp__paseo__create_agent:
  relationship: {kind: "subagent"}
  workspace:    {kind: "current"}        # or "create" + worktree for isolated experiment runs
  title:        "<skill> :: <phase> :: <run_id>"
  provider:     "<executor_provider>"      # default claude/sonnet-4-6
  settings:
    modeId:           "<executor_mode>"   # default "auto"
    thinkingOptionId: "<executor_thinking>"  # model default; "xhigh" only when the skill demands
  initialPrompt: |
    <rendered prompt — see contract below>
  notifyOnFinish: true                    # push; do NOT wait_for_agent
```

### The `initialPrompt` contract

The child's prompt points at a **workflow definition** (a SKILL.md) and
binds it to **this run's context**. It does not paraphrase the workflow —
it hands the child the skill path and the run's variables, and tells it
where to write its completion receipt. Concretely:

```
You are an ARIS workflow sub-agent. Execute the workflow defined in:

    skills/<leaf>/SKILL.md

Run context (this run, do not re-derive):
  - run_id:        <run_id>
  - phase:         <phase-name>            # e.g. idea-discovery
  - project root:  <cwd>                  # workspace:{kind:"current"} shares this
  - CLAUDE.md vars: read the ## ARIS Paseo + ## ARIS sections of ./CLAUDE.md

Operating rules (non-negotiable):
  1. Resolve every helper via integration-contract.md §2 (.aris/tools → tools → $ARIS_REPO/tools). Never hardcode a path.
  2. Write artifacts to the standard stage dir for this phase (per the SKILL's output protocol). Do NOT write elsewhere.
  3. When you need the GPT-5.5 reviewer, spawn/continue a paseo codex sub-agent per paseo-reviewer-dispatch.md (NOT mcp__codex__codex).
  4. Do NOT call run_state.py accept. You may `set done --artifact <path>`; acceptance is the orchestrator's job (acceptance-gate.md).
  5. On completion, write the receipt file below and stop. Do not call accept, do not start the next phase.

Receipt (write this last, to .aris/runs/<run_id>.<phase>.done.json):
  { "phase": "<phase>", "artifact_path": "<abs path>", "summary": "<1-3 lines>",
    "next_step": "<suggested next phase or null>", "reviewer_used": "<codex-agent-id or null>" }
```

Why a receipt file (and not `<agent-response>`): the orchestrator reads the
receipt in its SHORT notification turn, preemption-safe. The file is the
observable side effect (`integration-contract.md` §3 — "the model said it
ran" is not a receipt). `run_state.py` is unchanged; the orchestrator uses
the receipt's `artifact_path` for `set done` and its own gate result for
`accept`.

## The two continuity modes (the core of the migration)

A parent agent continues a child in exactly two ways, mirroring today's two
codex call types:

| Today | After migration | Used by |
|---|---|---|
| `mcp__codex__codex` (fresh thread) | **create a NEW paseo child agent** | every sub-skill dispatch; every fresh-reviewer round (bias guard); every audit layer |
| `mcp__codex__codex-reply` (same threadId) | **`send_agent_prompt` to the SAME agent** | multi-round reviewer continuation (`auto-review-loop` round 2+); `idea-creator` devil's-advocate triage; `research-review` follow-ups |

**For executor sub-agents, the default is fresh.** A sub-skill like
`/research-lit` or `/proof-checker` is dispatched as a new child each time
it is needed — independent context, no carryover. Continuation
(`send_agent_prompt` to the same agent) is the **exception**, reserved for
the cases in the table, and always carries reviewer-memory semantics — see
the reviewer doc.

**Never recreate a verdict-bearing loop's claude agent per round.**
`auto-review-loop` (W2) and `auto-paper-improvement-loop` are ONE paseo
claude agent that loops rounds 1→N internally. The claude agent is created
once; what changes per round is whether the *codex reviewer* it dispatches
is fresh (paper-improvement bias guard) or continued (auto-review-loop r2+).
This is the fence (`external-cadence.md`) made operational: the loop's
internal round cadence is owned by one long-lived agent, not re-entered from
the top on a timer.

## Parallel fan-out discipline

When a workflow fans out N independent units (idea lenses, audit layers,
per-source retrieval), the parent spawns N children concurrently. The
invariants below are the preemption-safe subset of `fan-out-pattern.md`:

1. **Each child writes its result to its OWN file** on the shared workspace
   (`workspace:{kind:"current"}`). The parent reads files in its
   notification turns — never the `<agent-response>` text. A later child's
   notification can preempt the parent mid-turn (`replaceRunning:true`); a
   file on disk survives that, an in-memory variable does not.
2. **Parent notification turns are SHORT.** Read the artifact file, append
   to a results manifest, return. Do not deliberate, do not call accept,
   do not spawn more children from inside a notification turn. Long
   notification turns raise the chance the next child's notify preempts
   unfinished state.
3. **Fan out the search, never the bench.** Children GENERATE candidates
   (ideas, attack points, draft sections, audit findings); they NEVER
   render the acceptance verdict (`fan-out-pattern.md`). Quality/correctness
   verdicts stay a single cross-model codex sub-agent step per
   `paseo-reviewer-dispatch.md`.
4. **Mechanical merge/dedup on the parent only.** After all N children
   notify, the parent merges the candidate files and dedups
   judgment-free, exactly as today (`fan-out-pattern.md` §dedup). This is
   safe same-model work.
5. **Cascade-archive cleans up.** Children spawned as `subagent` are
   pruned when the parent is archived; the parent need not track every
   child id for cleanup (though it should for tracing — see below).

## Child lifecycle (用完即 archive / 用即留)

Two lifecycles, chosen by whether the child holds durable continuity:

- **Fresh-purpose child (the common case): archive as soon as its verdict
  / artifact is read.** A one-shot sub-skill agent, a fresh-reviewer codex
  agent, a single audit pass — `archive_agent` it the moment the parent
  has read its receipt and (for reviewers) run `save_trace.sh`. The full
  review history stays auditable via `.aris/traces/<skill>/...` (Policy C
  forensic) + the artifact JSON, NOT via live agent records. No
  fresh-purpose agent accumulates past its turn.
- **Continuation child: keep alive until its loop terminates, then archive.**
  `auto-review-loop`'s codex reviewer agent (round 2+ continues it) stays
  alive across rounds — it IS the thread — and is `archive_agent`-ed only
  when the loop ends (PASS/FAIL/BLOCKED). The claude W2 agent that owns it
  is likewise one long-lived agent, archived when the orchestrator accepts
  the phase.

A parent that spawns a fresh-purpose child and then forgets to archive it
leaves a live agent record that (a) can still receive stray prompts and (b)
clutters `list_agents` on resume. **Archive on read** for fresh-purpose
children — this is the 用完即 archive rule. Cascade-archive then prunes any
grandchildren the child had spawned.

## Permission handling (overnight autonomy)

`executor_mode` (CLAUDE.md `## ARIS Paseo`) selects the child's autonomy:

- `auto` (default) — workspace-write, on-request approvals. The parent
  handles the child's permission requests via `list_pending_permissions`
  + `respond_to_permission`, OR the human approves interactively.
- `bypassPermissions` — overnight autonomy. No approval round-trips; the
  child runs unattended. Use this for overnight pipelines where no human
  is watching.
- `plan` — read-only planning; never for a workflow phase that must write
  artifacts.

When `executor_mode: auto` and a child raises a permission request, the
parent is notified (`wait_for_agent` returns the pending request). The
parent should respond promptly so the child is not blocked overnight — but
must NOT use permission approval as a covert way to inject guidance into a
reviewer child (that violates `reviewer-independence.md`).

## Cross-provider gotcha (recap)

When the executor (claude) spawns a **codex** reviewer child, the spawn
MUST pass explicit `settings.modeId` — cross-provider mode inheritance
throws. This is the single most common spawn bug. Full detail and the exact
codex spawn shape are in `paseo-reviewer-dispatch.md`; it is mentioned here
only so an executor-author who copy-pastes the claude shape for a reviewer
is warned before they hit it.

## Resume: re-attach or recreate

On `/research-pipeline — resume <run_id>`, the orchestrator's job is to
restore each phase's child agent if possible:

1. `run_state.py resume <run_id>` → first non-terminal phase.
2. `list_agents` — is that phase's W-agent (or reviewer) still alive?
   - **Alive** → re-attach: await its `notifyOnFinish` (do NOT re-prompt a
     verdict agent mid-run — the fence; only await).
   - **Dead / archived** → `create_agent` fresh. The W-agent's startup reads
     `REVIEW_STATE.json` / `PAPER_IMPROVEMENT_STATE.json` and resumes from
     saved round+1, recreating the codex reviewer agent by reading its
     persisted agent-id if still alive (continuation preserved), else a
     fresh codex agent (reviewer memory may be lost — same risk as today's
     codex-server-restart; the trace files survive, the live thread may not).

The orchestrator never judges quality on resume — it reads on-disk
artifacts, runs the gate, calls `run_state.py accept`. The
`run_state.py` self-acquittal tripwire (`accept` warns on a `claude*`
reviewer) is the backstop.

## Auto-skip-if-unconfigured (graceful degradation)

Paseo is an additive substrate, never load-bearing on the verdict. If the
paseo MCP server is unavailable (the tools `mcp__paseo__create_agent` etc.
are not present), the workflow falls back to today's behavior with **no
change to the jury**:

- Executor sub-skill dispatch → in-process `Skill`-tool call (Tier 3
  sequential, per `fan-out-pattern.md`).
- Cross-model reviewer → `mcp__codex__codex` / `codex-reply` per
  `reviewer-routing.md`.

Detect once at orchestrator startup: probe for `mcp__paseo__list_agents`
(or any paseo tool). If absent, set `fanout_subagents=false` for the run,
log a WARN, and proceed on the in-process path. The cross-model jury,
acceptance gate, audit chain, and `verify_paper_audits.sh` gate are
identical on either path — only the dispatch substrate changes. This is
the paseo analog of `fan-out-pattern.md`'s "degrade the dispatch, never
the verdict."

## Anti-patterns to refuse in review

- **"Spawn a fresh W2 agent each round."** Recreating a verdict-bearing
  loop's claude agent per round breaks its round-to-round state and is the
  fence violation (`external-cadence.md`). W2 is one agent looping
  internally.
- **"Pass the executor's summary in the reviewer's initialPrompt."**
  Violates `reviewer-independence.md`. Reviewer children get file paths
  only; executor children may receive run context but not pre-digested
  verdicts about quality.
- **"`wait_for_agent` on a `notifyOnFinish` child."** Re-blocks the parent
  and defeats the push model. Use the notification.
- **"Read the verdict from `<agent-response>`."** Not preemption-safe and
  only the last contiguous run. The verdict lives in a file the child
  writes; `<agent-response>` is a convenience for short status, not the
  authoritative payload.
- **"Forget to archive a fresh-purpose child."** Live agent records
  accumulate and can receive stray prompts. 用完即 archive.
- **"Let the heartbeat `send_agent_prompt` to a running verdict agent."**
  Interrupts it via `replaceRunning`. Heartbeat is Type-A only
  (`external-cadence.md`).

## Cross-references

- [`paseo-reviewer-dispatch.md`](paseo-reviewer-dispatch.md) — the
  cross-model codex reviewer spawn shape, fresh-vs-continuation rule, and
  the `save_trace.sh` `--thread-id <codex-agent-id>` contract. The jury
  half of this migration.
- [`fan-out-pattern.md`](fan-out-pattern.md) — fan-out is firepower; the
  jury is the bench. Paseo parallel fan-out is the Tier-1/2 dispatch
  mechanism; the verdict stays single and cross-model.
- [`external-cadence.md`](external-cadence.md) — the fence: do not wrap
  verdict-bearing loops in external cadence. Restated for the paseo driver:
  the heartbeat nudges Type-A only, never re-creates a running verdict agent.
- [`acceptance-gate.md`](acceptance-gate.md) — a parent can DRIVE (dispatch
  children, mark `done`); it cannot ACQUIT (call `accept` on its own
  family's quality verdict). Acceptance stays cross-model or deterministic.
- [`integration-contract.md`](integration-contract.md) — §2 helper
  resolution chain (children resolve helpers the same way); §3 the receipt
  file is the observable side effect.
- [`reviewer-independence.md`](reviewer-independence.md) — reviewer
  children get file paths only; the executor child may carry run context
  but never a pre-digested quality verdict.
- [`resumable-runs.md`](resumable-runs.md) — `run_state.py` done/accepted
  machine; resume re-attaches a live child or recreates a dead one.
