#!/bin/sh
# render_w_agent_prompt.sh — emit a paseo W-agent (or sub-agent) initialPrompt.
#
# Pure string templating. Does NOT touch tools/. Reads the user project's
# CLAUDE.md `## ARIS Paseo` block (optional — defaults if absent) and emits
# the initialPrompt contract defined in
# skills/shared-references/paseo-subagent-dispatch.md ("The initialPrompt
# contract") to stdout. The orchestrator (research-pipeline SKILL.md) reads
# this stdout and passes it as `initialPrompt` to mcp__paseo__create_agent.
#
# Why a script (not inline prose): the initialPrompt binds a workflow
# definition (a SKILL.md path) to a run's context deterministically. Prose
# would re-derive run_id / phase / root each time and drift. This is the
# integration-contract.md §2 "canonical helper" principle applied to the
# prompt itself — one implementation, every caller resolves + invokes it.
#
# Usage:
#   render_w_agent_prompt.sh \
#     --phase idea-discovery \
#     --run-id 2026-07-01_my-direction \
#     --root /path/to/project \
#     --skill skills/idea-discovery/SKILL.md \
#     [--extra "additional context, e.g. chosen idea title for W1.5"] \
#     [--role executor|reviewer]   # default executor; reviewer shape from paseo-reviewer-dispatch.md
#
# Resolve this script itself via the canonical chain (.aris/tools is NOT
# where skill scripts live; skill scripts live under skills/<skill>/scripts/
# per integration-contract.md "Layer 0"). Callers typically know the path
# directly. The orchestrator resolves it from $CLAUDE_SKILL_DIR or the
# skills/ tree.
#
# Exit codes: 0 = prompt emitted to stdout; 1 = usage error.

set -eu

phase=""
run_id=""
root=""
skill_path=""
extra=""
role="executor"

usage() {
    cat >&2 <<'EOF'
Usage: render_w_agent_prompt.sh --phase <phase> --run-id <run_id> --root <root>
                                  --skill <skill-path> [--extra "..."] [--role executor|reviewer]
EOF
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --phase)   phase="$2"; shift 2;;
        --run-id)  run_id="$2"; shift 2;;
        --root)    root="$2"; shift 2;;
        --skill)   skill_path="$2"; shift 2;;
        --extra)   extra="$2"; shift 2;;
        --role)    role="$2"; shift 2;;
        -h|--help) usage;;
        *) echo "unknown arg: $1" >&2; usage;;
    esac
done

[ -n "$phase" ]      || { echo "ERR: --phase is required" >&2; usage; }
[ -n "$run_id" ]     || { echo "ERR: --run-id is required" >&2; usage; }
[ -n "$root" ]       || { echo "ERR: --root is required" >&2; usage; }
[ -n "$skill_path" ] || { echo "ERR: --skill is required" >&2; usage; }
case "$role" in
    executor|reviewer) ;;
    *) echo "ERR: --role must be executor or reviewer" >&2; usage;;
esac

# --- Read CLAUDE.md `## ARIS Paseo` block (optional; defaults if absent). ---
# Tolerant: if CLAUDE.md is absent or the block is absent, use defaults.
# Paseo vars are orthogonal to effort/assurance (see templates/CLAUDE_MD_PASEO_SECTION.md).
claude_md="$root/CLAUDE.md"
executor_provider="claude/sonnet-4-6"
reviewer_provider="codex/gpt-5.5"
fanout_subagents="true"

if [ -f "$claude_md" ]; then
    # Extract the ## ARIS Paseo section (up to the next ## heading or EOF).
    paseo_block=$(awk '
        /^##[[:space:]]+ARIS[[:space:]]+Paseo/ {in_block=1; next}
        in_block && /^##[[:space:]]+/ {in_block=0}
        in_block {print}
    ' "$claude_md" 2>/dev/null || true)

    read_var() {
        # $1 = var name. Print the value from a "key: value" or "key: value # comment" line.
        printf '%s\n' "$paseo_block" \
            | grep -E "^[[:space:]]*$1[[:space:]]*:" \
            | head -n1 \
            | sed -E 's/^[^:]+:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' \
            | grep -v '^$' || true
    }

    v=$(read_var executor_provider);  [ -n "$v" ] && executor_provider="$v"
    v=$(read_var reviewer_provider);  [ -n "$v" ] && reviewer_provider="$v"
    v=$(read_var fanout_subagents);   [ -n "$v" ] && fanout_subagents="$v"
fi

# --- Emit the initialPrompt. ---
# Executor contract: paseo-subagent-dispatch.md "The initialPrompt contract".
# Reviewer contract: paseo-reviewer-dispatch.md "The initialPrompt contract"
#   (file-paths-only, no executor summary — the caller supplies paths via --extra).

if [ "$role" = "reviewer" ]; then
    # Reviewer prompt: the caller passes file paths + objective in --extra.
    # Independence is absolute (reviewer-independence.md): no executor summary.
    cat <<EOF
You are a senior cross-model reviewer (GPT-5.5). Review the work for run ${run_id}, phase ${phase}.

$extra

Read the listed files yourself; do not trust any summary. Emit a 6-state verdict
(PASS|WARN|FAIL|BLOCKED|ERROR|NOT_APPLICABLE) to a verdict file on the shared
workspace, then return a one-line status. Do not call run_state.py.

Review backend: ${reviewer_provider} (paseo codex sub-agent; see paseo-reviewer-dispatch.md).
EOF
    exit 0
fi

# Executor prompt.
extra_block=""
if [ -n "$extra" ]; then
    extra_block=$(printf '\nAdditional run context:\n%s\n' "$extra")
fi

cat <<EOF
You are an ARIS workflow sub-agent. Execute the workflow defined in:

    ${skill_path}

Run context (this run, do not re-derive):
  - run_id:        ${run_id}
  - phase:         ${phase}
  - project root:  ${root}   (workspace:{kind:"current"} shares this dir)
  - CLAUDE.md:     read ./CLAUDE.md — both the ## ARIS Paseo block (execution substrate)
                   and the ## ARIS / pipeline-status sections (research context)
${extra_block}
Operating rules (non-negotiable):
  1. Resolve every helper via integration-contract.md §2 (.aris/tools -> tools -> \$ARIS_REPO/tools). Never hardcode a path.
  2. Write artifacts to the standard stage dir for this phase (per the SKILL's output protocol). Do NOT write elsewhere.
  3. When you need the GPT-5.5 reviewer, spawn/continue a paseo codex sub-agent per skills/shared-references/paseo-reviewer-dispatch.md (NOT mcp__codex__codex). Fresh review = create_agent; continuation = send_agent_prompt to the same agent.
  4. Fan out sub-skills as paseo claude sub-agents per skills/shared-references/paseo-subagent-dispatch.md (fanout_subagents=${fanout_subagents}; if false, use in-process Skill-tool fallback).
  5. Do NOT call run_state.py accept. You may 'set done --artifact <path>'; acceptance is the orchestrator's job (acceptance-gate.md).
  6. On completion, write the receipt below and stop. Do not call accept, do not start the next phase.

Receipt (write this last, to ${root}/.aris/runs/${run_id}.${phase}.done.json):
  { "phase": "${phase}", "artifact_path": "<abs path>", "summary": "<1-3 lines>",
    "next_step": "<suggested next phase or null>", "reviewer_used": "<codex-agent-id or null>" }

Executor backend: ${executor_provider} (paseo claude sub-agent; see paseo-subagent-dispatch.md).
EOF
