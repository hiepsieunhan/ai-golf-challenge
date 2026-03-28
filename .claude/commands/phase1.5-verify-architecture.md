Verify and iterate on the finalized architecture before starting implementation.

This command runs an automated feedback loop: verify → fix → re-verify, up to 3 iterations.

## Step 1: Verify

Spawn the **architecture-verifier** agent to check:
1. Every requirement in `docs/requirements.md` is addressed in `docs/architecture.md`
2. Architecture decisions are consistent with research findings in `docs/research/`

## Step 2: Auto-fix (if needed)

If the verdict is NEEDS REVISION:
- Read the gaps and contradictions identified by the verifier
- Update `docs/architecture.md` to address ONLY the gaps. Do NOT change design decisions that were already marked as addressed — preserve the human's choices.
- Add a note to `docs/decisions/decision-log.md` for each change made, explaining what was missing and how it was addressed

## Step 3: Re-verify

Spawn the **architecture-verifier** agent again on the updated `docs/architecture.md`.

## Step 4: Repeat or stop

- If READY → stop, report results to me
- If still NEEDS REVISION and iteration count < 3 → go back to Step 2
- If still NEEDS REVISION after 3 iterations → stop, report remaining gaps to me for manual decision

## Rules for auto-fix

- You may ADD missing sections to the architecture doc (e.g., adding a TVL reporting section if it was missing)
- You may CLARIFY ambiguous descriptions
- You may NOT change the core design decisions (contract structure, RBAC roles, yield accounting approach, ETH handling) — these were chosen by the human
- You may NOT add scope that isn't in the requirements (no gold-plating)

## When done

Report to me:
- How many iterations it took
- What was fixed in each iteration (if any)
- Final verdict (should be READY)
- Any remaining gaps that need my input
- Remind me to commit: `git commit -am "architecture: verified and iterated"`
- Remind me to start a fresh session and run `/phase2-implement`