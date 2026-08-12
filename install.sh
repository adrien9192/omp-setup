#!/usr/bin/env bash
#
# omp-setup — install omp (Oh My Pi) without overwriting an existing setup.
#
# On a fresh machine, writes a measured starter configuration. On an existing
# machine, updates the runtime and ompw but leaves config.yml byte-for-byte intact.
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

# Current cross-vendor defaults. Override any role on the command line.
# An explicitly empty OMP_ADVISOR disables the advisor.
OMP_DOER="${OMP_DOER:-openai-codex/gpt-5.6-sol}"
OMP_ADVISOR="${OMP_ADVISOR-anthropic/claude-opus-5}"
OMP_TASK="${OMP_TASK:-anthropic/claude-sonnet-5}"
OMP_CHEAP="${OMP_CHEAP:-anthropic/claude-haiku-4-5}"

# Reasoning effort: low|medium|high|xhigh|max.
OMP_EFFORT="${OMP_EFFORT:-high}"

# always-ask | write | yolo.
#   yolo       = nothing is ever validated. This is the default here, on
#                purpose: the friction of approving every shell command is what
#                makes people stop using the tool. It is also what omp itself
#                ships. The installer prints what it means before finishing.
#   write      = auto-approves reads and writes, prompts before shell execution.
#   always-ask = prompts for everything.
OMP_APPROVAL_MODE="${OMP_APPROVAL_MODE:-yolo}"

BUN_MIN="1.3.14"
OMP_MIN="17.2.15"   # Current role set and template behavior validated here.
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
CONFIG_CREATED=false

if [ -f "$CONFIG" ]; then
  info "Existing config preserved: ${CONFIG/#$HOME/~}"
  info "This generic template never replaces a machine-specific source of truth."
else
  mkdir -p "$(dirname "$CONFIG")"

  # Copy-on-write clone of the working tree, one per subagent.
  case "$(uname -s)" in
    Darwin) ISOLATION="apfs" ;;
    *)      ISOLATION="auto" ;;
  esac
  info "Subagent isolation: $ISOLATION"

  DOER="$OMP_DOER:$OMP_EFFORT"
  TASK_MODEL="$OMP_TASK:$OMP_EFFORT"
  CHEAP_MODEL="$OMP_CHEAP:$OMP_EFFORT"
  ADVISOR_MODEL="${OMP_ADVISOR:+$OMP_ADVISOR:$OMP_EFFORT}"

  cat > "$CONFIG" <<YAML
# Fresh-machine starter configuration written by omp-setup.
# Existing configurations are never overwritten.

tools:
  approvalMode: $OMP_APPROVAL_MODE

secrets:
  enabled: true

dev:
  autoqa: false

marketplace:
  autoUpdate: notify

startup:
  checkUpdate: true

retry:
  usageAwareFallback: true
  usageReservePct: 10
  usageReservePolicy: fail-closed

task:
  isolation:
    mode: $ISOLATION
    apply: true
    merge: patch
  enableEffort: true
  maxEffort: high

modelRoles:
  default: $DOER
  advisor: ${ADVISOR_MODEL:-$DOER}
  plan: $DOER
  smol: $CHEAP_MODEL
  tiny: $CHEAP_MODEL
  commit: $CHEAP_MODEL
  vision: $TASK_MODEL
  slow: $TASK_MODEL
  designer: $TASK_MODEL
  task: $TASK_MODEL
YAML

  if [ -n "$OMP_ADVISOR" ]; then
    cat >> "$CONFIG" <<'YAML'

advisor:
  enabled: true
  syncBacklog: "off"
  immuneTurns: 3
  subagents: false
YAML
  fi

  chmod 600 "$CONFIG"
  CONFIG_CREATED=true
  info "Written: ${CONFIG/#$HOME/~}"
fi

# ─── 4. Verify ───────────────────────────────────────────────────────────────
step "4. Verify"
if $CONFIG_CREATED; then
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
  check retry.usageReservePct   10
  check retry.usageReservePolicy fail-closed
  check task.isolation.mode     "$ISOLATION"
  check task.enableEffort       true
  check task.maxEffort          high
  [ -n "$OMP_ADVISOR" ] && check advisor.enabled true
  [ -n "$OMP_ADVISOR" ] && check advisor.subagents false

  [ "$FAILURES" -eq 0 ] || die "$FAILURES setting(s) did not apply. Do not run omp on a client repository until this is fixed."
else
  info "Existing config was not changed; no template-value assertions applied."
fi

# ─── 4b. ompw ────────────────────────────────────────────────────────────────
# omp isolates the subagents it delegates to, but nothing isolates the MAIN
# turn: it always writes to the directory you launched from. In yolo that turn
# is also the one issuing the most shell commands, so the agent with the widest
# blast radius is the only one with no containment. There is no setting for it
# (checked: task.isolation covers delegated work only, --cwd just moves the
# start directory). ompw closes it from the outside: a worktree and a branch of
# its own, a diff when it exits, a merge only if you say so.
step "5. ompw"
if [ -f "$(dirname "$0")/ompw.sh" ]; then
  mkdir -p "$HOME/.omp"
  cp "$(dirname "$0")/ompw.sh" "$HOME/.omp/ompw.sh"
  chmod +x "$HOME/.omp/ompw.sh"
  for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
    [ -f "$rc" ] || continue
    grep -q 'omp/ompw.sh' "$rc" && continue
    cat >> "$rc" <<'RC'

# omp: run the main turn inside a disposable git worktree
[ -f "$HOME/.omp/ompw.sh" ] && . "$HOME/.omp/ompw.sh"
RC
    info "Sourced from ${rc/#$HOME/~}"
  done
  info "ompw installed. Use 'ompw' instead of 'omp' inside a git repository."
else
  info "ompw.sh not found next to this script, skipping."
fi

# ─── 6. What is left for a human ─────────────────────────────────────────────
if $CONFIG_CREATED; then
  if [ "$OMP_APPROVAL_MODE" = "yolo" ]; then
    printf '\n\033[33m%s\033[0m\n' "Approval mode is yolo. Read this once."
    cat <<'WARN'
  Nothing will be validated. Shell commands from the main turn run against your
  real working tree, and omp's hard-coded guardrails (rm -rf /, fork bombs,
  fetch-then-execute) are bypassed in this mode.

  Delegated subagents work in isolated clones. Use ompw to contain the main turn,
  and keep your work committed.

  To be prompted before shell instead:
    OMP_APPROVAL_MODE=write bash install.sh
  Or later:
    omp config set tools.approvalMode write
WARN
  fi

  step "Left to do, once"
  cat <<FIN
  Login is a browser OAuth flow and cannot be scripted:

    omp
FIN
  printf '    /login %s\n' "${OMP_DOER%%/*}"
  [ -n "$OMP_ADVISOR" ] && printf '    /login %s\n' "${OMP_ADVISOR%%/*}"
  cat <<'FIN'

  Then do real work and run /advisor status. A non-zero message count proves the
  second model is reviewing.
FIN
else
  step "Done"
  info "OMP and ompw updated; existing authentication and configuration preserved."
fi
