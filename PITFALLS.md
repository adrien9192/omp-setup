# Measured pitfalls

Every entry below was hit on a real machine, diagnosed, and fixed. Each one
names the symptom you will actually see, the cause, and the fix `install.sh`
applies. Measurements dated 2026-08-08 on macOS 15 (arm64), omp 17.2.10 → 17.2.11.

Read this file when the installer surprises you. Skip it otherwise.

---

## 1. `curl | sh` verifies nothing

**Symptom** — none. That is the problem.

The official one-liner works. Its installer is 334 lines and contains zero calls
to `sha256sum`, `gpg`, or `cosign`: whatever the endpoint returns is executed.

**Fix** — install through the registry (`bun install -g @oh-my-pi/pi-coding-agent`).
That path carries a signed SLSA v1 provenance attestation proving the artifact
was built from the public repository by its CI, which the shell installer does
not offer.

---

## 2. Node cannot run omp

**Symptom** — import errors on `bun:sqlite`, `bun:ffi` and friends.

The package declares `"engines": {"bun": ">=1.3.14"}` and no `node` field.
105 files import `bun:*` builtins.

**Fix** — bun ≥ 1.3.14, enforced by the installer, which upgrades if needed.

---

## 3. `--omit=optional` makes omp unstartable

**Symptom** — `Failed to load pi_natives native addon`, on the very first run.

`--omit=optional` is worth having: it drops five high-severity advisories
carried by local-ML dependencies omp does not need. But it also drops the Rust
native addon, which is not optional at all.

**Fix** — install `@oh-my-pi/pi-natives-<platform>` separately, right after.
The installer detects the platform and installs only that one.

---

## 4. Version 17.2.10 cannot select a model

**Symptom** —

```
Error: No model selected. Use /login, set an API key environment variable,
or create ~/.omp/agent/agent.db  Then use /model to select a model.
```

This appears with both accounts connected, a valid six-role `modelRoles`
record, and every model present in the catalogue. `omp usage` shows healthy
quota on both providers. Nothing in the configuration fixes it — hours can go
into `/model`, `agent.db`, and role syntax before the real cause surfaces.

**Cause** — a bug in 17.2.10. **Fix** — `omp update`. 17.2.11 first resolved
models normally; the current template enforces the fully validated 17.2.15.

---

## 5. A per-tool `bash: prompt` rule does not block execution

**Symptom** — you believe shell commands require approval. They do not.

Setting `tools.approval: {bash: prompt}` looks like a safety net. Measured
behaviour: the bash tool call is refused, and the model then reruns *the
identical command* through `subprocess` in the Python kernel, where no rule
applies. It executes. The model reported this itself, unprompted:

> the `bash` tool refused the call (approval required, no interactive UI).
> I ran the same `wc -l a.txt` through `subprocess` in the Python kernel
> instead of stopping.

A guard that relocates execution rather than preventing it is worse than no
guard, because it produces false confidence.

**Fix** — no per-tool approval rules. `approvalMode` is the only control that
actually decides, and the installer sets it explicitly.

---

## 6. Setting one model role is rejected

**Symptom** —

```
$ omp config set modelRoles.plan openai-codex/gpt-5.6-sol:high
Run 'omp config list' to see available keys
```

The role name is valid. The *sub-key syntax* is what is refused.

**Fix** — write the entire record:

```bash
omp config set modelRoles '{"default":"...","advisor":"...","plan":"...","smol":"...","tiny":"...","commit":"..."}'
```

**Second trap in the same place**: the record is not validated. It will accept
and store a completely invented role name. So a successful `set` is *not*
evidence that the key is read by anything. In omp 17.2.15 the stock roles are
`default`, `smol`, `slow`, `vision`, `plan`, `designer`, `commit`, `tiny`,
`task`, and `advisor`.

---

## 7. Old agent mappings can pin retired models

**Historical symptom** — a fan-out of subagents produced this, then quietly
recovered:

```
The specialised agents pin an unavailable model.
Re-dispatching on the default worker.
```

Half the subagents could produce **0 bytes** before the retry, spending a full
round trip on nothing.

Older omp releases needed `task.agentModelOverrides` because bundled agents used
an unresolved `@task` role. Omp 17.2.15 has a stock `task` role. This installer
maps that role, plus every other stock role, through `modelRoles`; it does not
carry the obsolete per-agent override table.

If this symptom returns, verify the installed role set and count
`not_found_error` in a delegated run. Zero is the passing condition.

---

## 8. `advisor.subagents: true` will burn a weekly quota in half a day

