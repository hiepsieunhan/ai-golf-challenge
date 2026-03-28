# Decision Log

Record key architecture and design decisions made during the project.

## Template

### [DATE] — [DECISION TITLE]
**Context:** Why this decision was needed
**Options considered:** What alternatives were evaluated
**Decision:** What was chosen
**Rationale:** Why this option was selected
**Tradeoffs:** What was sacrificed

---

### 2026-03-28 — Vault Architecture: Option B (Vault + Strategy Interface)
**Context:** Needed to choose between monolithic vault, vault+strategy, or full registry+router.
**Options considered:** (A) Monolithic Aave-aware vault, (B) Vault + IStrategy + AaveV3Strategy, (C) Vault + Registry + Router with multi-strategy-per-asset.
**Decision:** Option B — 3 contracts with a clean `IStrategy` interface.
**Rationale:** Option A fails the extensibility requirement by hardcoding Aave into the vault. Option C over-engineers for Day 1 when only one strategy per asset is needed. Option B is the minimum architecture that satisfies all requirements — extensible via new strategy contracts without vault changes, while keeping complexity proportional to actual needs.
**Tradeoffs:** Cannot run multiple strategies concurrently on the same asset (e.g., 60/40 Aave/Compound). Migration to multi-strategy is additive later.
