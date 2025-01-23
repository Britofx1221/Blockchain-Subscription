;; Subscription Service Smart Contract

;; Error codes
(define-constant ERROR-UNAUTHORIZED-ADMIN-ACCESS (err u100))
(define-constant ERROR-SUBSCRIPTION-ALREADY-EXISTS (err u101))
(define-constant ERROR-NO-ACTIVE-USER-SUBSCRIPTION (err u102))
(define-constant ERROR-INSUFFICIENT-USER-BALANCE (err u103))
(define-constant ERROR-INVALID-SUBSCRIPTION-TIER (err u104))
(define-constant ERROR-USER-SUBSCRIPTION-EXPIRED (err u105))
(define-constant ERROR-INVALID-REFUND-CALCULATION (err u106))
(define-constant ERROR-IDENTICAL-TIER-UPGRADE (err u107))
(define-constant ERROR-REFUND-PERIOD-ELAPSED (err u108))
(define-constant ERROR-INVALID-TIER-CHANGE (err u109))
(define-constant ERROR-INVALID-FUNCTION-PARAMETERS (err u110))

;; Data vars
(define-data-var contract-owner principal tx-sender)
(define-data-var minimum-tier-subscription-cost uint u100)
(define-data-var standard-subscription-duration-seconds uint u2592000)
(define-data-var maximum-user-refund-window-seconds uint u259200)  ;; 3 days in seconds
(define-data-var tier-change-transaction-fee uint u1000000)     ;; 1 STX fee for changing tiers

;; Data maps
(define-map UserSubscriptionDetails
    principal
    {
        is-subscription-active: bool,
        subscription-start-block: uint,
        subscription-end-block: uint,
        current-subscription-tier: (string-ascii 20),
        last-subscription-payment-amount: uint,
        user-subscription-credit-balance: uint
    }
)

(define-map SubscriptionTierConfig
    (string-ascii 20)
    {
        tier-subscription-cost: uint,
        tier-duration-blocks: uint,
        tier-features: (list 10 (string-ascii 50)),
        tier-level: uint,  ;; Higher number means higher tier
        are-refunds-allowed: bool
    }
)

(define-map UserRefundTransactionHistory
    { user-address: principal, refund-block-timestamp: uint }
    {
        refund-amount: uint,
        refund-justification: (string-ascii 50)
    }
)

;; Read-only functions
(define-read-only (get-user-subscription-details (user-address principal))
    (map-get? UserSubscriptionDetails user-address)
)

(define-read-only (get-subscription-tier-details (tier-name (string-ascii 20)))
    (map-get? SubscriptionTierConfig tier-name)
)

(define-read-only (calculate-user-subscription-time-remaining (user-address principal))
    (let (
        (user-subscription-info (unwrap! (map-get? UserSubscriptionDetails user-address) u0))
    )
    (if (get is-subscription-active user-subscription-info)
        (- (get subscription-end-block user-subscription-info) block-height)
        u0
    ))
)

(define-read-only (calculate-user-eligible-refund-amount (user-address principal))
    (let (
        (user-subscription-info (unwrap! (map-get? UserSubscriptionDetails user-address) u0))
        (elapsed-subscription-blocks (- block-height (get subscription-start-block user-subscription-info)))
        (total-subscription-period (- (get subscription-end-block user-subscription-info) (get subscription-start-block user-subscription-info)))
        (original-subscription-payment (get last-subscription-payment-amount user-subscription-info))
    )
    (if (> elapsed-subscription-blocks (var-get maximum-user-refund-window-seconds))
        u0
        (/ (* original-subscription-payment (- total-subscription-period elapsed-subscription-blocks)) total-subscription-period)
    ))
)

;; Private functions
(define-private (verify-admin-authorization)
    (is-eq tx-sender (var-get contract-owner))
)

(define-private (process-user-refund (user principal) (refund-amount uint) (refund-reason (string-ascii 50)))
    (begin
        (try! (stx-transfer? refund-amount (var-get contract-owner) user))
        (map-set UserRefundTransactionHistory
            { user-address: user, refund-block-timestamp: block-height }
            {
                refund-amount: refund-amount,
                refund-justification: refund-reason
            }
        )
        (ok true)
    )
)

(define-private (validate-tier-feature-list (feature-list (list 10 (string-ascii 50))))
    (let ((total-feature-count (len feature-list)))
        (and (> total-feature-count u0) (<= total-feature-count u10))
    )
)

