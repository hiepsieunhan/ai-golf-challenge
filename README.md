# GRVT Yield Vault — Setup & Execution Guide

A step-by-step guide to building the GRVT Yield Vault using Claude Code with multi-agent orchestration.

---

## Prerequisites

### 1. Install Foundry (Solidity toolchain)

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

Verify:
```bash
forge --version
```

### 2. Install Claude Code

```bash
npm install -g @anthropic-ai/claude-code
```

You need a Claude Pro ($20/mo) or Max ($100–200/mo) plan. Max is recommended — Agent Teams burn tokens fast, and you'll need headroom for Phase 2.

### 3. Get an Ethereum Mainnet RPC URL

Fork tests run against real Aave V3 on Ethereum mainnet. You need an RPC endpoint with archive data access.

**Free options (any one of these):**

| Provider | Free Tier | Sign Up |
|----------|-----------|---------|
| Alchemy | 30M compute units/mo (~1.2M requests) | https://www.alchemy.com/ |
| Infura | ~100k requests/day | https://www.infura.io/ |
| Chainstack | 3M requests/mo | https://chainstack.com/ |

After signing up, create a project for Ethereum Mainnet and copy your RPC URL. It will look like:
```
https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY
# or
https://mainnet.infura.io/v3/YOUR_API_KEY
```

### 4. Install tmux (optional but recommended)

Agent Teams show each teammate in a separate terminal pane if tmux is available:
```bash
# macOS
brew install tmux

# Ubuntu/Debian
sudo apt install tmux
```

Without tmux, Agent Teams still work but all output appears in one thread.

---

## Step 0: Project Initialization

**Time:** ~10 minutes
**Who does it:** You (manual)

### 0.1 Create the Foundry project

```bash
mkdir grvt-yield-vault && cd grvt-yield-vault
forge init --no-commit
```

### 0.2 Install Solidity dependencies

```bash
forge install OpenZeppelin/openzeppelin-contracts --no-commit
forge install aave/aave-v3-core --no-commit
```

### 0.3 Configure remappings

Create `remappings.txt` in the project root:
```
@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
@aave/v3-core/=lib/aave-v3-core/
forge-std/=lib/forge-std/src/
```

### 0.4 Configure Solidity version

Edit `foundry.toml` and set:
```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc_version = "0.8.34"
```

### 0.5 Set up the RPC URL

Create a `.env` file in the project root (**do NOT commit this**):
```bash
ETH_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY
```

Add `.env` to `.gitignore`:
```bash
echo ".env" >> .gitignore
```

To load it in your shell:
```bash
source .env
```

### 0.6 Extract the scaffold files

Extract the provided `grvt-yield-vault-scaffold.tar.gz` into the project. This adds:
- `CLAUDE.md`
- `docs/` (requirements, decision log template)
- `.claude/agents/` (7 subagent definitions)
- `.claude/commands/` (3 phase commands)
- `.claude/settings.json` (Agent Teams enabled)

```bash
# From the project root, extract (adjust path to where you downloaded the tar):
tar -xzf /path/to/grvt-yield-vault-scaffold.tar.gz --strip-components=1
```

> **NOTE:** If the tar extraction creates duplicate directories, just manually copy
> the `CLAUDE.md`, `docs/`, and `.claude/` folders into your project root.

### 0.7 Remove Foundry's default scaffolded files

```bash
rm src/Counter.sol test/Counter.t.sol script/Counter.s.sol
```

### 0.8 Verify everything compiles

```bash
forge build
```

It should succeed (with nothing to compile yet since we removed the default files).

### 0.9 Initial commit

```bash
git add -A
git commit -m "init: foundry project with OpenZeppelin, Aave V3, and agent scaffold"
```

> **Claude Code automation note:** Steps 0.1–0.9 could be done by Claude Code with a
> single prompt, but doing it manually ensures you understand the project structure and
> avoids wasting tokens on setup. If you prefer, you can ask Claude Code:
> *"Initialize a Foundry project, install OpenZeppelin and Aave V3 dependencies,
> configure remappings.txt and foundry.toml for Solidity 0.8.34."*

