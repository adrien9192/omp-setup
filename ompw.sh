#!/usr/bin/env bash
#
# ompw — run omp's MAIN turn inside a disposable git worktree.
#
# omp isolates the subagents it delegates to (task.isolation), but there is no
# setting that isolates the main turn: it always writes to the directory you
# launched from. In yolo mode that main turn is also the one issuing the most
# shell commands, with omp's hard-coded guardrails bypassed — so the agent with
# the widest blast radius is the only one with no containment at all.
#
# This closes that gap from the outside: a branch and a working tree of its own,
# a diff you look at when it exits, and a merge only if you say so.
#
#   ompw                 # worktree off the current branch, then omp
#   ompw "fix the auth bug"   # same, with an initial prompt
#
# Install: source this file from your shell profile, or copy the function.
set -euo pipefail

ompw() {
  local repo branch slug wt base
  repo="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "ompw: not inside a git repository. Plain 'omp' is the honest choice here." >&2
    return 1
  }
  base="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
  slug="omp-$(date +%Y%m%d-%H%M%S)"
  wt="${OMPW_ROOT:-$HOME/.omp/worktrees}/$(basename "$repo")-$slug"

  # Uncommitted work stays where it is: a worktree branches from the last
  # commit, so anything not committed is invisible to the agent. Say so rather
  # than let it be discovered mid-session.
  if ! git -C "$repo" diff --quiet || ! git -C "$repo" diff --cached --quiet; then
    echo "ompw: you have uncommitted changes on $base. The worktree branches from"
    echo "      the last commit, so the agent will NOT see them. Commit first if"
    echo "      they matter."
    printf "      Continue anyway? [y/N] "
    read -r reply
    [ "$reply" = "y" ] || [ "$reply" = "Y" ] || return 1
  fi

  mkdir -p "$(dirname "$wt")"
  git -C "$repo" worktree add -b "$slug" "$wt" "$base" >/dev/null
  echo "ompw: $slug  ←  $base"
  echo "      $wt"

  ( cd "$wt" && omp "$@" ) || true

  # What came back. An empty diff is the common case and is not a failure.
  if git -C "$wt" diff --quiet "$base" -- 2>/dev/null && [ -z "$(git -C "$wt" status --porcelain)" ]; then
    echo "ompw: nothing changed. Removing the worktree."
    git -C "$repo" worktree remove --force "$wt" >/dev/null
    git -C "$repo" branch -D "$slug" >/dev/null 2>&1 || true
    return 0
  fi

  git -C "$wt" add -A
  git -C "$wt" -c user.name="${GIT_AUTHOR_NAME:-$(git config user.name)}" \
               -c user.email="${GIT_AUTHOR_EMAIL:-$(git config user.email)}" \
               commit -qm "ompw: session $slug" || true

  echo
  git -C "$repo" diff --stat "$base".."$slug"
  echo
  printf "ompw: merge %s into %s? [y/N] " "$slug" "$base"
  read -r reply
  if [ "$reply" = "y" ] || [ "$reply" = "Y" ]; then
    git -C "$repo" merge --no-ff "$slug" -m "ompw: merge $slug"
    git -C "$repo" worktree remove --force "$wt" >/dev/null
    git -C "$repo" branch -d "$slug" >/dev/null 2>&1 || true
    echo "ompw: merged."
  else
    echo "ompw: kept on branch $slug, worktree at $wt"
    echo "      review with:  git diff $base..$slug"
    echo "      discard with: git worktree remove --force '$wt' && git branch -D $slug"
  fi
}

# Allow both `source ompw.sh` and `bash ompw.sh <args>`.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then ompw "$@"; fi