;; Function for creating subscription tiers
(define-public (create-subscription-tier 
    (tier-name (string-ascii 20))
    (tier-cost uint)
    (tier-duration uint)
    (tier-features (list 10 (string-ascii 50)))
    (tier-hierarchy-level uint)
    (enable-tier-refunds bool))
    (begin
        (asserts! (verify-admin-authorization) ERROR-UNAUTHORIZED-ADMIN-ACCESS)
        (asserts! (> tier-cost u0) ERROR-INVALID-FUNCTION-PARAMETERS)
        (asserts! (> tier-duration u0) ERROR-INVALID-FUNCTION-PARAMETERS)
        (asserts! (> tier-hierarchy-level u0) ERROR-INVALID-FUNCTION-PARAMETERS)
        (asserts! (validate-tier-feature-list tier-features) ERROR-INVALID-FUNCTION-PARAMETERS)
        (asserts! (not (is-eq tier-name "")) ERROR-INVALID-FUNCTION-PARAMETERS)
        (ok (map-set SubscriptionTierConfig
            tier-name
            {
                tier-subscription-cost: tier-cost,
                tier-duration-blocks: tier-duration,
                tier-features: tier-features,
                tier-level: tier-hierarchy-level,
                are-refunds-allowed: enable-tier-refunds
            }
        ))
    )
)

;; Public functions for plan management
(define-public (subscribe-to-tier (selected-tier-name (string-ascii 20)))
    (let (
        (tier-details (unwrap! (map-get? SubscriptionTierConfig selected-tier-name) ERROR-INVALID-SUBSCRIPTION-TIER))
        (subscription-start-block block-height)
        (tier-subscription-price (get tier-subscription-cost tier-details))
        (existing-user-subscription (get-user-subscription-details tx-sender))
    )
    (asserts! (is-none existing-user-subscription) ERROR-SUBSCRIPTION-ALREADY-EXISTS)
    (asserts! (not (is-eq selected-tier-name "")) ERROR-INVALID-FUNCTION-PARAMETERS)
    (asserts! (> tier-subscription-price u0) ERROR-INVALID-FUNCTION-PARAMETERS)
    (try! (stx-transfer? tier-subscription-price tx-sender (var-get contract-owner)))
    
    (ok (map-set UserSubscriptionDetails
        tx-sender
        {
            is-subscription-active: true,
            subscription-start-block: subscription-start-block,
            subscription-end-block: (+ subscription-start-block (get tier-duration-blocks tier-details)),
            current-subscription-tier: selected-tier-name,
            last-subscription-payment-amount: tier-subscription-price,
            user-subscription-credit-balance: u0
        }
    ))
))

(define-public (request-subscription-refund (refund-reason (string-ascii 50)))
    (let (
        (user-subscription-info (unwrap! (map-get? UserSubscriptionDetails tx-sender) ERROR-NO-ACTIVE-USER-SUBSCRIPTION))
        (tier-details (unwrap! (map-get? SubscriptionTierConfig (get current-subscription-tier user-subscription-info)) ERROR-INVALID-SUBSCRIPTION-TIER))
        (calculated-refund-amount (calculate-user-eligible-refund-amount tx-sender))
    )
    (asserts! (get is-subscription-active user-subscription-info) ERROR-NO-ACTIVE-USER-SUBSCRIPTION)
    (asserts! (get are-refunds-allowed tier-details) ERROR-INVALID-REFUND-CALCULATION)
    (asserts! (> calculated-refund-amount u0) ERROR-INVALID-REFUND-CALCULATION)
    (asserts! (not (is-eq refund-reason "")) ERROR-INVALID-FUNCTION-PARAMETERS)
    
    (try! (process-user-refund tx-sender calculated-refund-amount refund-reason))
    
    (ok (map-set UserSubscriptionDetails
        tx-sender
        {
            is-subscription-active: false,
            subscription-start-block: (get subscription-start-block user-subscription-info),
            subscription-end-block: block-height,
            current-subscription-tier: (get current-subscription-tier user-subscription-info),
            last-subscription-payment-amount: u0,
            user-subscription-credit-balance: u0
        }
    ))
))

