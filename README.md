# GRVT Yield Vault

A treasury vault system that accepts capital, deploys it into yield strategies (Aave V3), and harvests yield to a designated recipient. Built entirely with AI-assisted development using Claude Code.

## Approach

The core idea: **design the AI workflow before writing any code.**

Before touching Solidity, I used Claude to discuss and design a multi-phase, multi-agent workflow. The goal was to break the problem into stages where specialized AI agents handle different concerns — research, implementation, review — with human decision-making at the critical architecture step.

The workflow has 3 phases, each driven by purpose-built sub-agents defined in `.claude/agents/` and orchestrated via slash commands in `.claude/commands/`:

**Phase 1 — Research** (4 parallel agents)
Each agent researches one domain and writes findings to `docs/research/`:
- Vault architecture patterns (ERC-4626, multi-asset, strategy interfaces)
- Aave V3 integration details (Pool interface, aToken mechanics, yield accounting)
- Security patterns (RBAC, reentrancy, emergency controls, audit findings)
- Testing patterns (Foundry fork testing, yield simulation, DeFi test strategies)

**Phase 2 — Implementation** (Agent Team: lead + 3 specialists)
A team of agents builds in 3 gated waves, each with a compile/test gate before proceeding:
1. Interfaces + skeletons (must compile)
2. Core logic + happy path tests (tests must pass)
3. Hardening — RBAC tests, edge cases, NatSpec (all tests pass, zero warnings)

**Phase 3 — Review** (3 parallel agents)
Three independent reviewers audit the output:
- Security auditor (reentrancy, access control, unsafe calls, DeFi vulnerabilities)
- Requirements verifier (cross-references `docs/requirements.md` against implementation)
- Code quality reviewer (NatSpec, events, naming, gas, organization)

Between phases, the human makes the key decisions — architecture choices, which review findings to fix, and when to stop iterating.

## What the Human Does vs. What AI Does

| Step | Human | AI |
|------|-------|-----|
| Workflow design | Design phases, agent roles, orchestration | Discuss and refine the approach |
| Research | Kick off, skim results | 4 agents research in parallel |
| Architecture | Read options, make decisions, log reasoning | Propose options, write architecture doc |
| Implementation | Monitor, intervene if stuck | Agent team builds in 3 waves |
| Review | Decide what to fix | 3 agents audit in parallel |
| Fix | Prioritize findings | Fix code, re-run tests |
| Creator review | Read judgement, iterate | Play role of challenge author, score |

## The Creator Review Loop

After the standard build-review-fix cycle, I added an extra step: asking Claude to **play the role of the challenge creator** and review the submission as if grading it. This catches design-level gaps that mechanical reviewers miss — things that are technically correct but would lose points.

This loop ran iteratively (review → fix → re-review) until findings converged to info-level only:

| Round | Score | Key findings addressed |
|-------|-------|----------------------|
| 1 | 8/10 | No idle withdrawal path, stale `deployedPrincipal` after harvest |
| 2 | 9/10 | Added `withdraw()`, `migrateStrategy()`, fuzz tests |
| 3 | 9.5/10 | Simplified inheritance, added `emergencyWithdrawIdle`, invariant tests |
| 4+ | 9.5+ | Harvest-before-migrate, multi-asset invariants, event completeness |
| Final | 9.8/10 | No actionable findings remaining |

Full judgements: [`docs/judgement/`](docs/judgement/)

## Results

**3 contracts, ~680 lines of Solidity.** ~70 tests including fuzz and stateful invariants, all running against real Aave V3 on a mainnet fork.

```
src/
  GrvtVault.sol              445 lines — Core vault (accounting, RBAC, fund routing)
  interfaces/IStrategy.sol    44 lines — Strategy interface
  strategies/AaveV3Strategy  194 lines — Aave V3 implementation
```

Key properties:
- **4-role RBAC** (Admin, Strategist, Depositor, Guardian) with 1-day admin transfer delay
- **Fee-on-transfer safe** deposits (before/after balance check)
- **ReentrancyGuardTransient** (EIP-1153) on all fund-moving functions
- **Pause design**: inbound operations pause, outbound/emergency never trapped
- **Atomic strategy migration** with yield harvest to grvtBank
- **Live TVL reporting** via aToken balance (not stale bookkeeping)
- **Mainnet fork tests** — not mocks. Validates real Aave V3 integration.

## Build & Test

```bash
forge build
forge test --fork-url $ETH_RPC_URL -vvv
```

## Project Structure

```
src/                          Solidity contracts
test/                         Foundry tests (fork, fuzz, invariant)
docs/
  requirements.md             Challenge problem statement
  architecture.md             Design document
  research/                   Phase 1 research outputs
  review/                     Phase 3 review outputs
  judgement/                   Creator review loop history
  decisions/                  Architecture decision log
  execution-guide.md          Step-by-step setup & execution guide
.claude/
  agents/                     Sub-agent definitions (7 agents)
  commands/                   Phase slash commands
```

## Detailed Execution Guide

For the full step-by-step walkthrough of how to reproduce this workflow (prerequisites, setup, running each phase): [`docs/execution-guide.md`](docs/execution-guide.md)
