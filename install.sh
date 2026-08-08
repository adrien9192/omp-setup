#!/usr/bin/env bash
#
# omp-setup — install omp (Oh My Pi) with a hardened, working configuration.
#
# Idempotent: safe to re-run. Backs up any existing config before writing.
#
# Everything this script does differently from the official install is there
# because it was measured failing. See PITFALLS.md for each measurement.
#
#   bash install.sh
#
set -euo pipefail

# ─── What you can change ─────────────────────────────────────────────────────
# Override any of these on the command line:
#   OMP_APPROVAL_MODE=yolo OMP_EFFORT=max bash install.sh

# Second model that reviews the first. Leave empty to run single-model.
# Its whole value is that it does NOT share the doer's blind spots, so pick a
# different vendor than OMP_DOER.
# Note the missing colon: ${VAR-default} keeps an explicitly empty value, while
# ${VAR:-default} would overwrite it. `OMP_ADVISOR= bash install.sh` must mean
# "no advisor", not "the default advisor".
OMP_ADVISOR="${OMP_ADVISOR-openai-codex/gpt-5.6-sol}"
OMP_DOER="${OMP_DOER:-anthropic/claude-opus-5}"
OMP_CHEAP="${OMP_CHEAP:-anthropic/claude-haiku-4-5}"

# Reasoning effort for the doer and the advisor: low|medium|high|xhigh|max.
# Higher burns subscription quota faster on EVERY turn, including trivial ones.
OMP_EFFORT="${OMP_EFFORT:-high}"

# always-ask | write | yolo.
#   write = auto-approves reads and writes, prompts before shell execution.
#   yolo  = approves everything AND disables omp's own hard-coded guardrails
#           (rm -rf /, fork bombs, fetch-then-execute). Deliberate choice only.
OMP_APPROVAL_MODE="${OMP_APPROVAL_MODE:-write}"

BUN_MIN="1.3.14"
OMP_MIN="17.2.11"   # 17.2.10 cannot resolve a model at all. See PITFALLS #4.
CONFIG="$HOME/.omp/agent/config.yml"

info()  { printf '  %s\n' "$1"; }
step()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
die()   { printf '\n\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

# Returns 0 when $2 >= $1. Works with BSD and GNU sort.
version_at_least() { printf '%s\n%s\n' "$1" "$2" | sort -V -C; }

# ─── 1. Runtime ──────────────────────────────────────────────────────────────
step "1. Runtime"
# omp declares "engines": {"bun": ">=1.3.14"} and has no node field: 105 files
# in the package import bun:* builtins. Node cannot run it.
if ! command -v bun >/dev/null 2>&1; then
  info "bun not found, installing from bun.sh"
  curl -fsSL https://bun.sh/install | bash
  export PATH="$HOME/.bun/bin:$PATH"
fi
BUN_VERSION="$(bun --version)"
if version_at_least "$BUN_MIN" "$BUN_VERSION"; then
  info "bun $BUN_VERSION (minimum $BUN_MIN) ok"
else
  info "bun $BUN_VERSION is below $BUN_MIN, upgrading"
  bun upgrade >/dev/null 2>&1
  info "bun $(bun --version) ok"
fi

# ─── 2. Install ──────────────────────────────────────────────────────────────
step "2. Install"
# Installing through bun/npm rather than the official `curl https://omp.sh/install | sh`:
# that installer verifies no checksum or signature (334 lines, zero calls to
# sha256/gpg/cosign). The registry path publishes a signed SLSA v1 provenance
# attestation proving the package was built from the public repository.
#
# --omit=optional drops 5 high-severity advisories carried by local-ML
# dependencies omp does not need here.
bun install -g @oh-my-pi/pi-coding-agent --omit=optional 2>&1 | tail -3 | sed 's/^/  /'

# But --omit=optional ALSO drops the Rust native addon, without which omp does
# not start at all ("Failed to load pi_natives native addon"). Reinstall the
# one for this platform, and only that one.
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)  NATIVE="darwin-arm64"  ;;
  Darwin-x86_64) NATIVE="darwin-x64"    ;;
  Linux-aarch64) NATIVE="linux-arm64"   ;;
  Linux-x86_64)  NATIVE="linux-x64"     ;;
  *) die "Unsupported platform: $(uname -s)-$(uname -m)" ;;