(define-public (upgrade-subscription-tier (new-tier-name (string-ascii 20)))
    (begin
        (let (
            (current-user-subscription (unwrap! (map-get? UserSubscriptionDetails tx-sender) ERROR-NO-ACTIVE-USER-SUBSCRIPTION))
            (current-tier (unwrap! (map-get? SubscriptionTierConfig (get current-subscription-tier current-user-subscription)) ERROR-INVALID-SUBSCRIPTION-TIER))
            (new-tier (unwrap! (map-get? SubscriptionTierConfig new-tier-name) ERROR-INVALID-SUBSCRIPTION-TIER))
            (remaining-subscription-blocks (calculate-user-subscription-time-remaining tx-sender))
            (current-tier-value-remaining (* (get last-subscription-payment-amount current-user-subscription) (/ remaining-subscription-blocks (get tier-duration-blocks current-tier))))
        )
        (asserts! (get is-subscription-active current-user-subscription) ERROR-NO-ACTIVE-USER-SUBSCRIPTION)
        (asserts! (> (get tier-level new-tier) (get tier-level current-tier)) ERROR-INVALID-TIER-CHANGE)
        (asserts! (not (is-eq new-tier-name (get current-subscription-tier current-user-subscription))) ERROR-IDENTICAL-TIER-UPGRADE)
        
        (let (
            (tier-upgrade-cost (- (get tier-subscription-cost new-tier) current-tier-value-remaining))
        )
        (try! (stx-transfer? (+ tier-upgrade-cost (var-get tier-change-transaction-fee)) tx-sender (var-get contract-owner)))
        
        (ok (map-set UserSubscriptionDetails
            tx-sender
            {
                is-subscription-active: true,
                subscription-start-block: block-height,
                subscription-end-block: (+ block-height (get tier-duration-blocks new-tier)),
                current-subscription-tier: new-tier-name,
                last-subscription-payment-amount: (get tier-subscription-cost new-tier),
                user-subscription-credit-balance: u0
            }
        ))
    ))
))

(define-public (downgrade-subscription-tier (new-tier-name (string-ascii 20)))
    (begin
        (let (
            (current-user-subscription (unwrap! (map-get? UserSubscriptionDetails tx-sender) ERROR-NO-ACTIVE-USER-SUBSCRIPTION))
            (current-tier (unwrap! (map-get? SubscriptionTierConfig (get current-subscription-tier current-user-subscription)) ERROR-INVALID-SUBSCRIPTION-TIER))
            (new-tier (unwrap! (map-get? SubscriptionTierConfig new-tier-name) ERROR-INVALID-SUBSCRIPTION-TIER))
            (remaining-subscription-blocks (calculate-user-subscription-time-remaining tx-sender))
        )
        (asserts! (get is-subscription-active current-user-subscription) ERROR-NO-ACTIVE-USER-SUBSCRIPTION)
        (asserts! (< (get tier-level new-tier) (get tier-level current-tier)) ERROR-INVALID-TIER-CHANGE)
        
        (let (
            (current-tier-value-remaining (* (get last-subscription-payment-amount current-user-subscription) (/ remaining-subscription-blocks (get tier-duration-blocks current-tier))))
            (user-subscription-credit-amount (- current-tier-value-remaining (get tier-subscription-cost new-tier)))
        )
        (try! (stx-transfer? (var-get tier-change-transaction-fee) tx-sender (var-get contract-owner)))
        
        (ok (map-set UserSubscriptionDetails
            tx-sender
            {
                is-subscription-active: true,
                subscription-start-block: block-height,
                subscription-end-block: (+ block-height (get tier-duration-blocks new-tier)),
                current-subscription-tier: new-tier-name,
                last-subscription-payment-amount: (get tier-subscription-cost new-tier),
                user-subscription-credit-balance: user-subscription-credit-amount
            }
        ))
    ))
))

;; Admin functions
(define-public (update-refund-window-duration (new-refund-window-seconds uint))
    (begin
        (asserts! (verify-admin-authorization) ERROR-UNAUTHORIZED-ADMIN-ACCESS)
        (asserts! (> new-refund-window-seconds u0) ERROR-INVALID-FUNCTION-PARAMETERS)
        (ok (var-set maximum-user-refund-window-seconds new-refund-window-seconds))
    )
)

(define-public (update-tier-change-transaction-fee (updated-fee uint))
    (begin
        (asserts! (verify-admin-authorization) ERROR-UNAUTHORIZED-ADMIN-ACCESS)
        (asserts! (>= updated-fee u0) ERROR-INVALID-FUNCTION-PARAMETERS)
        (ok (var-set tier-change-transaction-fee updated-fee))
    )
)

;; Initial contract setup
(begin
    ;; Add default subscription tiers
    (try! (create-subscription-tier
        "basic-tier"  ;; Basic tier plan
        u50000000  ;; 50 STX
        u2592000   ;; 30 days
        (list 
            "Basic Platform Access"
            "Standard Customer Support"
            "Core Feature Set"
        )
        u1  ;; Tier hierarchy level
        true ;; Allow refunds
    ))
    
    (try! (create-subscription-tier
        "premium-tier"  ;; Premium tier plan
        u100000000  ;; 100 STX
        u2592000    ;; 30 days
        (list 
            "Premium Platform Access"
            "24/7 Priority Support"
            "Complete Feature Set"
            "Advanced Analytics Dashboard"
        )
        u2  ;; Tier hierarchy level
        true ;; Allow refunds
    ))
)