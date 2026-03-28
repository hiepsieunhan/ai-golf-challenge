Kick off Phase 2: Implementation.

Read `docs/architecture.md` for the finalized design. Read `docs/requirements.md` for the full spec.

You are the team lead. Operate in **delegate mode** — coordinate and review only, do NOT write implementation code yourself.

## Team Structure

Create an agent team with 3 teammates. Read `docs/architecture.md` for exact contract names, file paths, interfaces, RBAC roles, and design decisions. The teammates below are role descriptions — map them to the actual contracts and patterns defined in the architecture doc.

### Teammate 1: Vault Engineer
- **Owns**: Core vault contract and all interface definitions (exact file names in architecture doc)
- **Responsibility**: Deposits, RBAC, asset management, deploy/withdraw orchestration, TVL reporting, and any emergency controls specified in architecture

### Teammate 2: Strategy Engineer
- **Owns**: Aave V3 strategy contract and any helper contracts (exact file names in architecture doc)
- **Responsibility**: Aave V3 integration — supply/withdraw, yield accounting (approach defined in architecture doc), harvest logic, ETH handling (approach defined in architecture doc)

### Teammate 3: Test Engineer
- **Owns**: `test/` directory entirely
- **Responsibility**: Fork tests against mainnet Aave V3, RBAC tests, edge cases, integration tests

## Execution: 3 Waves with Gates

### Wave 1: Interfaces + Skeletons
- Vault Engineer: Write all interfaces and vault skeleton based on `docs/architecture.md` — RBAC roles, events, custom errors, function signatures (empty bodies OK)
- Strategy Engineer: Write Aave V3 strategy skeleton implementing the strategy interface defined in architecture doc
- Test Engineer: Write base test contract with fork setup, deploy helpers, role assignments per architecture doc
- **GATE**: Run `forge build`. ALL contracts must compile. Verify interfaces match across vault and strategy. If mismatch → tell the responsible teammate to fix before proceeding.
- **COMMIT**: After gate passes, run: `git add -A && git commit -m "impl: wave 1 — interfaces and skeletons compile"`

### Wave 2: Core Implementation
- Vault Engineer: Implement all function bodies per architecture doc — deposit flows, deploy/withdraw orchestration, TVL views, and any emergency controls
- Strategy Engineer: Implement Aave V3 supply/withdraw, yield accounting (per approach chosen in architecture doc), harvest logic
- Test Engineer: START WRITING AND RUNNING TESTS IN PARALLEL. Begin with happy path: deposit ERC20, deposit ETH (per chosen ETH approach), deploy to Aave, check balances, warp time, verify yield, harvest, withdraw.
- **FEEDBACK LOOP**: Test Engineer runs `forge test` continuously. When a test fails, Test Engineer messages the responsible teammate DIRECTLY with the failure details. That teammate fixes it. Do NOT wait until all implementation is done to start testing.
- **GATE**: ALL happy path tests must pass. `forge build` clean. Run `forge test -vvv` and verify.
- **COMMIT**: `git add -A && git commit -m "impl: wave 2 — core logic + happy path tests passing"`

### Wave 3: Hardening
- Test Engineer: Write RBAC restriction tests (every privileged function reverts for unauthorized callers), edge case tests (zero amounts, unsupported assets, excess operations), and tests for any emergency controls defined in architecture doc
- Vault Engineer + Strategy Engineer: Add NatSpec to ALL public/external functions, verify event emission on ALL state changes, add any missing input validation
- **GATE**: ALL tests pass. `forge build` zero warnings. Total test count should be 15+.
- **COMMIT**: `git add -A && git commit -m "impl: wave 3 — hardening, RBAC tests, edge cases, NatSpec"`

## Quality Bar

Tell ALL teammates:
- Use SafeERC20 for ALL token operations
- Use ReentrancyGuard on ALL fund-moving functions
- Emit events for ALL state changes
- Use custom errors, not require strings
- NatSpec on ALL public/external functions
- Follow checks-effects-interactions pattern
- No magic numbers — use named constants
- Test names follow: `test_functionName_revertsWhen_condition` or `test_functionName_succeeds_when_condition`

## When Done

After Wave 3 gate passes, report to me:
- Total number of tests and pass status
- List of contracts created
- Any concerns or tradeoffs made during implementation
- Remind me to review before Phase 3