---

## Step 1: Phase 1 — Research

**Time:** ~15–30 minutes (agents work in parallel)
**Who does it:** Claude Code (you watch)

### 1.1 Start Claude Code

```bash
cd grvt-yield-vault
source .env
claude
```

### 1.2 Run the research command

Type:
```
/phase1-research
```

This spawns 4 research subagents in parallel:
- **researcher-vault-arch** → `docs/research/vault-architecture.md`
- **researcher-aave** → `docs/research/aave-v3-deep-dive.md`
- **researcher-security** → `docs/research/security-rbac.md`
- **researcher-testing** → `docs/research/testing-yield-accounting.md`

Wait for all 4 to complete. Claude will give you a summary.

### 1.3 Commit research

```bash
git add -A
git commit -m "research: phase 1 complete — vault architecture, aave v3, security, testing"
```

---

## Step 2: Synthesize & Decide (YOUR CRITICAL STEP)

**Time:** ~30–60 minutes
**Who does it:** You + Claude Code (interactive)

This is the most important step. You're making architecture decisions that shape everything.

### 2.1 Read the research (skim is fine)

You don't need to understand every Solidity detail. Focus on:
- What patterns/options each researcher proposed
- What tradeoffs they identified
- What they recommended

### 2.2 Ask Claude to propose architecture options

Still in the same Claude Code session, prompt:

```
Read all files in docs/research/. Based on these findings, propose 2-3 architecture
options for the vault system. For each option, cover:
- Contract structure (how many contracts, what each does)
- Strategy interface design
- RBAC role structure
- ETH handling approach
- Yield accounting approach
- Emergency controls (if any)
- TVL reporting interface
Show tradeoffs between options. Write to docs/architecture-options.md.
```

### 2.3 Make your decisions

Read `docs/architecture-options.md`. For each open question, pick an option. You're looking at ~6 decisions:

| Decision | What to consider |
|----------|-----------------|
| **Contract structure** | Simpler = fewer bugs, more complex = more extensible |
| **RBAC roles** | 2-tier minimum (admin + operator). 3-tier adds funding separation. More roles = more security but more complexity |
| **ETH handling** | WETH wrapping is simplest for uniform ERC20 logic. Separate path is more gas efficient but more code |
| **Yield accounting** | Principal tracking is simple and easy to audit. Scaled balances are more precise but harder to understand |
| **Emergency controls** | Pausable is low-cost to add and shows production-mindedness |
| **TVL reporting** | View functions are minimum. Events help indexers |

### 2.4 Finalize architecture

Prompt Claude Code:

```
Based on my decisions: [state your choices clearly].
Write the final architecture document to docs/architecture.md. Include:
- Contract file names and responsibilities
- Full interface definitions (function signatures)
- RBAC role names and what each can do
- Data structures (mappings, structs)
- Fund flow diagrams (text-based)
- Yield accounting approach
- ETH handling approach
```

### 2.5 Log your decisions

Edit `docs/decisions/decision-log.md` yourself (or ask Claude). For each decision, write:
- What you chose
- Why (1-2 sentences is enough)

This is what makes the submission look human-steered rather than auto-generated.

### 2.6 Commit

```bash
git add -A
git commit -m "architecture: finalized vault design with [brief summary of key choices]"
```

### 2.7 Verify architecture against requirements

Run the verification command:
```
/verify-architecture
```

This runs an **automated feedback loop**: a subagent verifies the architecture against all requirements and research findings. If gaps are found, it auto-fixes the architecture doc (without changing your core design decisions), then re-verifies. This repeats up to 3 iterations.

The loop can ADD missing sections and CLARIFY ambiguities, but it will NOT change the design decisions you made (contract structure, RBAC roles, yield approach, ETH handling). If issues remain after 3 iterations, it stops and asks for your input.

