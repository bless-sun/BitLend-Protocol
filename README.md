# BitLend Protocol - Technical Documentation

## Overview

BitLend is a Bitcoin-native decentralized lending protocol built on Stacks Layer 2, enabling sBTC holders to access liquidity while maintaining Bitcoin exposure. The protocol combines Bitcoin's security with Stacks L2 scalability through Clarity smart contracts, offering non-custodial lending, decentralized governance, and automated risk management.

## Key Features

- **sBTC Collateralization**: Deposit SIP-010 compliant sBTC to mint USDA stablecoins
- **Decentralized Governance**: Protocol parameters controlled by governance token holders
- **Risk-Managed Vaults**: Real-time collateralization ratio monitoring
- **Trustless Liquidations**: Permissionless liquidation of undercollateralized positions
- **Dynamic Interest Rates**: Utilization-based borrowing costs
- **Transparent Accounting**: On-chain tracking of total collateral/debt positions

## Technical Architecture

### Core Components

1. **Vault System**

   - Stores user collateral and debt positions
   - Tracks interest accrual per block
   - Enforces collateralization ratios

2. **Governance Module**

   - Proposal creation and voting system
   - Parameter adjustment mechanism
   - Quadratic voting weight based on token holdings

3. **Risk Management**

   - Real-time price feeds (Oracle integration)
   - Automated interest calculations
   - Liquidation engine with penalty incentives

4. **Token Systems**
   - USDA (SIP-010 Stablecoin)
   - BLGOV (Governance Token)

## Key Protocol Parameters

| Parameter                | Default Value       | Description                                        |
| ------------------------ | ------------------- | -------------------------------------------------- |
| Minimum Collateral Ratio | 150%                | Minimum collateralization ratio before liquidation |
| Liquidation Penalty      | 10%                 | Additional fee paid by liquidated vaults           |
| Base Interest Rate       | 2%                  | Minimum borrowing cost                             |
| Utilization Multiplier   | 8%                  | Rate increase per 100% utilization                 |
| Proposal Duration        | 144 blocks (~1 day) | Voting period length                               |
| Governance Threshold     | 100 BLGOV           | Minimum tokens to create proposals                 |

## Smart Contract Functions

### Vault Management

**Deposit Collateral**

```clarity
(define-public (deposit-collateral (sbtc-token <sip-010-trait>) (amount uint))
```

- Accepts sBTC transfers
- Creates or updates user vault
- Updates total protocol collateral

**Withdraw Collateral**

```clarity
(define-public (withdraw-collateral (sbtc-token <sip-010-trait>) (amount uint))
```

- Verifies health factor remains above minimum
- Transfers sBTC back to user
- Updates vault state

### Debt Operations

**Borrow USDA**

```clarity
(define-public (borrow (amount uint))
```

- Mints new USDA stablecoins
- Verifies collateralization ratio
- Updates vault debt and interest timestamp

**Repay Debt**

```clarity
(define-public (repay (amount uint))
```

- Burns USDA tokens
- Applies accrued interest
- Reduces vault debt balance

### Liquidation System

**Liquidate Vault**

```clarity
(define-public (liquidate (vault-owner principal) (sbtc-token <sip-010-trait>))
```

- Checks collateralization status
- Applies liquidation penalty
- Transfers collateral to liquidator
- Closes undercollateralized vault

## Governance System

### Proposal Lifecycle

1. **Creation**

   - 100 BLGOV threshold
   - Specifies parameter changes
   - 24-hour voting period

2. **Voting**

   - Token-weighted voting
   - Changeable votes
   - Quadratic voting implementation

3. **Execution**
   - Automatic parameter updates
   - Time-locked execution
   - State machine tracking

**Key Governance Functions**

```clarity
(define-public (create-proposal ...))
(define-public (vote-on-proposal ...))
(define-public (execute-proposal ...))
```

## Security Model

### Contract Safeguards

- Administrative pause functionality
- Oracle price validation
- Reentrancy protection
- Overflow/underflow checks
- Timelock on governance actions

### Error Codes

| Code  | Description              |
| ----- | ------------------------ |
| u1000 | Unauthorized access      |
| u1001 | Invalid amount           |
| u1002 | Insufficient collateral  |
| u1003 | Vault not found          |
| u1006 | Liquidation failed       |
| u1010 | Unhealthy vault position |

## Development Guide

### Requirements

- Clarinet SDK 1.5.0+
- Stacks blockchain 2.1+
- Node.js 16.x

## Risk Considerations

1. **Oracle Risk**

   - Current mock implementation requires mainnet-grade solution
   - Price feed latency considerations

2. **Interest Rate Risk**

   - Utilization-based rate model volatility
   - Block time variability

3. **Governance Risk**
   - Proposal spam protection
   - Timelock implementation status
