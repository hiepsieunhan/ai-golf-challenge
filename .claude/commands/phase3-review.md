Kick off Phase 3: Review.

Spawn these 3 subagents IN PARALLEL using the Task tool:

1. **security-auditor** agent — perform a security audit on all contracts in src/
2. **requirements-verifier** agent — verify all requirements from docs/requirements.md are met
3. **code-quality-reviewer** agent — review code quality, NatSpec, events, naming, organization

Each agent knows where to write its output (in `docs/review/`).

After ALL 3 agents complete, provide me a synthesis:

1. **Critical/High security findings** (if any) — list them with the auditor's recommended fix
2. **Requirements gaps** — any PARTIAL or FAIL items from the checklist
3. **Top 5 code quality improvements** worth making

Then ask me:
- "Review the findings in docs/review/. Which items do you want me to fix?"
- "After fixes, commit: git commit -am 'fix: addressed review findings'"
