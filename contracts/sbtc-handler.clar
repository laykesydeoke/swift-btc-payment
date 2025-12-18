;; title: SwiftBTC sBTC Handler Contract
;; version: 1.0.0
;; summary: Handles actual sBTC token transfers, deposits, and withdrawals
;; description: Integrates with payment processor for Bitcoin-backed payments

;; SIP-010 Token Trait Definition
(define-trait sip-010-trait
  (
    (transfer (uint principal principal (optional (buff 34))) (response bool uint))
    (get-name () (response (string-ascii 32) uint))
    (get-symbol () (response (string-ascii 32) uint))
    (get-decimals () (response uint uint))
    (get-balance (principal) (response uint uint))
    (get-total-supply () (response uint uint))
    (get-token-uri () (response (optional (string-utf8 256)) uint))
  )
)

;; Default sBTC contract (optional - for when sBTC is available)
;; Set to 'none' initially, can be configured by admin when sBTC contract is deployed
(define-data-var sbtc-contract-enabled bool false)
(define-data-var sbtc-contract-address (optional principal) none)

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-UNAUTHORIZED (err u300))
(define-constant ERR-INVALID-AMOUNT (err u301))
(define-constant ERR-INSUFFICIENT-BALANCE (err u302))
(define-constant ERR-TRANSFER-FAILED (err u303))
(define-constant ERR-INVALID-RECIPIENT (err u304))
(define-constant ERR-ESCROW-NOT-FOUND (err u305))
(define-constant ERR-ESCROW-ALREADY-RELEASED (err u306))
(define-constant ERR-PAYMENT-PROCESSOR-ONLY (err u307))
(define-constant ERR-INVALID-CONVERSION-RATE (err u308))
(define-constant ERR-SLIPPAGE-EXCEEDED (err u309))

;; Contract principals
(define-data-var payment-processor-contract (optional principal) none)
(define-data-var authorized-operators (list 10 principal) (list))

;; sBTC conversion and fee settings
(define-data-var sbtc-conversion-rate uint u100000000) ;; 1:1 ratio in satoshis
(define-data-var withdrawal-fee uint u10000) ;; 0.0001 sBTC withdrawal fee
(define-data-var deposit-fee uint u5000) ;; 0.00005 sBTC deposit fee
(define-data-var max-slippage uint u500) ;; 5% max slippage in basis points

;; Data Maps
(define-map escrow-deposits
  { payment-id: uint }
  {
    payer: principal,
    merchant: principal,
    amount: uint,
    deposited-at: uint,
    released: bool,
    release-height: (optional uint),
    tx-hash: (optional (buff 32))
  }
)

(define-map merchant-sbtc-balances
  { merchant: principal }
  { 
    available: uint, 
    escrowed: uint,
    total-deposited: uint,
    total-withdrawn: uint
  }
)

(define-map withdrawal-requests
  { request-id: uint }
  {
    merchant: principal,
    amount: uint,
    recipient-address: (buff 20),
    requested-at: uint,
    processed: bool,
    tx-hash: (optional (buff 32))
  }
)

(define-map conversion-history
  { tx-id: uint }
  {
    from-amount: uint,
    to-amount: uint,
    conversion-rate: uint,
    fee-paid: uint,
    timestamp: uint,
    user: principal
  }
)

;; Data variables for tracking
(define-data-var withdrawal-counter uint u0)
(define-data-var conversion-counter uint u0)
(define-data-var total-sbtc-locked uint u0)

;; Read-only functions

(define-read-only (get-escrow-deposit (payment-id uint))
  (map-get? escrow-deposits { payment-id: payment-id })
)

(define-read-only (get-merchant-sbtc-balance (merchant principal))
  (default-to 
    { available: u0, escrowed: u0, total-deposited: u0, total-withdrawn: u0 }
    (map-get? merchant-sbtc-balances { merchant: merchant })
  )
)

(define-read-only (get-withdrawal-request (request-id uint))
  (map-get? withdrawal-requests { request-id: request-id })
)

(define-read-only (get-sbtc-conversion-rate)
  (var-get sbtc-conversion-rate)
)

(define-read-only (calculate-withdrawal-amount (gross-amount uint))
  (let ((fee (var-get withdrawal-fee)))
    (if (> gross-amount fee)
      (ok (- gross-amount fee))
      (err ERR-INSUFFICIENT-BALANCE)
    )
  )
)

