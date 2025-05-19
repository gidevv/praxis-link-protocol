;; Praxis Link - Bridging theoretical knowledge with practical expertise through blockchain

;; This contract enables a decentralized marketplace where users can tokenize their
;; expertise and trade them in a trustless environment with built-in governance
;; and verification mechanisms.

;; =========================================================================
;; ADMINISTRATIVE CONSTANTS
;; =========================================================================

(define-constant contract-admin tx-sender)
(define-constant error-unauthorized-access (err u200))
(define-constant error-liquidity-shortage (err u201))
(define-constant error-transaction-rejected (err u202))
(define-constant error-invalid-pricing (err u203))
(define-constant error-invalid-units (err u204))
(define-constant error-protocol-fee (err u205))
(define-constant error-reimbursement-failed (err u206))
(define-constant error-circular-reference (err u207))
(define-constant error-capacity-breached (err u208))
(define-constant error-invalid-threshold (err u209))
(define-constant error-system-locked (err u210))
(define-constant error-system-active (err u211))

;; =========================================================================
;; PROTOCOL PARAMETERS
;; =========================================================================

(define-data-var credit-base-value uint u150) ;; Base value of credits in microstacks
(define-data-var max-credits-per-entity uint u50) ;; Maximum credits an entity can add to system
(define-data-var network-fee-percentage uint u3) ;; Protocol fee percentage (e.g., 3%)
(define-data-var devaluation-coefficient uint u85) ;; Coefficient for credit value reduction (85%)
(define-data-var ecosystem-capacity-threshold uint u100000) ;; Maximum capacity of the ecosystem
(define-data-var current-ecosystem-utilization uint u0) ;; Current utilization of the ecosystem

;; =========================================================================
;; STATE STORAGE MAPPINGS
;; =========================================================================

(define-map entity-credit-inventory principal uint)
(define-map entity-quantum-balance principal uint)
(define-map available-credits {entity: principal} {units: uint, value: uint})
(define-map provider-trust-status principal bool)
(define-data-var trust-verification-fee uint u1000000) ;; 1 STX for trust verification

;; =========================================================================
;; BUNDLE OFFERINGS REGISTRY
;; =========================================================================

(define-map credit-packages 
  {provider: principal, package-id: uint} 
  {credit-units: uint, value-multiplier: uint, available: bool})
(define-data-var package-sequence-counter uint u1)

;; =========================================================================
;; GOVERNANCE FRAMEWORK
;; =========================================================================

(define-map governance-proposals uint {parameter: (string-ascii 20), 
                           proposed-value: uint, 
                           initiator: principal, 
                           support-count: uint,
                           closing-block: uint,
                           implemented: bool})
(define-data-var proposal-counter uint u1)
(define-data-var consensus-threshold uint u10)
(define-map participant-votes {participant: principal, proposal-id: uint} bool)

;; =========================================================================
;; EMERGENCY CONTROLS
;; =========================================================================

(define-data-var protocol-suspended bool false)
(define-data-var suspension-termination uint u0) ;; Block height for auto-resumption
(define-constant max-suspension-duration u1000) ;; Maximum suspension period (~7 days)

;; =========================================================================
;; PRIVATE UTILITY FUNCTIONS
;; =========================================================================

;; Calculate protocol operational fee
(define-private (derive-protocol-fee (units uint))
  (/ (* units (var-get network-fee-percentage)) u100))

;; Calculate credit value reduction for returns
(define-private (calculate-value-reduction (units uint))
  (/ (* units (var-get credit-base-value) (var-get devaluation-coefficient)) u100))

;; Update ecosystem utilization metrics
(define-private (adjust-ecosystem-utilization (delta int))
  (let (
    (current-utilization (var-get current-ecosystem-utilization))
    (updated-total (if (< delta 0)
                   (if (>= current-utilization (to-uint (- delta)))
                       (- current-utilization (to-uint (- delta)))
                       u0)
                   (+ current-utilization (to-uint delta))))
  )
    (asserts! (<= updated-total (var-get ecosystem-capacity-threshold)) error-capacity-breached)
    (var-set current-ecosystem-utilization updated-total)
    (ok true)))

;; Validate parameter name is on the allowed list for governance
(define-private (is-valid-governance-parameter (parameter (string-ascii 20)))
  (or
    (is-eq parameter "credit-base-value")
    (is-eq parameter "network-fee-percentage")
    (is-eq parameter "devaluation-coefficient")
    (is-eq parameter "max-credits-per-entity")
    (is-eq parameter "ecosystem-capacity-threshold")
  ))

;; =========================================================================
;; CREDIT MANAGEMENT FUNCTIONS
;; =========================================================================

