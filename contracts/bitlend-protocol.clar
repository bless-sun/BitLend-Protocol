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
(define-constant ERR_ORACLE_NOT_SET (err u1012))

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

;; Data vars
(define-data-var next-proposal-id uint u1)
(define-data-var total-collateral uint u0)
(define-data-var total-debt uint u0)
(define-data-var protocol-paused bool false)
(define-data-var governance-enabled bool false)
(define-data-var oracle-contract principal 'ST000000000000000000002AMW42H.oracle)
;; Replace the complex oracle integration with a simple mock
(define-data-var btc-price uint u30000)  ;; Mock BTC price in USD (e.g., $30,000)
(define-data-var price-decimals uint u0) ;; No decimals for simplicity

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
    vault (ok vault)
    (err ERR_VAULT_NOT_FOUND)
  )
)

(define-read-only (get-btc-price)
  (var-get btc-price)
)

;; Calculate current health factor for a vault (collateralization ratio)
(define-private (get-health-factor (owner principal))
  (match (map-get? vaults { owner: owner })
    vault
      (let 
        (
          (collateral-value (unwrap-panic (calculate-collateral-value (get collateral-amount vault))))
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

;; Get current oracle contract
(define-read-only (get-oracle-contract)
  (var-get oracle-contract)
)

;; Calculate USD value of collateral
(define-private (calculate-collateral-value (amount uint))
  (ok (* amount (var-get btc-price)))
)

;; Get protocol parameter
(define-read-only (get-parameter (parameter-name (string-ascii 32)))
  (default-to u0 (get value (map-get? protocol-parameters { parameter-name: parameter-name })))
)

;; Get proposal details
(define-read-only (get-proposal (proposal-id uint))
  (map-get? governance-proposals { proposal-id: proposal-id })
)

;; Get current interest rate based on utilization
(define-read-only (get-current-interest-rate)
  (let
    (
      (base-rate (get-parameter "base-rate"))
      (utilization-multiplier (get-parameter "utilization-multiplier"))
      (utilization-rate (calculate-utilization-rate))
    )
    (+ base-rate (* utilization-rate utilization-multiplier))
  )
)

;; Calculate protocol utilization rate (debt / collateral)
(define-read-only (calculate-utilization-rate)
  (if (is-eq (var-get total-collateral) u0)
    u0
    (/ (* (var-get total-debt) u10000) (var-get total-collateral))
  )
)

;; Calculate accrued interest for a vault
(define-read-only (calculate-accrued-interest (owner principal))
  (match (map-get? vaults { owner: owner })
    vault
      (let
        (
          (debt (get debt-amount vault))
          (last-block (get last-interest-block vault))
          (current-block stacks-block-height)
          (blocks-passed (- current-block last-block))
          (interest-rate (get-current-interest-rate))
          ;; Interest formula: debt * (rate / 10000) * (blocks / blocks-per-year)
          (blocks-per-year (get-parameter "blocks-per-year"))
          (interest-amount (/ (* debt (* interest-rate blocks-passed)) (* blocks-per-year u10000)))
        )
        (ok interest-amount)
      )
    (err ERR_VAULT_NOT_FOUND)
  )
)

;; Public functions

;; Initialize protocol parameters
(define-public (initialize-protocol)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (not (var-get governance-enabled)) ERR_ALREADY_INITIALIZED)
    
    ;; Set initial protocol parameters
    (map-set protocol-parameters { parameter-name: "minimum-collateral-ratio" } { value: u15000 }) ;; 150%
    (map-set protocol-parameters { parameter-name: "liquidation-penalty" } { value: u1000 })      ;; 10%
    (map-set protocol-parameters { parameter-name: "base-rate" } { value: u200 })                 ;; 2%
    (map-set protocol-parameters { parameter-name: "utilization-multiplier" } { value: u800 })    ;; 8%
    (map-set protocol-parameters { parameter-name: "governance-token-threshold" } { value: u100000000 }) ;; 100 tokens (assuming 6 decimals)
    (map-set protocol-parameters { parameter-name: "proposal-duration" } { value: u144 })         ;; ~1 day at 10 min blocks
    (map-set protocol-parameters { parameter-name: "blocks-per-year" } { value: u52560 })         ;; 365 * 144 blocks

    ;; Mint initial governance tokens to contract owner
    (try! (ft-mint? GOVERNANCE_TOKEN u1000000000 CONTRACT_OWNER))
    
    ;; Enable governance
    (var-set governance-enabled true)
    (ok true)
  )
)

;; Create a vault or deposit more collateral
(define-public (deposit-collateral (sbtc-token <sip-010-trait>) (amount uint))
  (begin
    (asserts! (not (var-get protocol-paused)) ERR_UNAUTHORIZED)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    
    ;; Transfer sBTC from user to contract
    (try! (contract-call? sbtc-token transfer amount tx-sender (as-contract tx-sender) none))
    
    ;; Update or create vault
    (match (map-get? vaults { owner: tx-sender })
      existing-vault
        (map-set vaults
          { owner: tx-sender }
          {
            collateral-amount: (+ (get collateral-amount existing-vault) amount),
            debt-amount: (get debt-amount existing-vault),
            last-interest-block: stacks-block-height,
            liquidation-ratio: (get liquidation-ratio existing-vault)
          }
        )
      ;; Create new vault if it doesn't exist
      (map-set vaults
        { owner: tx-sender }
        {
          collateral-amount: amount,
          debt-amount: u0,
          last-interest-block: stacks-block-height,
          liquidation-ratio: (get-parameter "minimum-collateral-ratio")
        }
      )
    )
    
    ;; Update total collateral
    (var-set total-collateral (+ (var-get total-collateral) amount))
    
    (ok true)
  )
)

;; Withdraw collateral if health factor permits
(define-public (withdraw-collateral (sbtc-token <sip-010-trait>) (amount uint))
  (begin
    (asserts! (not (var-get protocol-paused)) ERR_UNAUTHORIZED)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    
    (match (map-get? vaults { owner: tx-sender })
      vault
        (let
          (
            (current-collateral (get collateral-amount vault))
            (current-debt (get debt-amount vault))
          )
          ;; Check if withdrawal would leave sufficient collateral
          (asserts! (<= amount current-collateral) ERR_INSUFFICIENT_COLLATERAL)
          
          ;; If there's debt, check if health factor will remain above minimum after withdrawal
          (if (> current-debt u0)
            (let
              (
                (remaining-collateral (- current-collateral amount))
                (collateral-value-result (calculate-collateral-value remaining-collateral))
                (min-collateral-ratio (get liquidation-ratio vault))
                (required-collateral (/ (* current-debt min-collateral-ratio) u10000))
              )
              (match collateral-value-result 
                collateral-value (asserts! (>= collateral-value required-collateral) ERR_VAULT_NOT_HEALTHY)
                err (err err)
              )
            )
            true
          )
          
          ;; Update vault
          (try! (as-contract (contract-call? sbtc-token transfer amount (as-contract tx-sender) tx-sender none)))
          
          (map-set vaults
            { owner: tx-sender }
            {
              collateral-amount: (- current-collateral amount),
              debt-amount: current-debt,
              last-interest-block: stacks-block-height,
              liquidation-ratio: (get liquidation-ratio vault)
            }
          )
          
          ;; Update total collateral
          (var-set total-collateral (- (var-get total-collateral) amount))
          
          (ok true)
        )
      (err ERR_VAULT_NOT_FOUND)
    )
  )
)

;; Borrow stablecoins against collateral
(define-public (borrow (amount uint))
  (begin
    (asserts! (not (var-get protocol-paused)) ERR_UNAUTHORIZED)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    
    (match (map-get? vaults { owner: tx-sender })
      vault
        (let
          (
            (current-collateral (get collateral-amount vault))
            (current-debt (get debt-amount vault))
            (new-debt (+ current-debt amount))
            (collateral-value-result (calculate-collateral-value current-collateral))
            (min-collateral-ratio (get liquidation-ratio vault))
            (required-collateral (/ (* new-debt min-collateral-ratio) u10000))
          )
          ;; Check if borrowing would leave sufficient collateralization
          (match collateral-value-result
            collateral-value 
              (begin
                (asserts! (>= collateral-value required-collateral) ERR_INSUFFICIENT_COLLATERAL)
                
                ;; Mint stablecoins to borrower
                (try! (ft-mint? USDA amount tx-sender))
                
                ;; Update vault
                (map-set vaults
                  { owner: tx-sender }
                  {
                    collateral-amount: current-collateral,
                    debt-amount: new-debt,
                    last-interest-block: stacks-block-height,
                    liquidation-ratio: (get liquidation-ratio vault)
                  }
                )
                
                ;; Update total debt
                (var-set total-debt (+ (var-get total-debt) amount))
                
                (ok true)
              )
            err (err err)
          )
        )
      (err ERR_VAULT_NOT_FOUND)
    )
  )
)

;; Repay debt
(define-public (repay (amount uint))
  (begin
    (asserts! (not (var-get protocol-paused)) ERR_UNAUTHORIZED)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    
    (match (map-get? vaults { owner: tx-sender })
      vault
        (let
          (
            (current-debt (get debt-amount vault))
            (accrued-interest-result (calculate-accrued-interest tx-sender))
          )
          (match accrued-interest-result
            accrued-interest
              (let
                (
                  (total-owed (+ current-debt accrued-interest))
                  (repay-amount (if (> amount total-owed) total-owed amount))
                )
                ;; Check if user has sufficient stablecoins
                (try! (ft-burn? USDA repay-amount tx-sender))
                
                ;; Update vault
                (map-set vaults
                  { owner: tx-sender }
                  {
                    collateral-amount: (get collateral-amount vault),
                    debt-amount: (- total-owed repay-amount),
                    last-interest-block: stacks-block-height,
                    liquidation-ratio: (get liquidation-ratio vault)
                  }
                )
                
                ;; Update total debt
                (var-set total-debt (- (var-get total-debt) repay-amount))
                
                (ok true)
              )
            err (err err)
          )
        )
      (err ERR_VAULT_NOT_FOUND)
    )
  )
)

;; Liquidation function - can be called by anyone when a vault is undercollateralized
(define-public (liquidate (vault-owner principal) (sbtc-token <sip-010-trait>))
  (begin
    (asserts! (not (var-get protocol-paused)) ERR_UNAUTHORIZED)
    
    (match (map-get? vaults { owner: vault-owner })
      vault
        (let
          (
            (current-collateral (get collateral-amount vault))
            (current-debt (get debt-amount vault))
            (collateral-value-result (calculate-collateral-value current-collateral))
            (min-collateral-ratio (get liquidation-ratio vault))
            (required-value (/ (* current-debt min-collateral-ratio) u10000))
            (liquidation-penalty (get-parameter "liquidation-penalty"))
            (penalty-amount (/ (* current-debt liquidation-penalty) u10000))
            (total-to-repay (+ current-debt penalty-amount))
          )
          (match collateral-value-result
            collateral-value
              (begin
                ;; Check if vault is undercollateralized
                (asserts! (< collateral-value required-value) ERR_VAULT_NOT_HEALTHY)
                
                ;; Check if liquidator has enough stablecoins
                (try! (ft-burn? USDA total-to-repay tx-sender))
                
                ;; Transfer collateral to liquidator
                (try! (as-contract (contract-call? sbtc-token transfer current-collateral (as-contract tx-sender) tx-sender none)))
                
                ;; Close the vault
                (map-delete vaults { owner: vault-owner })
                
                ;; Update totals
                (var-set total-collateral (- (var-get total-collateral) current-collateral))
                (var-set total-debt (- (var-get total-debt) current-debt))
                
                (ok true)
              )
            err (err err)  
          )
        )
      (err ERR_VAULT_NOT_FOUND)
    )
  )
)

;; Governance functions

;; Create governance proposal
(define-public (create-proposal 
  (title (string-ascii 64)) 
  (description (string-utf8 256)) 
  (parameter-name (string-ascii 32)) 
  (proposed-value uint))
  (begin
    (asserts! (var-get governance-enabled) ERR_GOVERNANCE_DISABLED)
    
    ;; Check if proposer has enough governance tokens
    (let 
      (
        (threshold (get-parameter "governance-token-threshold"))
        (user-balance-result (ft-get-balance GOVERNANCE_TOKEN tx-sender))
        (proposal-id (var-get next-proposal-id))
        (proposal-duration (get-parameter "proposal-duration"))
      )
      (match user-balance-result
        user-balance
          (begin 
            (asserts! (>= user-balance threshold) ERR_UNAUTHORIZED)
            
            ;; Create proposal
            (map-set governance-proposals
              { proposal-id: proposal-id }
              {
                proposer: tx-sender,
                title: title,
                description: description,
                parameter-name: parameter-name,
                proposed-value: proposed-value,
                votes-for: u0,
                votes-against: u0,
                status: "active",
                end-block: (+ stacks-block-height proposal-duration)
              }
            )
            
            ;; Increment proposal counter
            (var-set next-proposal-id (+ proposal-id u1))
            
            (ok proposal-id)
          )
        err (err ERR_INSUFFICIENT_BALANCE)
      )
    )
  )
)

;; Vote on proposal
(define-public (vote-on-proposal (proposal-id uint) (vote-direction bool) (vote-amount uint))
  (begin
    (asserts! (var-get governance-enabled) ERR_GOVERNANCE_DISABLED)
    
    (match (map-get? governance-proposals { proposal-id: proposal-id })
      proposal
        (let
          (
            (user-balance-result (ft-get-balance GOVERNANCE_TOKEN tx-sender))
            (proposal-active (is-eq (get status proposal) "active"))
            (not-ended (<= stacks-block-height (get end-block proposal)))
          )
          ;; Check if proposal is active and not ended
          (asserts! (and proposal-active not-ended) ERR_PROPOSAL_NOT_ACTIVE)
          
          (match user-balance-result
            user-balance
              (begin
                ;; Check if user has enough tokens
                (asserts! (>= user-balance vote-amount) ERR_INSUFFICIENT_BALANCE)
                
                ;; Record vote
                (match (map-get? user-votes { proposal-id: proposal-id, voter: tx-sender })
                  previous-vote
                    ;; Update existing vote
                    (let
                      (
                        (previous-amount (get vote-amount previous-vote))
                        (previous-direction (get vote-direction previous-vote))
                        (votes-for (get votes-for proposal))
                        (votes-against (get votes-against proposal))
                        (new-votes-for (if vote-direction
                          (+ votes-for vote-amount (if previous-direction u0 previous-amount))
                          (- votes-for (if previous-direction previous-amount u0))))
                        (new-votes-against (if vote-direction
                          (- votes-against (if previous-direction u0 previous-amount))
                          (+ votes-against vote-amount (if previous-direction previous-amount u0))))
                      )
                      ;; Update proposal votes
                      (map-set governance-proposals
                        { proposal-id: proposal-id }
                        (merge proposal
                          {
                            votes-for: new-votes-for,
                            votes-against: new-votes-against
                          }
                        )
                      )
                      
                      ;; Update user vote
                      (map-set user-votes
                        { proposal-id: proposal-id, voter: tx-sender }
                        { vote-amount: vote-amount, vote-direction: vote-direction }
                      )
                      
                      (ok true)
                    )
                  ;; New vote
                  (let
                    (
                      (votes-for (get votes-for proposal))
                      (votes-against (get votes-against proposal))
                      (new-votes-for (if vote-direction (+ votes-for vote-amount) votes-for))
                      (new-votes-against (if vote-direction votes-against (+ votes-against vote-amount)))
                    )
                    ;; Update proposal votes
                    (map-set governance-proposals
                      { proposal-id: proposal-id }
                      (merge proposal
                        {
                          votes-for: new-votes-for,
                          votes-against: new-votes-against
                        }
                      )
                    )
                    
                    ;; Record user vote
                    (map-set user-votes
                      { proposal-id: proposal-id, voter: tx-sender }
                      { vote-amount: vote-amount, vote-direction: vote-direction }
                    )
                    
                    (ok true)
                  )
                )
              )
            err (err ERR_INSUFFICIENT_BALANCE)
          )
        )
      (err ERR_PROPOSAL_NOT_ACTIVE)
    )
  )
)

;; Execute passed proposal
(define-public (execute-proposal (proposal-id uint))
  (begin
    (asserts! (var-get governance-enabled) ERR_GOVERNANCE_DISABLED)
    
    (match (map-get? governance-proposals { proposal-id: proposal-id })
      proposal
        (let
          (
            (votes-for (get votes-for proposal))
            (votes-against (get votes-against proposal))
            (proposal-ended (> stacks-block-height (get end-block proposal)))
            (proposal-active (is-eq (get status proposal) "active"))
            (parameter-name (get parameter-name proposal))
            (proposed-value (get proposed-value proposal))
          )
          ;; Check if proposal has ended and is still active
          (asserts! (and proposal-ended proposal-active) ERR_PROPOSAL_NOT_ACTIVE)
          
          ;; Check if proposal passed (more votes for than against)
          (if (> votes-for votes-against)
            (begin
              ;; Update parameter
              (map-set protocol-parameters
                { parameter-name: parameter-name }
                { value: proposed-value }
              )
              
              ;; Update proposal status
              (map-set governance-proposals
                { proposal-id: proposal-id }
                (merge proposal { status: "executed" })
              )
              
              (ok true)
            )
            (begin
              ;; Update proposal status to rejected
              (map-set governance-proposals
                { proposal-id: proposal-id }
                (merge proposal { status: "rejected" })
              )
              
              (ok false)
            )
          )
        )
      (err ERR_PROPOSAL_NOT_ACTIVE)
    )
  )
)

;; Emergency functions (only callable by contract owner)
(define-public (toggle-protocol-pause)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set protocol-paused (not (var-get protocol-paused)))
    (ok (var-get protocol-paused))
  )
)

;; Mint governance tokens (for testing or initial distribution)
(define-public (mint-governance-tokens (recipient principal) (amount uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (ft-mint? GOVERNANCE_TOKEN amount recipient)
  )
)

;; Set oracle contract (can only be called by contract owner)
(define-public (set-oracle (new-oracle principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set oracle-contract new-oracle)
    (ok true)
  )
)

(define-public (set-btc-price (new-price uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set btc-price new-price)
    (ok true)
  )
)