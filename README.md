# Fund

**On-chain treasury primitive with share ledger, governed distributions, and verifiable ownership control.**

---

## Definition

`Fund` is an on-chain treasury contract that maintains a share ledger and enables proportional distribution of treasury-held value according to explicitly defined rules.

The Fund does not promise outcomes.  
It is a governed accounting and treasury primitive.

All actions and state are verifiable on-chain.

---

## What This Contract Does

- Maintains a share ledger (`shareBalances`)
- Tracks total share supply (`totalShares`)
- Supports proportional distribution mechanics (when executed by authorized control)
- Exposes verifiable state for governance weight and monitoring
- Enforces explicit ownership / governance execution boundaries

---

## What This Contract Does NOT Do

- Does **not** promise yield, profit, or compensation
- Does **not** provide investment guarantees
- Does **not** create off-chain ownership rights
- Does **not** custody ERC-20 assets for discretionary deployment (unless explicitly coded)
- Does **not** allow silent or discretionary value allocation

This is a treasury and accounting primitive only.

---

## Scope Limitation

The Fund is typically controlled by governance.

Common control model:

- **Weighted Governor** proposes actions
- **Timelock** executes approved actions
- **Fund** applies the action on-chain

Exact configuration depends on deployment and is verifiable via `owner()`.

---

## Governance / Control

Verify control state via:

- `owner()`
- ownership transfer events
- (if applicable) proxy admin / implementation addresses

If `owner()` is a Timelock, changes require on-chain governance.

---

## Deployment Status

- **Ownership:** Set per deployment (ideally Timelock-controlled)
- **Upgradeability:** Deployment-specific (proxy or non-proxy)
- **Immutability:** Final if non-proxy and ownership renounced (if used)

Refer to GitBook for deployed addresses, ownership state, and verification steps.

---

## Documentation

Full documentation:

https://docs.modulexo.com