;; Publish credits to the marketplace
(define-public (publish-credits (units uint) (unit-value uint))
  (let (
    (current-inventory (default-to u0 (map-get? entity-credit-inventory tx-sender)))
    (current-offered (get units (default-to {units: u0, value: u0} (map-get? available-credits {entity: tx-sender}))))
    (updated-offering (+ units current-offered))
  )
    ;; Validate operation parameters
    (asserts! (> units u0) error-invalid-units)
    (asserts! (> unit-value u0) error-invalid-pricing)
    (asserts! (>= current-inventory updated-offering) error-liquidity-shortage)

    ;; Update ecosystem metrics
    (try! (adjust-ecosystem-utilization (to-int units)))

    ;; Update marketplace listing
    (map-set available-credits {entity: tx-sender} {units: updated-offering, value: unit-value})

    ;; Record success event
    (print {event: "credits-published", provider: tx-sender, units: units, value: unit-value})
    (ok true)))

;; Remove credits from the marketplace
(define-public (withdraw-published-credits (units uint))
  (let (
    (current-offered (get units (default-to {units: u0, value: u0} (map-get? available-credits {entity: tx-sender}))))
  )
    ;; Validate withdrawal parameters
    (asserts! (>= current-offered units) error-liquidity-shortage)

    ;; Update ecosystem metrics
    (try! (adjust-ecosystem-utilization (to-int (- units))))

    ;; Update marketplace listing
    (map-set available-credits {entity: tx-sender} 
             {units: (- current-offered units), 
              value: (get value (default-to {units: u0, value: u0} (map-get? available-credits {entity: tx-sender})))})

    ;; Record withdraw event
    (print {event: "credits-withdrawn", provider: tx-sender, units: units})
    (ok true)))

;; Exchange quantum tokens for credits
(define-public (acquire-credits (provider principal) (units uint))
  (let (
    (credit-data (default-to {units: u0, value: u0} (map-get? available-credits {entity: provider})))
    (transaction-value (* units (get value credit-data)))
    (protocol-fee (derive-protocol-fee transaction-value))
    (total-cost (+ transaction-value protocol-fee))
    (provider-inventory (default-to u0 (map-get? entity-credit-inventory provider)))
    (buyer-balance (default-to u0 (map-get? entity-quantum-balance tx-sender)))
    (provider-balance (default-to u0 (map-get? entity-quantum-balance provider)))
    (admin-balance (default-to u0 (map-get? entity-quantum-balance contract-admin)))
  )
    ;; Validate transaction parameters
    (asserts! (not (is-eq tx-sender provider)) error-circular-reference)
    (asserts! (> units u0) error-invalid-units)
    (asserts! (>= (get units credit-data) units) error-liquidity-shortage)
    (asserts! (>= provider-inventory units) error-liquidity-shortage)
    (asserts! (>= buyer-balance total-cost) error-liquidity-shortage)

    ;; Check for system suspension
    (asserts! (not (var-get protocol-suspended)) error-system-locked)

    ;; Update participant balances
    (map-set entity-credit-inventory provider (- provider-inventory units))
    (map-set available-credits {entity: provider} 
             {units: (- (get units credit-data) units), value: (get value credit-data)})
    (map-set entity-quantum-balance tx-sender (- buyer-balance total-cost))
    (map-set entity-credit-inventory tx-sender (+ (default-to u0 (map-get? entity-credit-inventory tx-sender)) units))
    (map-set entity-quantum-balance provider (+ provider-balance transaction-value))
    (map-set entity-quantum-balance contract-admin (+ admin-balance protocol-fee))

    ;; Record purchase event
    (print {event: "credits-acquired", buyer: tx-sender, provider: provider, units: units, value: transaction-value})
    (ok true)))

;; Return credits for partial refund
(define-public (return-credits (units uint))
  (let (
    (entity-inventory (default-to u0 (map-get? entity-credit-inventory tx-sender)))
    (refund-amount (calculate-value-reduction units))
    (protocol-balance (default-to u0 (map-get? entity-quantum-balance contract-admin)))
  )
    ;; Validate return parameters
    (asserts! (> units u0) error-invalid-units)
    (asserts! (>= entity-inventory units) error-liquidity-shortage)
    (asserts! (>= protocol-balance refund-amount) error-reimbursement-failed)

    ;; Check for system suspension
    (asserts! (not (var-get protocol-suspended)) error-system-locked)

    ;; Process the return and refund
    (map-set entity-credit-inventory tx-sender (- entity-inventory units))
    (map-set entity-quantum-balance tx-sender (+ (default-to u0 (map-get? entity-quantum-balance tx-sender)) refund-amount))
    (map-set entity-quantum-balance contract-admin (- protocol-balance refund-amount))
    (map-set entity-credit-inventory contract-admin (+ (default-to u0 (map-get? entity-credit-inventory contract-admin)) units))

    ;; Update ecosystem metrics
    (try! (adjust-ecosystem-utilization (to-int (- units))))

    ;; Record return event
    (print {event: "credits-returned", entity: tx-sender, units: units, refund: refund-amount})
    (ok true)))