(define-read-only (calculate-deposit-amount (gross-amount uint))
  (let ((fee (var-get deposit-fee)))
    (if (> gross-amount fee)
      (ok (- gross-amount fee))
      (err ERR-INSUFFICIENT-BALANCE)
    )
  )
)

;; Get contract sBTC balance (returns zero when no sBTC contract configured)
(define-read-only (get-contract-sbtc-balance)
  (if (var-get sbtc-contract-enabled)
    (match (var-get sbtc-contract-address)
      contract-addr (ok u0) ;; Would call external contract here when available
      (ok u0)
    )
    (ok u0)
  )
)

(define-read-only (get-sbtc-token-contract)
  (var-get sbtc-contract-address)
)

(define-read-only (is-sbtc-integration-enabled)
  (var-get sbtc-contract-enabled)
)

(define-read-only (get-total-locked-sbtc)
  (var-get total-sbtc-locked)
)

(define-read-only (is-authorized-operator (operator principal))
  (is-some (index-of (var-get authorized-operators) operator))
)

;; Private functions

(define-private (increment-withdrawal-counter)
  (let ((current (var-get withdrawal-counter)))
    (var-set withdrawal-counter (+ current u1))
    (+ current u1)
  )
)

(define-private (increment-conversion-counter)
  (let ((current (var-get conversion-counter)))
    (var-set conversion-counter (+ current u1))
    (+ current u1)
  )
)

(define-private (update-merchant-sbtc-balance 
  (merchant principal) 
  (available-delta int) 
  (escrowed-delta int)
  (deposited-delta int)
  (withdrawn-delta int)
)
  (let ((current-balance (get-merchant-sbtc-balance merchant)))
    (map-set merchant-sbtc-balances
      { merchant: merchant }
      {
        available: (+ (get available current-balance) 
                     (if (< available-delta 0) u0 (to-uint available-delta))),
        escrowed: (+ (get escrowed current-balance) 
                    (if (< escrowed-delta 0) u0 (to-uint escrowed-delta))),
        total-deposited: (+ (get total-deposited current-balance) 
                           (if (< deposited-delta 0) u0 (to-uint deposited-delta))),
        total-withdrawn: (+ (get total-withdrawn current-balance) 
                           (if (< withdrawn-delta 0) u0 (to-uint withdrawn-delta)))
      }
    )
  )
)

(define-private (validate-slippage (expected-amount uint) (actual-amount uint))
  (let (
    (max-slippage-amount (/ (* expected-amount (var-get max-slippage)) u10000))
    (difference (if (> expected-amount actual-amount) 
                   (- expected-amount actual-amount) 
                   (- actual-amount expected-amount)))
  )
    (<= difference max-slippage-amount)
  )
)

;; Public functions

;; Deposit sBTC into escrow for payment
(define-public (deposit-for-payment 
  (payment-id uint) 
  (merchant principal) 
  (amount uint)
)
  (let (
    (payer tx-sender)
    (net-amount (unwrap! (calculate-deposit-amount amount) ERR-INVALID-AMOUNT))
  )
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (is-none (get-escrow-deposit payment-id)) ERR-ESCROW-ALREADY-RELEASED)
    
    ;; For development: simulate sBTC transfer (replace with real contract call when available)
    ;; (try! (contract-call? SBTC-CONTRACT transfer amount payer (as-contract tx-sender) none))
    ;; Simulated transfer - in production, integrate with actual sBTC contract
    
    ;; Create escrow deposit record
    (map-set escrow-deposits
      { payment-id: payment-id }
      {
        payer: payer,
        merchant: merchant,
        amount: net-amount,
        deposited-at: stacks-block-height,
        released: false,
        release-height: none,
        tx-hash: none
      }
    )
    
    ;; Update merchant escrowed balance
    (update-merchant-sbtc-balance merchant 0 (to-int net-amount) (to-int amount) 0)
    
    ;; Update total locked sBTC
    (var-set total-sbtc-locked (+ (var-get total-sbtc-locked) net-amount))
    
    (print {
      event: "sbtc-deposited",
      payment-id: payment-id,
      payer: payer,
      merchant: merchant,
      gross-amount: amount,
      net-amount: net-amount,
      fee: (- amount net-amount)
    })
    
    (ok net-amount)
  )
)