esac
info "Native module: $NATIVE"
bun install -g "@oh-my-pi/pi-natives-$NATIVE" 2>&1 | tail -2 | sed 's/^/  /'

command -v omp >/dev/null || die "omp is not on PATH. Add \$HOME/.bun/bin to it and re-run."

# Version 17.2.10 accepts a valid modelRoles record, reports both accounts as
# connected, and then fails every turn with "No model selected". Nothing in the
# config can work around it; only the upgrade fixes it.
OMP_VERSION="$(omp --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
if ! version_at_least "$OMP_MIN" "$OMP_VERSION"; then
  info "omp $OMP_VERSION is below $OMP_MIN, updating"
  omp update </dev/null 2>&1 | tail -2 | sed 's/^/  /'
  OMP_VERSION="$(omp --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
fi
version_at_least "$OMP_MIN" "$OMP_VERSION" || die "omp $OMP_VERSION is below the required $OMP_MIN."
info "omp $OMP_VERSION ok"

# ─── 3. Configuration ────────────────────────────────────────────────────────
step "3. Configuration"
if [ -f "$CONFIG" ]; then
  BACKUP="$CONFIG.bak-$(date +%Y%m%d-%H%M%S)"
  cp "$CONFIG" "$BACKUP"
  info "Existing config backed up to ${BACKUP/#$HOME/~}"
fi
mkdir -p "$(dirname "$CONFIG")"

# Copy-on-write clone of the working tree, one per subagent. Measured on APFS:
# cloning 200 MB takes 0.029 s because no bytes are copied, only block
# references. "auto" elsewhere lets omp pick among btrfs/zfs/reflink/overlayfs;
# that path is untested by this script.
case "$(uname -s)" in
  Darwin) ISOLATION="apfs" ;;
  *)      ISOLATION="auto" ;;
esac
info "Subagent isolation: $ISOLATION"

DOER="$OMP_DOER:$OMP_EFFORT"
ADVISOR_MODEL="${OMP_ADVISOR:+$OMP_ADVISOR:$OMP_EFFORT}"

cat > "$CONFIG" <<YAML
# omp — hardened configuration written by omp-setup.
# Every non-default value below exists because the default was measured failing.
# Reasons: https://github.com/adrien9192/omp-setup/blob/main/PITFALLS.md

tools:
  # FACTORY DEFAULT: "yolo" — reads, writes AND shell execution auto-approved,
  # and in yolo omp explicitly bypasses its own hard-coded guardrails.
  approvalMode: $OMP_APPROVAL_MODE
  # Deliberately no per-tool \`approval\` rules. A {bash: prompt} rule does not
  # block execution, it relocates it: refused on the bash tool, the model reran
  # the identical command through subprocess in the Python kernel and it went
  # through unvalidated. A bypassable guard is worse than none.

secrets:
  # FACTORY DEFAULT: false. Enabled, it replaces sensitive-looking environment
  # variables and token patterns with reversible markers BEFORE the prompt
  # reaches the model provider.
  enabled: true

dev:
  # FACTORY DEFAULT: true. The model writes malfunction reports POSTed to
  # qa.omp.sh. The payload is free text and can carry paths or code fragments.
  # A consent popup exists, but PI_AUTO_QA_PUSH=1 bypasses it when headless.
  autoqa: false

marketplace:
  # Never "auto": plugin code runs in-process, with no sandbox.
  autoUpdate: notify

startup:
  checkUpdate: true