;; Transfer credits directly between entities
(define-public (transfer-credits (recipient principal) (units uint))
  (let (
    (sender-inventory (default-to u0 (map-get? entity-credit-inventory tx-sender)))
  )
    ;; Validate transfer parameters
    (asserts! (not (is-eq tx-sender recipient)) error-circular-reference)
    (asserts! (> units u0) error-invalid-units)
    (asserts! (>= sender-inventory units) error-liquidity-shortage)

    ;; Check for system suspension
    (asserts! (not (var-get protocol-suspended)) error-system-locked)

    ;; Execute transfer
    (map-set entity-credit-inventory tx-sender (- sender-inventory units))
    (map-set entity-credit-inventory recipient (+ (default-to u0 (map-get? entity-credit-inventory recipient)) units))

    ;; Record transfer event
    (print {event: "credit-transfer", sender: tx-sender, recipient: recipient, units: units})
    (ok true)))

;; Update credit pricing
(define-public (adjust-credit-value (new-value uint))
  (let (
    (credit-data (default-to {units: u0, value: u0} (map-get? available-credits {entity: tx-sender})))
    (available-units (get units credit-data))
  )
    ;; Validate pricing update
    (asserts! (> new-value u0) error-invalid-pricing)
    (asserts! (> available-units u0) error-liquidity-shortage)

    ;; Check for system suspension
    (asserts! (not (var-get protocol-suspended)) error-system-locked)

    ;; Update marketplace listing
    (map-set available-credits {entity: tx-sender} 
             {units: available-units, value: new-value})

    ;; Record value update event
    (print {event: "value-adjusted", provider: tx-sender, old-value: (get value credit-data), new-value: new-value})
    (ok true)))

;; =========================================================================
;; TRUST VERIFICATION SYSTEM
;; =========================================================================

(define-public (certify-provider (provider principal))
  (let (
    (admin-status (is-eq tx-sender contract-admin))
    (current-fee (var-get trust-verification-fee))
    (requester-balance (default-to u0 (map-get? entity-quantum-balance tx-sender)))
    (admin-balance (default-to u0 (map-get? entity-quantum-balance contract-admin)))
    (self-certification (is-eq tx-sender provider))
  )
    ;; Validate certification request
    (asserts! (or admin-status self-certification) error-unauthorized-access)

    ;; Check for system suspension
    (asserts! (not (var-get protocol-suspended)) error-system-locked)

    ;; Process certification fee if self-certifying
    (if self-certification
        (begin
          (asserts! (>= requester-balance current-fee) error-liquidity-shortage)
          (map-set entity-quantum-balance tx-sender (- requester-balance current-fee))
          (map-set entity-quantum-balance contract-admin (+ admin-balance current-fee))
        )
        true
    )

    ;; Record certification
    (map-set provider-trust-status provider true)

    ;; Record certification event
    (print {event: "provider-certified", provider: provider, certifier: tx-sender})
    (ok true)))

;; =========================================================================
;; CREDIT PACKAGE MANAGEMENT
;; =========================================================================


(define-public (acquire-credit-package (provider principal) (package-id uint))
  (let (
    (package-data (default-to {credit-units: u0, value-multiplier: u0, available: false}
                 (map-get? credit-packages {provider: provider, package-id: package-id})))
    (credit-data (default-to {units: u0, value: u0} 
                  (map-get? available-credits {entity: provider})))
    (base-value (* (get credit-units package-data) (get value credit-data)))
    (discount-amount (/ (* base-value (get value-multiplier package-data)) u100))
    (discounted-value (- base-value discount-amount))
    (protocol-fee (derive-protocol-fee discounted-value))
    (total-cost (+ discounted-value protocol-fee))
    (buyer-balance (default-to u0 (map-get? entity-quantum-balance tx-sender)))
    (provider-balance (default-to u0 (map-get? entity-quantum-balance provider)))
    (admin-balance (default-to u0 (map-get? entity-quantum-balance contract-admin)))
    (units (get credit-units package-data))
  )
    ;; Validate package purchase
    (asserts! (not (is-eq tx-sender provider)) error-circular-reference)
    (asserts! (get available package-data) error-transaction-rejected)
    (asserts! (>= buyer-balance total-cost) error-liquidity-shortage)

    ;; Check for system suspension
    (asserts! (not (var-get protocol-suspended)) error-system-locked)

    ;; Process payment
    (map-set entity-quantum-balance tx-sender (- buyer-balance total-cost))
    (map-set entity-quantum-balance provider (+ provider-balance discounted-value))
    (map-set entity-quantum-balance contract-admin (+ admin-balance protocol-fee))

    ;; Transfer credits
    (map-set entity-credit-inventory tx-sender 
             (+ (default-to u0 (map-get? entity-credit-inventory tx-sender)) units))

    ;; Record package purchase event
    (print {event: "package-acquired", 
            buyer: tx-sender, 
            provider: provider, 
            package-id: package-id,
            units: units,
            value: discounted-value})
    (ok true)))