;; Release escrowed sBTC to merchant (called by payment processor)
(define-public (release-escrow-to-merchant (payment-id uint))
  (let (
    (caller tx-sender)
    (escrow (unwrap! (get-escrow-deposit payment-id) ERR-ESCROW-NOT-FOUND))
  )
    ;; Verify caller is authorized payment processor
    (asserts! (is-eq (some caller) (var-get payment-processor-contract)) ERR-PAYMENT-PROCESSOR-ONLY)
    (asserts! (not (get released escrow)) ERR-ESCROW-ALREADY-RELEASED)
    
    ;; For development: simulate sBTC transfer to merchant
    ;; (try! (as-contract (contract-call? SBTC-CONTRACT transfer (get amount escrow) tx-sender (get merchant escrow) none)))
    ;; Simulated transfer - in production, integrate with actual sBTC contract
    
    ;; Update escrow record
    (map-set escrow-deposits
      { payment-id: payment-id }
      (merge escrow {
        released: true,
        release-height: (some stacks-block-height)
      })
    )
    
    ;; Update merchant balances
    (update-merchant-sbtc-balance 
      (get merchant escrow)
      (to-int (get amount escrow))  ;; Add to available
      (- 0 (to-int (get amount escrow)))  ;; Remove from escrowed
      0
      0
    )
    
    ;; Update total locked sBTC
    (var-set total-sbtc-locked (- (var-get total-sbtc-locked) (get amount escrow)))
    
    (print {
      event: "escrow-released",
      payment-id: payment-id,
      merchant: (get merchant escrow),
      amount: (get amount escrow)
    })
    
    (ok (get amount escrow))
  )
)

;; Refund escrowed sBTC to payer (in case of payment failure)
(define-public (refund-escrow-to-payer (payment-id uint))
  (let (
    (caller tx-sender)
    (escrow (unwrap! (get-escrow-deposit payment-id) ERR-ESCROW-NOT-FOUND))
  )
    ;; Verify caller is authorized payment processor
    (asserts! (is-eq (some caller) (var-get payment-processor-contract)) ERR-PAYMENT-PROCESSOR-ONLY)
    (asserts! (not (get released escrow)) ERR-ESCROW-ALREADY-RELEASED)
    
    ;; For development: simulate sBTC refund to payer
    ;; (try! (as-contract (contract-call? SBTC-CONTRACT transfer (get amount escrow) tx-sender (get payer escrow) none)))
    ;; Simulated refund - in production, integrate with actual sBTC contract
    
    ;; Update escrow record
    (map-set escrow-deposits
      { payment-id: payment-id }
      (merge escrow {
        released: true,
        release-height: (some stacks-block-height)
      })
    )
    
    ;; Update merchant balances (remove from escrowed)
    (update-merchant-sbtc-balance 
      (get merchant escrow)
      0
      (- 0 (to-int (get amount escrow)))  ;; Remove from escrowed
      (- 0 (to-int (get amount escrow)))  ;; Reduce total deposited
      0
    )
    
    ;; Update total locked sBTC
    (var-set total-sbtc-locked (- (var-get total-sbtc-locked) (get amount escrow)))
    
    (print {
      event: "escrow-refunded",
      payment-id: payment-id,
      payer: (get payer escrow),
      amount: (get amount escrow)
    })
    
    (ok (get amount escrow))
  )
)

;; Merchant withdrawal to Bitcoin address
(define-public (request-withdrawal 
  (amount uint) 
  (bitcoin-address (buff 20))
)
  (let (
    (merchant tx-sender)
    (request-id (increment-withdrawal-counter))
    (balance (get-merchant-sbtc-balance merchant))
    (net-amount (unwrap! (calculate-withdrawal-amount amount) ERR-INVALID-AMOUNT))
  )
    (asserts! (>= (get available balance) amount) ERR-INSUFFICIENT-BALANCE)
    (asserts! (> (len bitcoin-address) u0) ERR-INVALID-RECIPIENT)
    
    ;; Create withdrawal request
    (map-set withdrawal-requests
      { request-id: request-id }
      {
        merchant: merchant,
        amount: net-amount,
        recipient-address: bitcoin-address,
        requested-at: stacks-block-height,
        processed: false,
        tx-hash: none
      }
    )
    
    ;; Update merchant balance (reduce available)
    (update-merchant-sbtc-balance merchant (- 0 (to-int amount)) 0 0 (to-int net-amount))
    
    (print {
      event: "withdrawal-requested",
      request-id: request-id,
      merchant: merchant,
      gross-amount: amount,
      net-amount: net-amount,
      bitcoin-address: bitcoin-address
    })
    
    (ok request-id)
  )
)

