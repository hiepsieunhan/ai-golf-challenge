# GRVT Yield Vault

## What This Is
A treasury vault system for GRVT. Accepts capital from funding wallets, holds it safely, deploys it into yield strategies (Day 1: Aave V3), reports TVL, and supports harvesting yield to `grvtBank`.

## Requirements
Full problem statement: `docs/requirements.md`

## Architecture
Design document (created after research phase): `docs/architecture.md`
Decision log: `docs/decisions/decision-log.md`

## Workflow
This project is built in 3 phases. Phase instructions live in `.claude/commands/`.
- Phase 1: Research → 4 parallel researchers write to `docs/research/`
- Phase 2: Implementation → agent team builds `src/` and `test/` in 3 waves
- Phase 3: Review → 3 parallel reviewers write to `docs/review/`

Research findings from Phase 1 are available in `docs/research/` and can be referenced during any phase.

## Tech Stack
- Solidity 0.8.34 (latest stable as of March 2026)
- Foundry (forge build / forge test)
- OpenZeppelin Contracts (AccessControl, ReentrancyGuard, SafeERC20, and others as decided in architecture)
- Aave V3 Core (interfaces only)

## Build & Test
```bash
forge build          # must pass with zero warnings
forge test -vvv      # run all tests
forge test --fork-url $ETH_RPC_URL -vvv  # fork tests against mainnet
```

## Code Standards
- NatSpec (`@notice`, `@param`, `@return`) on ALL public/external functions
- Events emitted for ALL state changes
- ReentrancyGuard on ALL functions that move funds
- SafeERC20 for ALL token interactions (handles non-standard tokens like USDT)
- Custom errors, not require strings
- No magic numbers — use named constants
- Checks-effects-interactions pattern on all external calls
- Pin pragma to exact version: `pragma solidity 0.8.34;` (no floating ^)

## RBAC
At minimum, admin/configuration actions must be separated from operational fund-moving actions.
Exact role structure is an architecture decision — see `docs/architecture.md` after Phase 1.

## File Ownership
Contract file names and structure are defined in `docs/architecture.md`.
At minimum expect: a core vault contract, strategy interface(s), and an Aave V3 strategy implementation under `src/`, with all tests under `test/`.

## Research
Phase 1 research outputs: `docs/research/`

## Commit Convention
Commit at each milestone with descriptive prefix:
- `init:` / `research:` / `architecture:` / `impl:` / `review:` / `fix:`