;; =========================================================================
;; EMERGENCY MANAGEMENT FUNCTIONS
;; =========================================================================

(define-public (suspend-protocol-operations (blocks uint))
  (let (
    (current-height block-height)
    (expiry-block (+ current-height blocks))
  )
    ;; Validate suspension request
    (asserts! (is-eq tx-sender contract-admin) error-unauthorized-access)
    (asserts! (<= blocks max-suspension-duration) error-capacity-breached)

    ;; Set suspension status
    (var-set protocol-suspended true)
    (var-set suspension-termination expiry-block)

    ;; Record suspension event
    (print {event: "protocol-suspended", 
            initiated-by: tx-sender, 
            current-block: current-height,
            expiry-block: expiry-block,
            duration: blocks})

    ;; Return appropriate message
    (if (var-get protocol-suspended)
        (ok "Protocol suspension extended")
        (ok "Protocol suspended successfully"))
  ))

;; =========================================================================
;; GOVERNANCE FUNCTIONS
;; =========================================================================

(define-public (submit-governance-proposal (parameter (string-ascii 20)) (proposed-value uint))
  (let (
    (proposer-balance (default-to u0 (map-get? entity-quantum-balance tx-sender)))
    (proposal-fee u1000000) ;; 1 STX proposal submission fee
    (admin-balance (default-to u0 (map-get? entity-quantum-balance contract-admin)))
    (proposal-id (var-get proposal-counter))
    (deadline (+ block-height u1440)) ;; ~10 days at 10 min blocks
    (parameter-valid (is-valid-governance-parameter parameter))
  )
    ;; Validate proposal submission
    (asserts! parameter-valid error-transaction-rejected)
    (asserts! (>= proposer-balance proposal-fee) error-liquidity-shortage)

    ;; Check for system suspension
    (asserts! (not (var-get protocol-suspended)) error-system-locked)

    ;; Process proposal fee
    (map-set entity-quantum-balance tx-sender (- proposer-balance proposal-fee))
    (map-set entity-quantum-balance contract-admin (+ admin-balance proposal-fee))
    ;; Increment proposal counter
    (var-set proposal-counter (+ proposal-id u1))

    ;; Record proposal submission event
    (print {event: "proposal-submitted", 
            id: proposal-id, 
            parameter: parameter,
            proposed-value: proposed-value,
            initiator: tx-sender,
            deadline: deadline})
    (ok proposal-id)))

(define-public (vote-on-proposal (proposal-id uint))
  (let (
    (proposal-data (default-to {parameter: "", 
                              proposed-value: u0, 
                              initiator: tx-sender, 
                              support-count: u0,
                              closing-block: u0,
                              implemented: false}
                   (map-get? governance-proposals proposal-id)))
    (has-voted (default-to false (map-get? participant-votes {participant: tx-sender, proposal-id: proposal-id})))
    (current-votes (get support-count proposal-data))
    (voter-credits (default-to u0 (map-get? entity-credit-inventory tx-sender)))
    (minimum-credits u5) ;; Minimum credits required to vote
  )
    ;; Validate voting eligibility
    (asserts! (not has-voted) error-transaction-rejected)
    (asserts! (>= voter-credits minimum-credits) error-unauthorized-access)
    (asserts! (< block-height (get closing-block proposal-data)) error-transaction-rejected)
    (asserts! (not (get implemented proposal-data)) error-transaction-rejected)

    ;; Check for system suspension
    (asserts! (not (var-get protocol-suspended)) error-system-locked)

    ;; Record vote
    (map-set participant-votes {participant: tx-sender, proposal-id: proposal-id} true)

    ;; Update vote count
    (map-set governance-proposals proposal-id
      (merge proposal-data {support-count: (+ current-votes u1)}))

    (ok true)))

;; Implement approved parameter change
(define-private (implement-proposal (parameter (string-ascii 20)) (new-value uint))
  (begin
    (if (is-eq parameter "credit-base-value")
        (var-set credit-base-value new-value)
        false)
    (if (is-eq parameter "network-fee-percentage")
        (var-set network-fee-percentage new-value)
        false)
    (if (is-eq parameter "devaluation-coefficient")
        (var-set devaluation-coefficient new-value)
        false)
    (if (is-eq parameter "max-credits-per-entity")
        (var-set max-credits-per-entity new-value)
        false)
    (if (is-eq parameter "ecosystem-capacity-threshold")
        (var-set ecosystem-capacity-threshold new-value)
        false)
    (ok true)))

