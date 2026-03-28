# AI Solidity Golf Challenge: GRVT Yield Vault

## Overview

Build a Solidity-based treasury vault system for GRVT.

In plain English: you are building a vault that can receive treasury capital, keep some of it idle, deploy some of it into yield strategies, report what it currently owns, and support harvesting yield.

The system should be able to accept capital from a funding wallet, hold that capital safely, deploy it into yield strategies, report what it owns, and support harvesting yield.

For Day 1, the only required strategy is **Aave V3**.

The important constraint is that the design should **not** feel permanently hardcoded to this single case. A strong submission should make it realistic to support a more general model later:

* deploy asset **X**
* into strategy **Y**
* track what is deployed
* harvest what the strategy earns

This is intentionally not a one-shot toy problem. It is meant to test how well you can use AI tools, prompting, and agent orchestration to solve a moderately complex smart contract task.

## Scope

In scope for this challenge:

* a treasury-style vault in Solidity
* funding flows from a designated funding wallet
* support for both native ETH and ERC20 assets
* Day 1 strategy support for Aave V3
* TVL/reporting surfaces
* RBAC
* meaningful tests

Out of scope for this challenge:

* production deployment scripts or live deployment
* support for every future protocol on Day 1
* solving every exotic token behavior perfectly
* full operational documentation

## Core Requirements

### 1. Accept capital from a funding wallet

The system should be able to receive assets from a designated funding source. Assume the funding wallet is an authorized source of capital, not a random public user account.

Examples:
* a funding wallet sends 100 ETH
* a funding wallet sends 1,000,000 USDC
* a funding wallet sends 500,000 USDT

### 2. Support both ETH and ERC20 assets

The solution should not be limited to only one asset type.

Examples:
* native ETH
* USDC
* USDT
* other ERC20 assets with standard ERC20 behavior

### 3. Deploy assets into a yield strategy

For Day 1, the vault must support deploying capital into **Aave V3**.

### Aave V3: Minimal mental model

* to **supply**, a contract approves the Aave pool to spend an ERC20 asset, then calls `supply(asset, amount, onBehalfOf, referralCode)`
* in return, Aave credits the position with the corresponding **aToken**
* over time, the position accrues yield through the Aave accounting model
* to **withdraw**, a contract calls `withdraw(asset, amount, to)`
* Aave then returns the underlying asset to the chosen recipient

### 4. Be extensible beyond Aave V3

Future examples:
* deploy USDC into another lending protocol
* deploy ETH into another yield venue
* add a second strategy without rewriting the vault from scratch

### 5. Support harvesting yield

Example:
* the vault deploys 1,000,000 USDC
* later, the position is effectively worth 1,020,000 USDC
* the 20,000 USDC yield should be harvestable and moved to **grvtBank**, the designated yield recipient

### 6. Report TVL for third-party trackers

At a minimum, third parties should be able to understand idle balance, deployed balance, and total holdings on a per-asset basis.

### 7. Include RBAC

The exact role structure is up to you, but at minimum the design should make it clear which actions are admin/configuration actions and which actions are operational fund-moving actions.

### 8. Be production-minded

Assume the contracts are intended to hold real funds. That should show up in:
* how you structure responsibilities
* how you think about permissions
* how you handle accounting
* how you test behavior

## Deliverables

* Solidity contracts
* code that compiles successfully
* meaningful automated tests

Tests should not only cover the happy path. At minimum, they should demonstrate that the core flows behave correctly and that privileged actions are appropriately restricted.

A good submission should make it easy for a reviewer to answer three questions quickly:
* how funds enter the system
* how funds move into and out of strategy
* how an external party can understand what the vault currently owns

## What Will Be Judged

* correctness
* architecture and extensibility
* security-mindedness
* clarity of accounting/reporting
* quality of RBAC design
* test quality
* overall implementation quality