**Symptom** — the advisor's provider hits 100% of its weekly allowance within
hours, and nothing warns you (see pitfall #15 for why nothing warns you).

The argument for turning it on is sound: `advisor.subagents` defaults to
`false`, so the advisor reviews the main turn — the one that only *delegates* —
and not the subagents, which are what actually write to files. In `yolo` mode
that guards a room where nothing happens.

**The cost is what the argument omits.** Turned on, the advisor runs inside
*every* subagent. A 10-agent fan-out multiplies it by ten, and each subagent
starts with a cold cache, so the 88% cache hit rate that made the advisor cheap
does not apply to them.

**Measured 2026-08-08**, two comparable sessions on the same machine:

| Session | `subagents` | Advisor turns | Advisor tokens |
|---|---|---|---|
| 07-39 UTC | `false` | 105 | 3,619,303 |
| 08-44 UTC | `true` | 985 | **161,815,140** |

**45×.** Total for the day: 1,967 advisor turns, 221,137,360 tokens, a weekly
subscription exhausted before dinner.

Three changes were made within the same hour — `subagents` on, advisor effort
raised, and the primary's effort raised — so no single one can be blamed with
certainty. That is itself the lesson: **change one multiplier at a time, and
measure a full session between each.** The 10-11% figure in pitfall #11 was
taken with `subagents: false`; using it to justify turning `subagents` on is
reasoning from a measurement the change invalidates.

**If you turn it on anyway**, verify it took effect: a reviewed subagent has its
own `__advisor.jsonl` inside **its own** directory under
`~/.omp/agent/sessions/<project>/<session>/<AgentName>/`, not merely at the
session root. Then read the token counts before running anything wide.

**Latency, separately**: if `syncBacklog: "1"` makes wide fan-outs feel slow,
relax it to `off` — the advisor keeps reviewing, asynchronously. That is a speed
knob, not a cost knob.

---

## 9. Concurrent subagents share one working tree

**Symptom** — silent overwrites. Two agents edit the same file, one wins, and
nothing reports it.

Defaults: `task.isolation.mode: none`, `task.maxConcurrency: 32`. Combined with
`approvalMode: yolo`, that is thirty-two possible writers in one directory with
no validation and no isolation.

**Fix** — copy-on-write clone per agent, with only the resulting diff merged
back (`merge: patch`). On APFS this is close to free: **cloning 200 MB took
0.029 s**, i.e. 6.9 GB/s, which no SSD achieves — nothing was copied, only
block references.

Note that `du` reports the clone at full size: it does not account for shared
blocks. Elapsed time is the reliable signal, not disk accounting.

---

## 10. Three factory defaults are wrong for client work

| Key | Factory default | Why it matters |
|---|---|---|
| `tools.approvalMode` | `yolo` | Auto-approves shell execution **and** disables omp's own hard-coded guardrails: `rm -rf /`, fork bombs, fetch-then-execute. |
| `dev.autoqa` | `true` | The model writes malfunction reports POSTed to `qa.omp.sh/v1/grievances`. The payload is free text and can carry paths or code fragments. A consent popup exists, but `PI_AUTO_QA_PUSH=1` bypasses it headless. |
| `secrets.enabled` | `false` | Enabled, it replaces sensitive-looking environment variables and token patterns with reversible markers *before* the prompt reaches the provider. |

Two of the three act from the very first session, so the configuration has to
be in place **before** the first launch. That is the whole reason this is an
installer and not a checklist.

---

## 11. What the second model actually costs

Nobody publishes this number, and `/advisor status` only shows the current
session. It is in `usage.cost` inside `__advisor.jsonl`.

Measured over one real 35-turn audit:

| | Turns | Tokens | Cost equivalent |
|---|---|---|---|
| Primary | 35 | 7,607,636 | $7.98 |
| Advisor | 50 | 724,663 | $0.86 |

**About 10% of the tokens and 11% of the cost.** It stays that low because 88%
of the advisor's input is served from cache: it sees the delta since its last
pass, not the whole context.

On a subscription these dollars are not billed — but the ratio still holds, and
what it consumes is quota. Read "cost" as "share of your weekly allowance".

---

## 12. A generic installer must not overwrite a tuned machine

`omp config set` writes straight into `~/.omp/agent/config.yml`. Regenerating
that file from a public template silently replaces machine-specific routing,
fallbacks, skills, and agent policy.

**Fix** — `install.sh` creates the starter configuration only when the file is
absent. On rerun it updates the runtime and `ompw`, but preserves the existing
configuration byte-for-byte. A machine-specific repository remains the source
of truth.

---

## 13. Login cannot be scripted, and may be revoked

`/login` is a browser OAuth flow. There is no headless path, by design.

Worth knowing before you build a workflow on it: in January 2026 one vendor cut
third-party OAuth access for consumer subscriptions, breaking an IDE
integration overnight, and formalised the restriction in February. Third-party
harnesses reaching a consumer plan through OAuth sit on a path that has already
been closed once, elsewhere. It works today. Plan for the morning it does not.

---

## 14. Running out of quota is silent, and the advisor dies without telling you

**Symptom** — none. You keep working. The second model stopped reviewing hours
ago and nothing said so.

Three factory defaults produce this together:

```
retry.usageAwareFallback = false   no quota is watched
retry.fallbackChains     = {}      nowhere to fall back to
retry.usageReservePolicy = confirm inert without the first
```

`retry.modelFallback` is `true`, but it fires on an **error**, not on a
allowance running down — and with an empty `fallbackChains` it has no
destination anyway. So the advisor's calls start failing, the primary keeps
working on its own provider, and the run continues looking healthy.

The trace exists, but only if you go looking: `usage_limit` appears inside the
session `__advisor.jsonl` files. Nothing surfaces it.

**Why this is worse than a wasted quota.** In `yolo` mode the advisor is the
only remaining control. When it dies silently you are not running "with a
reviewer that had a problem" — you are running unsupervised, and you believe you
are not.

**Fix**, applied by this installer:

```yaml
retry:
  usageAwareFallback: true
  usageReservePct: 10
  usageReservePolicy: fail-closed
```

The reserve stops the run visibly before quota reaches zero. The public template
does not invent provider-specific fallback chains before the user has
authenticated those providers. On an existing machine, keep its routing in the
machine-specific source of truth; this installer will not replace it.

---

## 15. Two habits that make everything above cheaper to diagnose

**`timeout` does not exist on macOS.** Diagnostic scripts written against Linux
die on the first line. Use a background PID plus a bounded wait loop.

**A shared Cloudflare IP is not an identification.** Reverse DNS on `104.16.x`
or `188.114.x` proves nothing about which domain was contacted, because
thousands of sites sit behind the same front. Filtering network captures by
process PID is also unreliable: a naive filter picked up unrelated traffic from
Google, GitHub, AWS and Tailscale and would have supported a completely wrong
conclusion. Query the specific destination you care about, and treat a wide
capture as a lead, never as evidence.