;; Convert between different payment amounts (utility function)
(define-public (convert-payment-amount 
  (from-amount uint) 
  (expected-to-amount uint)
)
  (let (
    (conversion-id (increment-conversion-counter))
    (rate (var-get sbtc-conversion-rate))
    (calculated-amount (/ (* from-amount rate) u100000000))
    (fee (var-get deposit-fee))
    (net-amount (- calculated-amount fee))
  )
    (asserts! (> from-amount u0) ERR-INVALID-AMOUNT)
    (asserts! (validate-slippage expected-to-amount net-amount) ERR-SLIPPAGE-EXCEEDED)
    
    ;; Record conversion
    (map-set conversion-history
      { tx-id: conversion-id }
      {
        from-amount: from-amount,
        to-amount: net-amount,
        conversion-rate: rate,
        fee-paid: fee,
        timestamp: stacks-block-height,
        user: tx-sender
      }
    )
    
    (print {
      event: "amount-converted",
      conversion-id: conversion-id,
      from-amount: from-amount,
      to-amount: net-amount,
      rate: rate,
      fee: fee
    })
    
    (ok net-amount)
  )
)

;; Admin functions

;; Admin functions

;; Configure sBTC contract integration (admin only)
(define-public (configure-sbtc-contract (contract-address principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (var-set sbtc-contract-address (some contract-address))
    (var-set sbtc-contract-enabled true)
    (print { event: "sbtc-contract-configured", contract: contract-address })
    (ok true)
  )
)

;; Disable sBTC integration (admin only)
(define-public (disable-sbtc-integration)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (var-set sbtc-contract-enabled false)
    (print { event: "sbtc-integration-disabled" })
    (ok true)
  )
)

;; Set payment processor contract (admin only)
(define-public (set-payment-processor (processor principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (var-set payment-processor-contract (some processor))
    (ok true)
  )
)

;; Update conversion rate (admin only)
(define-public (update-conversion-rate (new-rate uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (> new-rate u0) ERR-INVALID-CONVERSION-RATE)
    (var-set sbtc-conversion-rate new-rate)
    (ok true)
  )
)

;; Update fees (admin only)
(define-public (update-fees (new-withdrawal-fee uint) (new-deposit-fee uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (var-set withdrawal-fee new-withdrawal-fee)
    (var-set deposit-fee new-deposit-fee)
    (ok true)
  )
)

;; Add authorized operator (admin only)
(define-public (add-authorized-operator (operator principal))
  (let ((current-operators (var-get authorized-operators)))
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (is-none (index-of current-operators operator)) ERR-UNAUTHORIZED)
    (asserts! (< (len current-operators) u10) ERR-UNAUTHORIZED) ;; Check list isn't full
    (var-set authorized-operators (unwrap! (as-max-len? (append current-operators operator) u10) ERR-UNAUTHORIZED))
    (print { event: "operator-added", operator: operator })
    (ok true)
  )
)

;; Process withdrawal (operator only)
(define-public (process-withdrawal (request-id uint) (tx-hash (buff 32)))
  (let (
    (request (unwrap! (get-withdrawal-request request-id) ERR-ESCROW-NOT-FOUND))
  )
    (asserts! (or (is-eq tx-sender CONTRACT-OWNER) 
                  (is-authorized-operator tx-sender)) ERR-UNAUTHORIZED)
    (asserts! (not (get processed request)) ERR-ESCROW-ALREADY-RELEASED)
    
    ;; Mark withdrawal as processed
    (map-set withdrawal-requests
      { request-id: request-id }
      (merge request {
        processed: true,
        tx-hash: (some tx-hash)
      })
    )
    
    (print {
      event: "withdrawal-processed",
      request-id: request-id,
      merchant: (get merchant request),
      amount: (get amount request),
      tx-hash: tx-hash
    })
    
    (ok true)
  )
)