task:
  isolation:
    # Without this, every concurrent subagent writes into the same directory.
    # Two agents touching one file silently overwrite each other, and in yolo
    # nobody validates the result.
    mode: $ISOLATION
    apply: true
    merge: patch

  # The bundled agents declare model: ["@task"] — a role that does NOT exist in
  # modelRoles, whose key set is closed (default, advisor, plan, smol, tiny,
  # commit). With no override, omp falls back to an internal default of
  # claude-sonnet-4-0, which its bundled catalogue still advertises but which
  # the provider has retired: every subagent 404s and is re-dispatched, burning
  # one full round trip each. Judgement and review on the strong model,
  # read-only exploration on the cheap one.
  agentModelOverrides:
    task:              $DOER
    reviewer:          $DOER
    designer:          $DOER
    security-reviewer: $DOER
    scout:             $OMP_CHEAP
    librarian:         $OMP_CHEAP
    sonic:             $OMP_CHEAP

# Roles are a CLOSED set. To change one you must rewrite the whole record:
#   omp config set modelRoles.plan <value>     -> rejected
#   omp config set modelRoles '{...all six...}' -> accepted
# The record itself is unvalidated and will happily store an invented key, so
# "it saved" is not evidence that the key is read.
modelRoles:
  default: $DOER
  advisor: ${ADVISOR_MODEL:-$DOER}
  plan:    ${ADVISOR_MODEL:-$DOER}
  smol:    $OMP_CHEAP
  tiny:    $OMP_CHEAP
  commit:  $OMP_CHEAP
YAML

if [ -n "$OMP_ADVISOR" ]; then
cat >> "$CONFIG" <<'YAML'

advisor:
  # FACTORY DEFAULT: disabled. This is the feature with no equivalent elsewhere:
  # a second model, from a different vendor, reading the first one's diffs and
  # reasoning while it works, able to interrupt.
  #
  # It does NOT receive the full context: one line per tool call, results
  # omitted, arguments truncated at 120 characters — but edit diffs verbatim and
  # the primary's reasoning. Hence a sub-linear overhead. Measured over a real
  # 35-turn audit: 724,663 advisor tokens against 7,607,636 for the primary,
  # about 10% of the tokens and 11% of the cost, because 88% of its input is
  # served from cache.
  enabled: true
  syncBacklog: "1"   # end of turn, bounded 30s wait. "off" = fully async.
  immuneTurns: 3     # after an accepted interruption, 3 turns in remark-only mode
  # Subagents are what actually write to files; the main turn only delegates.
  # Reviewing the delegator and not the writers guards an empty room.
  subagents: true
YAML
fi

chmod 600 "$CONFIG"
info "Written: ${CONFIG/#$HOME/~}"

# ─── 4. Verify ───────────────────────────────────────────────────────────────
step "4. Verify"
FAILURES=0
check() {
  local key="$1" expected="$2" actual
  actual="$(omp config get "$key" 2>/dev/null | tail -1 | tr -d '[:space:]')"
  if [ "$actual" = "$expected" ]; then
    printf '  %-28s %s\n' "$key" "$actual"
  else
    printf '  %-28s %s (expected %s)  FAIL\n' "$key" "${actual:-empty}" "$expected"
    FAILURES=$((FAILURES + 1))
  fi
}
check tools.approvalMode      "$OMP_APPROVAL_MODE"
check secrets.enabled         true
check dev.autoqa              false
check marketplace.autoUpdate  notify
check task.isolation.mode     "$ISOLATION"
[ -n "$OMP_ADVISOR" ] && check advisor.enabled true
[ -n "$OMP_ADVISOR" ] && check advisor.subagents true

[ "$FAILURES" -eq 0 ] || die "$FAILURES setting(s) did not apply. Do not run omp on a client repository until this is fixed."

# ─── 5. What is left for a human ─────────────────────────────────────────────
step "Left to do, once"
cat <<FIN
  Login is a browser OAuth flow and cannot be scripted:

    omp                     # opens the interface
FIN
printf '    /login %s\n' "${OMP_DOER%%/*}"
[ -n "$OMP_ADVISOR" ] && printf '    /login %s\n' "${OMP_ADVISOR%%/*}"
cat <<'FIN'

  Then, to confirm the second model is actually reviewing:

    ask omp to fix something in a real file, then run /advisor status
    Total messages > 0 means it ran. 0 after real work means it did not.

  A subagent is only being reviewed when a __advisor.jsonl file appears inside
  ITS OWN session directory, not merely at the session root.
FIN
