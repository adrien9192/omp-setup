# The findings contract

Give this to every subagent you send looking for defects — audit, review, bug
hunt, security pass, compliance check. It is six clauses long and it is the
single biggest lever on the result, larger than the model and larger than the
harness.

## What it is worth, measured

Two harnesses audited the same commit of the same repository on the same day,
2026-08-08.

| | Findings | Tokens |
|---|---|---|
| Without the contract | 17 | 21,068,104 |
| Ten agents with it | ~70 | 1,698,950 |

**8% of the cost, five times the findings.** Among what only the second pass
caught: a production admin password committed in plain text, `prisma db push
--accept-data-loss` running on every deployment with no migrations directory,
and a mail-sending route that opens to unauthenticated POSTs when one
environment variable is absent.

Same models on both sides. The delta was what each was asked to return.

## The six clauses

Put all six in the prompt. Dropping any one of them costs something specific.

1. **Anchor every finding** to `path/file.ts:line`. No anchor, no finding. This
   is what stops plausible invention: an agent that cannot name the line has not
   read it.

2. **Quote the faulty code**, 3 to 8 lines, verbatim. Same purpose, second lock.

3. **Give a concrete trigger scenario** — who does what, in what order, with
   which values. "This function could fail" is not a finding. "A member scoped
   to A sends this request with an id from B and receives this content" is.

4. **Assign a severity** yourself. Do not leave the ranking to the reader.

5. **Keep a separate NOT CONFIRMED section** for anything whose reachability you
   could not establish, with the reason. This clause is what produces honesty:
   without somewhere to put uncertainty, uncertainty dresses up as certainty
   rather than appear empty.

6. **Write this sentence literally:** *"A false positive costs more than a
   miss. Report nothing you have not read line by line."* It inverts the
   filler reflex.

Always add: **"Finish with a VERIFIED SOUND list of the mechanisms you inspected
and found correct, with their file."** It is worth as much as the defects — it
says where not to look tomorrow, and it makes visible what the agent actually
covered rather than what it claims to have covered.

## Slicing

One slice per functional domain, not per directory. Name the starting files in
the prompt instead of letting the agent hunt for its own scope — it will spend
its budget exploring rather than reading.

Ten slices is a reasonable order of magnitude for an application repository.
Read-only agents need no worktree isolation.

**Measured trap:** reusing a previous audit's slicing makes comparison possible
but inherits its map of the terrain. A domain the first pass missed entirely,
the second will miss too. To search, leave the slicing free; to compare, impose
it and say so.

## What the contract does not do

It produces anchored findings, not true ones. In the same test, one slice marked
a file "verified sound" that was not — a quoting regex missing one character
from its class.

**Reopen by hand the findings that will trigger an action, and any where two
sources disagree.** That step is the one thing the contract cannot automate.