After it reports READY:

```bash
git add -A
git commit -m "architecture: verified against requirements"
```

> **Claude Code automation note:** This step is fully automated including fixes. You only
> intervene if it can't reach READY after 3 iterations (rare — usually means a fundamental
> design gap that needs a human decision).

---

## Step 3: Phase 2 — Implementation

**Time:** ~45–90 minutes (agent team works in 3 waves)
**Who does it:** Claude Code Agent Team (you monitor)

### 3.1 Start a FRESH Claude Code session

This is critical. A fresh session starts with a clean context window, loading only `CLAUDE.md` and the files on disk (including your architecture doc).

```bash
# Exit the previous session first (Ctrl+C or type /exit)
claude
```

### 3.2 Run the implementation command

```
/phase2-implement
```

This creates an Agent Team with a lead + 3 teammates (Vault Engineer, Strategy Engineer, Test Engineer). The team works in 3 waves:

**Wave 1: Interfaces + Skeletons**
- All contracts created with function signatures
- Gate: `forge build` must pass
- Auto-commit: `impl: wave 1 — interfaces and skeletons compile`

**Wave 2: Core Implementation**
- Full logic implemented
- Test Engineer writes and runs tests IN PARALLEL
- Feedback loop: failed tests → direct message to responsible engineer → fix
- Gate: all happy path tests pass
- Auto-commit: `impl: wave 2 — core logic + happy path tests passing`

**Wave 3: Hardening**
- RBAC restriction tests, edge cases, NatSpec, events
- Gate: all tests pass, `forge build` zero warnings
- Auto-commit: `impl: wave 3 — hardening, RBAC tests, edge cases, NatSpec`

### 3.3 Monitor (optional but recommended)

If you have tmux, you can watch each teammate in its own pane. Use `Shift+Down` to cycle between teammates if using in-process mode.

Things to watch for:
- Interface mismatches between vault and strategy (the lead should catch this)
- Tests failing repeatedly on the same issue (might need your input)
- Context getting too long (if a teammate seems confused, the lead should compact or restart it)

### 3.4 If something goes wrong

If the agent team stalls or produces broken code:
- You can talk directly to a specific teammate
- You can message the lead with corrections
- Worst case: exit, `git stash`, start a new session, and re-run `/phase2-implement`

### 3.5 Verify after Phase 2

Once the team reports done:

```bash
source .env
forge build
forge test --fork-url $ETH_RPC_URL -vvv
```

Skim the output:
- Do all tests pass?
- Are test names descriptive?
- Do the contract files match your architecture doc?

> **Claude Code automation note:** Phase 2 is almost entirely automated. Your role is
> monitoring and intervening only if things go sideways. The commits happen
> automatically at each wave gate.

---

## Step 4: Phase 3 — Review

**Time:** ~15–30 minutes (agents work in parallel)
**Who does it:** Claude Code (you read results)

### 4.1 Start a FRESH Claude Code session

```bash
claude
```

### 4.2 Run the review command

```
/phase3-review
```

This spawns 3 review subagents in parallel:
- **security-auditor** → `docs/review/security-audit.md`
- **requirements-verifier** → `docs/review/requirements-checklist.md`
- **code-quality-reviewer** → `docs/review/code-quality.md`

### 4.3 Commit review results

```bash
git add -A
git commit -m "review: security audit, requirements checklist, code quality review"
```

---

## Step 5: Fix Review Findings (YOUR DECISION STEP)

**Time:** ~15–45 minutes
**Who does it:** You decide what to fix, Claude Code fixes it

### 5.1 Read the review docs

Focus on:
1. `docs/review/security-audit.md` — any CRITICAL or HIGH findings?
2. `docs/review/requirements-checklist.md` — any FAIL items?
3. `docs/review/code-quality.md` — top 5 SHOULD FIX items

### 5.2 Tell Claude Code what to fix

Still in the same session, prompt:

