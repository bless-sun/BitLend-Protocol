;; Title: BitLend Protocol - Bitcoin-Native Decentralized Lending on Stacks L2
;; Summary: Secure, self-custodial lending protocol enabling sBTC holders to unlock liquidity while maintaining Bitcoin exposure
;; Description:
;; A next-generation DeFi primitive combining Bitcoin's security with Stacks Layer 2 scalability. BitLend allows users to:
;; - Deposit sBTC as collateral to mint USDA stablecoins (SIP-010 compliant)
;; - Participate in decentralized governance through protocol-owned tokens
;; - Benefit from transparent risk parameters and real-time price feeds
;; - Engage in trustless liquidations and automated interest calculations
;; Built with Clarity's inherent security for financial smart contracts, BitLend serves as a bridge between Bitcoin's store-of-value 
;; and decentralized finance capabilities, strictly adhering to Bitcoin compliance standards and leveraging Stacks L2 for fast, 
;; low-cost transactions.

;; Constants and configuration
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u1000))
(define-constant ERR_INVALID_AMOUNT (err u1001))
(define-constant ERR_INSUFFICIENT_COLLATERAL (err u1002))
(define-constant ERR_VAULT_NOT_FOUND (err u1003))
(define-constant ERR_ALREADY_INITIALIZED (err u1004))
(define-constant ERR_NOT_INITIALIZED (err u1005))
(define-constant ERR_LIQUIDATION_FAILED (err u1006))
(define-constant ERR_PRICE_FEED_ERROR (err u1007))
(define-constant ERR_GOVERNANCE_DISABLED (err u1008))
(define-constant ERR_INSUFFICIENT_BALANCE (err u1009))
(define-constant ERR_VAULT_NOT_HEALTHY (err u1010))
(define-constant ERR_PROPOSAL_NOT_ACTIVE (err u1011))

;; Governance token info
(define-fungible-token GOVERNANCE_TOKEN)

;; Data structures
(define-map vaults
  { owner: principal }
  {
    collateral-amount: uint,     ;; Amount of sBTC deposited
    debt-amount: uint,           ;; Amount of stablecoin borrowed
    last-interest-block: uint,   ;; Block height of last interest calculation
    liquidation-ratio: uint      ;; Minimum collateralization ratio (in basis points, e.g. 15000 = 150%)
  }
)

(define-map protocol-parameters
  { parameter-name: (string-ascii 32) }
  { value: uint }
)

(define-map governance-proposals
  { proposal-id: uint }
  {
    proposer: principal,
    title: (string-ascii 64),
    description: (string-utf8 256),
    parameter-name: (string-ascii 32),
    proposed-value: uint,
    votes-for: uint,
    votes-against: uint,
    status: (string-ascii 16),    ;; "active", "passed", "rejected", "executed"
    end-block: uint
  }
)

(define-map user-votes
  { proposal-id: uint, voter: principal }
  { vote-amount: uint, vote-direction: bool }  ;; true = for, false = against
)

(define-data-var next-proposal-id uint u1)
(define-data-var total-collateral uint u0)
(define-data-var total-debt uint u0)
(define-data-var protocol-paused bool false)
(define-data-var governance-enabled bool false)

;; SIP-010 compliant fungible token for the stablecoin
(define-fungible-token USDA)

;; External contract interfaces
(define-trait sip-010-trait
  (
    (transfer (uint principal principal (optional (buff 34))) (response bool uint))
    (get-balance (principal) (response uint uint))
    (get-total-supply () (response uint uint))
  )
)

(define-trait oracle-trait
  (
    (get-price () (response uint uint))
    (get-decimals () (response uint uint))
  )
)

;; Read-only functions

;; Get vault information for a user
(define-read-only (get-vault (owner principal))
  (match (map-get? vaults { owner: owner })
    vault vault
    (err ERR_VAULT_NOT_FOUND)
  )
)

;; Calculate current health factor for a vault (collateralization ratio)
(define-read-only (get-health-factor (owner principal))
  (match (map-get? vaults { owner: owner })
    vault
      (let 
        (
          (collateral-value (calculate-collateral-value (get collateral-amount vault)))
          (debt-value (get debt-amount vault))
        )
        (if (is-eq debt-value u0)
          (ok u0) ;; No debt, no need for health factor
          (ok (/ (* collateral-value u10000) debt-value))
        )
      )
    (err ERR_VAULT_NOT_FOUND)
  )
)