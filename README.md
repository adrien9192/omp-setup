# omp-setup

Install [omp](https://omp.sh) (Oh My Pi) with a configuration that works on the
first try, and with a second model from a different vendor reviewing the first
one's work while it codes.

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
| `tools.approvalMode` | `yolo` | `write` | `yolo` auto-approves shell execution *and* disables omp's own hard-coded guardrails (`rm -rf /`, fork bombs, fetch-then-execute). |
| `dev.autoqa` | `true` | `false` | Posts model-written free-text reports to `qa.omp.sh`; the payload can carry paths and code fragments. |
| `secrets.enabled` | `false` | `true` | Masks sensitive env vars and token patterns before the prompt reaches the provider. |
| `advisor.enabled` | `false` | `true` | The feature with no equivalent elsewhere: a second model reads the first one's diffs and reasoning as it works, and can interrupt. |
| `advisor.subagents` | `false` | `true` | Subagents are what write to files; the main turn only delegates. Reviewing the delegator alone guards an empty room. |
| `task.isolation.mode` | `none` | `apfs` / `auto` | Otherwise up to 32 concurrent agents write into one directory and silently overwrite each other. |
| `task.agentModelOverrides` | empty | 7 agents mapped | Without it every subagent 404s on a retired model and burns a full round trip before recovering. |
| `marketplace.autoUpdate` | — | `notify` | Plugin code runs in-process, with no sandbox. |

No per-tool `approval` rules, deliberately. A `{bash: prompt}` rule does not
block execution — measured, it relocates it to the Python kernel, which
executes the same command unvalidated. See [PITFALLS.md](PITFALLS.md#5).

---

## Options

Override any of these on the command line:

```bash
OMP_APPROVAL_MODE=yolo OMP_EFFORT=max bash install.sh
```

| Variable | Default | Notes |
|---|---|---|
| `OMP_DOER` | `anthropic/claude-opus-5` | The model that does the work. |
| `OMP_ADVISOR` | `openai-codex/gpt-5.6-sol` | The reviewer. Set empty to run single-model. |
| `OMP_CHEAP` | `anthropic/claude-haiku-4-5` | Commits, summaries, read-only exploration. |
| `OMP_EFFORT` | `high` | `low`…`max`. Applies to every turn, including trivial ones — it burns subscription quota fast. |
| `OMP_APPROVAL_MODE` | `write` | `always-ask`, `write`, or `yolo`. |

**On `yolo`:** it is a real choice, not a mistake, if you accept that the
advisor becomes your only remaining control. Pair it with the isolation this
installer already sets, so a runaway agent damages a disposable clone rather
than your tree.

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

---

## Verifying it actually worked

The installer's verification block must print no `FAIL`. Beyond that, two
checks worth doing yourself on the first real task:

**The advisor is reviewing subagents** when a `__advisor.jsonl` file appears
inside a subagent's **own** directory under
`~/.omp/agent/sessions/<project>/<session>/<AgentName>/`, not merely at the
session root.

**Model resolution is clean** when a run that delegates produces zero
`not_found_error` in its output.

---

## Requirements

macOS or Linux, `curl`, and `git`. bun is installed for you if missing.

Node is not enough: omp declares `"engines": {"bun": ">=1.3.14"}` and 105 of its
files import `bun:*` builtins.

---

## Licence

MIT. Not affiliated with the omp project.
