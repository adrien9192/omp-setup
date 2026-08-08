# omp-setup

Install [omp](https://omp.sh) (Oh My Pi) with a configuration that works on the
first try, and with a second model from a different vendor reviewing the first
one's work while it codes.

> **This installs omp in `yolo` mode: nothing you ask it to do gets validated
> first.** That is deliberate — approving every shell command is what makes
> people abandon the tool, and it is what omp ships by default anyway. What
> contains it: delegated work runs in a throwaway clone, and `ompw` (shipped
> here) puts the main turn in a disposable git worktree too. Run
> `OMP_APPROVAL_MODE=write bash install.sh` if you want to be prompted before
> shell commands instead. Details below.

The factory defaults are not the ones you want on a client repository. Three of
them act from the very first session, so the configuration has to be in place
**before** you launch. That is why this is an installer and not a checklist.

Everything it does differently from the official install is there because the
default was measured failing. Each measurement is in [PITFALLS.md](PITFALLS.md).

---

## Install it with one prompt

Paste this into any coding agent (Claude Code, omp itself, Codex, Cursor):

```
Install omp using https://github.com/adrien9192/omp-setup

Steps, in order:
1. git clone https://github.com/adrien9192/omp-setup /tmp/omp-setup
2. Read /tmp/omp-setup/install.sh in full before running it. It installs a
   package globally and writes ~/.omp/agent/config.yml.
3. Run: bash /tmp/omp-setup/install.sh
4. Report exactly what the verification block printed. Every line must pass.
   If any line says FAIL, stop and show me the output. Do not work around it.

Then tell me the two /login commands it printed at the end. Do not try to run
them yourself: OAuth is a browser flow and cannot be scripted.

Finally, relay the yolo warning the installer prints, verbatim, so I know what
was installed. Do not summarise it away.
```

Or, without an agent:

```bash
git clone https://github.com/adrien9192/omp-setup && bash omp-setup/install.sh
```

Re-running it is safe. Any existing config is backed up first.

---

## Then, once, by hand

Login is a browser OAuth flow. Nothing can script it.

```bash
omp
/login anthropic       # the doer
/login openai-codex    # the reviewer
```

Two vendors on purpose. A second model reviewing the first is only worth its
tokens if it does not share the first one's blind spots.

---

## What you get

| Setting | Factory | Here | Why |
|---|---|---|---|
| `tools.approvalMode` | `yolo` | `yolo` | Kept. Nothing is validated, and omp's hard-coded guardrails (`rm -rf /`, fork bombs, fetch-then-execute) are bypassed. The isolation and advisor rows below are what make that survivable. |
| `dev.autoqa` | `true` | `false` | Posts model-written free-text reports to `qa.omp.sh`; the payload can carry paths and code fragments. |
| `secrets.enabled` | `false` | `true` | Masks sensitive env vars and token patterns before the prompt reaches the provider. |
| `advisor.enabled` | `false` | `true` | The feature with no equivalent elsewhere: a second model reads the first one's diffs and reasoning as it works, and can interrupt. |
| `advisor.subagents` | `false` | `false` | Kept off. Turning it on runs the advisor inside every subagent: measured 3.6M advisor tokens off vs 161.8M on, a weekly subscription gone in half a day. See [PITFALLS #8](PITFALLS.md). |
| `task.isolation.mode` | `none` | `apfs` / `auto` | Otherwise up to 32 concurrent agents write into one directory and silently overwrite each other. |
| `task.agentModelOverrides` | empty | 7 agents mapped | Without it every subagent 404s on a retired model and burns a full round trip before recovering. |
| `marketplace.autoUpdate` | — | `notify` | Plugin code runs in-process, with no sandbox. |
| `retry.usageAwareFallback` | `false` | `true` | Without it, running out of quota is silent: the advisor dies, the run continues, and you believe you are still supervised. |
| main-turn isolation | none, and no setting for it | `ompw` | A shell function shipped here: worktree, branch, diff on exit, merge on your word. |

No per-tool `approval` rules, deliberately. A `{bash: prompt}` rule does not
block execution — measured, it relocates it to the Python kernel, which
executes the same command unvalidated. See [PITFALLS.md](PITFALLS.md#5).

---

## Options

Override any of these on the command line:

```bash
OMP_APPROVAL_MODE=write OMP_EFFORT=max bash install.sh
```

| Variable | Default | Notes |
|---|---|---|
| `OMP_DOER` | `anthropic/claude-opus-5` | The model that does the work. |
| `OMP_ADVISOR` | `openai-codex/gpt-5.6-sol` | The reviewer. Set empty to run single-model. |
| `OMP_CHEAP` | `anthropic/claude-haiku-4-5` | Commits, summaries, read-only exploration. |
| `OMP_EFFORT` | `high` | `low`…`max`. Applies to every turn, including trivial ones — it burns subscription quota fast. |
| `OMP_APPROVAL_MODE` | `yolo` | `always-ask`, `write`, or `yolo`. |

**On `yolo`, which is the default here:** it is a real choice, not an oversight.
Approving every shell command is the friction that makes people stop using an
agent, so the trade is made once, up front, rather than fifty times a day.

Know exactly what it trades. Delegated subagents are contained: they work in a
copy-on-write clone and only their diff comes back. **omp has no setting that
isolates the main turn** — checked: `task.isolation` covers delegated work only,
`--cwd` just moves the start directory. So the agent issuing the most shell
commands was the one with no containment at all.

`ompw`, installed alongside, closes that from the outside: it creates a git
worktree and a branch, runs omp there, shows you the diff when it exits, and
merges only if you say so. Use `ompw` instead of `omp` inside a repository.

The advisor reviews the main turn, and only it: extending it to subagents is
what costs a weekly quota (PITFALLS #8).

So: keep your work committed, and prefer `OMP_APPROVAL_MODE=write` on a
repository whose loss would actually hurt. Switching later needs no reinstall:

```bash
omp config set tools.approvalMode write
```

**On `max`:** more reasoning budget helps on hard problems, and costs on every
turn that is not one. Watch your weekly quota rather than the clock.

---

## Does the second model earn its tokens?

Measured over one real 35-turn audit:

| | Turns | Tokens | Cost equivalent |
|---|---|---|---|
| Primary | 35 | 7,607,636 | $7.98 |
| Advisor | 50 | 724,663 | $0.86 |

**About 10% of the tokens, 11% of the cost.** It stays that low because 88% of
its input comes from cache — it reads the delta since its last pass, not the
whole context.

That figure is published nowhere. Check your own with `/advisor status` after
real work, or read `usage.cost` in `__advisor.jsonl`.

Note the honest part: on that particular audit the advisor raised **zero**
objections across 48 review turns. That can mean the work was sound, or that it
did not bite. One run cannot tell you which.

**And note the trap in that number.** It was measured with `advisor.subagents`
off. Using it to justify turning that setting on is reasoning from a measurement
the change invalidates — on 2026-08-08 that exact mistake turned 3.6M advisor
tokens into 161.8M and exhausted a weekly subscription in half a day. Change one
multiplier at a time, and measure a full session between each.

---

## Verifying it actually worked

The installer's verification block must print no `FAIL`. Beyond that, two
checks worth doing yourself on the first real task:

**The advisor is running** when `__advisor.jsonl` appears at the root of the
session directory under `~/.omp/agent/sessions/<project>/<session>/`, with a
non-zero turn count. If the same file also appears inside a **subagent's own**
folder, `advisor.subagents` is on — check your token counts before running
anything wide.

**Model resolution is clean** when a run that delegates produces zero
`not_found_error` in its output.

---

## The lever that beats the harness

Measured on 2026-08-08: two harnesses audited the same commit. One returned 17
findings for 21M tokens. Ten agents carrying an explicit output contract
returned ~70 for 1.7M — 8% of the cost, five times the findings, same models on
both sides.

The delta was not the harness. It was what each agent was asked to return.
[FINDINGS-CONTRACT.md](FINDINGS-CONTRACT.md) is those six clauses, ready to
paste into any subagent prompt.

---

## Requirements

macOS or Linux, `curl`, and `git`. bun is installed for you if missing.

Node is not enough: omp declares `"engines": {"bun": ">=1.3.14"}` and 105 of its
files import `bun:*` builtins.

---

## Licence

MIT. Not affiliated with the omp project.
