Kick off Phase 1: Research.

Read `docs/requirements.md` to understand the full challenge spec.

Then spawn these 4 subagents IN PARALLEL using the Task tool:

1. **researcher-vault-arch** agent — research vault architecture and extensibility patterns
2. **researcher-aave** agent — research Aave V3 integration details
3. **researcher-security** agent — research security, RBAC, and DeFi safety patterns
4. **researcher-testing** agent — research Foundry testing and yield accounting

Each agent knows where to write its output (in `docs/research/`).

After ALL 4 agents complete, report a brief summary of what each one found (2-3 bullet points each). Do NOT synthesize into an architecture yet — that's a separate step that needs human review.

Then remind me:
- "Research phase complete. Read the docs in docs/research/ and then ask me to propose architecture options."
- "After you pick an architecture, update docs/decisions/decision-log.md with your reasoning."
- "Then commit: git commit -am 'research: phase 1 complete'"