```
Read all files in docs/review/. Fix the following:
- All CRITICAL and HIGH security findings
- All FAIL items from the requirements checklist
- The top [N] code quality issues marked SHOULD FIX

After fixing, run forge build and forge test to verify everything still passes.
```

### 5.3 Final verification

```bash
source .env
forge build
forge test --fork-url $ETH_RPC_URL -vvv
```

### 5.4 Final commit

```bash
git add -A
git commit -m "fix: addressed security findings and requirements gaps"
```

> **Claude Code automation note:** The fix step is a good candidate for Claude Code
> to handle autonomously. You just need to tell it which findings to prioritize.

---

## Step 6: Final Cleanup (Optional)

**Time:** ~10 minutes

### 6.1 Verify the submission tells a clear story

A reviewer should be able to answer these three questions quickly from your code:
1. How funds enter the system → look at deposit functions
2. How funds move into and out of strategy → look at deploy/withdraw/harvest
3. How an external party understands what the vault owns → look at TVL view functions

If any of these are unclear, ask Claude Code to improve the NatSpec or add a comment.

### 6.2 Check git log

```bash
git log --oneline
```

Should look something like:
```
abc1234 fix: addressed security findings and requirements gaps
def5678 review: security audit, requirements checklist, code quality review
ghi9012 impl: wave 3 — hardening, RBAC tests, edge cases, NatSpec
jkl3456 impl: wave 2 — core logic + happy path tests passing
mno7890 impl: wave 1 — interfaces and skeletons compile
pqr1234 architecture: finalized vault design
stu5678 research: phase 1 complete
vwx9012 init: foundry project with OpenZeppelin, Aave V3, and agent scaffold
```

### 6.3 Final commit

```bash
git add -A
git commit -m "final: cleanup and submission"
```

---

## Quick Reference: What You Do vs. What Claude Does

| Step | You | Claude Code |
|------|-----|-------------|
| Step 0: Setup | Run commands, create `.env` | Can do this if you prefer |
| Step 1: Research | Type `/phase1-research`, wait | 4 subagents research in parallel |
| Step 2: Decide | Read research, make architecture decisions, log reasoning | Proposes options, writes architecture doc |
| Step 2.7: Verify | Type `/verify-architecture`, read verdict | Subagent checks architecture vs. requirements |
| Step 3: Implement | Type `/phase2-implement`, monitor | Agent team builds in 3 waves with feedback loops |
| Step 4: Review | Type `/phase3-review`, wait | 3 subagents audit in parallel |
| Step 5: Fix | Decide what to fix, tell Claude | Fixes issues, re-runs tests |
| Step 6: Cleanup | Verify git log, skim code | Optional NatSpec improvements |

**Total estimated time:** 2.5–5 hours depending on how deep you go in Step 2.

---

## Troubleshooting

### `forge build` fails after installing dependencies
Check `remappings.txt` is correct. Run `forge remappings` to see what Foundry auto-detects, and compare with your `remappings.txt`.

### Fork tests fail with "could not connect"
Verify your `.env` has the correct RPC URL and you ran `source .env` before `forge test`.

### Agent Team teammates don't appear
Verify `.claude/settings.json` has `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` set to `"1"`. Run `claude --version` to ensure you're on a version from after February 5, 2026.

### Agent Team stalls or loops
Exit the session, check git status, and start fresh. The wave-gate commits give you safe rollback points.

### Context window fills up during Phase 2
This is normal for complex implementations. The team lead should handle compaction. If a teammate seems confused, you can message it directly with clarification. Starting a fresh session and re-running is always an option — your code is on disk and committed.

### Research subagents return thin results
Web search quality varies. You can re-run a specific researcher manually:
```
Use the researcher-aave agent to research Aave V3 integration details.
Focus specifically on [the area that was weak].
```

### "forge test" passes locally but not with --fork-url
Fork tests depend on network state. Pin to a specific block number in your test setup for reproducibility. The testing researcher should have covered this.