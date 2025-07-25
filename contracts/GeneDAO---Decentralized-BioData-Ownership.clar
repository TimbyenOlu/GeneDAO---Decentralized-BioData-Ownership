(define-non-fungible-token bio-data uint)

(define-fungible-token gene-token)

(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-insufficient-balance (err u102))
(define-constant err-already-exists (err u103))
(define-constant err-unauthorized (err u104))
(define-constant err-invalid-proposal (err u105))
(define-constant err-proposal-expired (err u106))
(define-constant err-already-voted (err u107))
(define-constant err-insufficient-stake (err u108))

(define-data-var next-bio-data-id uint u1)
(define-data-var next-proposal-id uint u1)
(define-data-var min-stake-amount uint u1000)
(define-data-var proposal-duration uint u1440)

(define-map bio-data-metadata uint {
    owner: principal,
    data-hash: (buff 32),
    price: uint,
    available: bool,
    created-at: uint
})

(define-map research-stakes principal {
    amount: uint,
    locked-until: uint
})

(define-map proposals uint {
    proposer: principal,
    target-data-ids: (list 10 uint),
    stake-amount: uint,
    votes-for: uint,
    votes-against: uint,
    created-at: uint,
    expires-at: uint,
    executed: bool
})

(define-map proposal-votes {proposal-id: uint, voter: principal} bool)

(define-map data-licenses {data-id: uint, researcher: principal} {
    expires-at: uint,
    price-paid: uint
})

(define-map user-earnings principal uint)

(define-read-only (get-bio-data-metadata (data-id uint))
    (map-get? bio-data-metadata data-id)
)

(define-read-only (get-research-stake (researcher principal))
    (map-get? research-stakes researcher)
)

(define-read-only (get-proposal (proposal-id uint))
    (map-get? proposals proposal-id)
)

(define-read-only (get-data-license (data-id uint) (researcher principal))
    (map-get? data-licenses {data-id: data-id, researcher: researcher})
)

(define-read-only (get-user-earnings (user principal))
    (default-to u0 (map-get? user-earnings user))
)

(define-read-only (get-next-bio-data-id)
    (var-get next-bio-data-id)
)

(define-read-only (get-next-proposal-id)
    (var-get next-proposal-id)
)

(define-read-only (get-min-stake-amount)
    (var-get min-stake-amount)
)

(define-public (mint-bio-data (data-hash (buff 32)) (price uint))
    (let ((data-id (var-get next-bio-data-id)))
        (try! (nft-mint? bio-data data-id tx-sender))
        (map-set bio-data-metadata data-id {
            owner: tx-sender,
            data-hash: data-hash,
            price: price,
            available: true,
            created-at: stacks-block-height
        })
        (var-set next-bio-data-id (+ data-id u1))
        (ok data-id)
    )
)

(define-public (set-data-availability (data-id uint) (available bool))
    (let ((metadata (unwrap! (map-get? bio-data-metadata data-id) err-not-found)))
        (asserts! (is-eq (get owner metadata) tx-sender) err-unauthorized)
        (map-set bio-data-metadata data-id (merge metadata {available: available}))
        (ok true)
    )
)

(define-public (update-data-price (data-id uint) (new-price uint))
    (let ((metadata (unwrap! (map-get? bio-data-metadata data-id) err-not-found)))
        (asserts! (is-eq (get owner metadata) tx-sender) err-unauthorized)
        (map-set bio-data-metadata data-id (merge metadata {price: new-price}))
        (ok true)
    )
)

(define-public (stake-tokens (amount uint))
    (let ((current-stake (default-to {amount: u0, locked-until: u0} (map-get? research-stakes tx-sender))))
        (asserts! (>= amount (var-get min-stake-amount)) err-insufficient-stake)
        (try! (ft-transfer? gene-token amount tx-sender (as-contract tx-sender)))
        (map-set research-stakes tx-sender {
            amount: (+ (get amount current-stake) amount),
            locked-until: (+ stacks-block-height u1440)
        })
        (ok true)
    )
)

(define-public (unstake-tokens (amount uint))
    (let ((stake-info (unwrap! (map-get? research-stakes tx-sender) err-not-found)))
        (asserts! (>= stacks-block-height (get locked-until stake-info)) err-unauthorized)
        (asserts! (>= (get amount stake-info) amount) err-insufficient-balance)
        (try! (as-contract (ft-transfer? gene-token amount tx-sender tx-sender)))
        (map-set research-stakes tx-sender {
            amount: (- (get amount stake-info) amount),
            locked-until: (get locked-until stake-info)
        })
        (ok true)
    )
)

(define-public (create-access-proposal (data-ids (list 10 uint)) (total-stake uint))
    (let ((proposal-id (var-get next-proposal-id))
          (stake-info (unwrap! (map-get? research-stakes tx-sender) err-not-found)))
        (asserts! (>= (get amount stake-info) total-stake) err-insufficient-stake)
        (asserts! (> (len data-ids) u0) err-invalid-proposal)
        (map-set proposals proposal-id {
            proposer: tx-sender,
            target-data-ids: data-ids,
            stake-amount: total-stake,
            votes-for: u0,
            votes-against: u0,
            created-at: stacks-block-height,
            expires-at: (+ stacks-block-height (var-get proposal-duration)),
            executed: false
        })
        (var-set next-proposal-id (+ proposal-id u1))
        (ok proposal-id)
    )
)

(define-public (vote-on-proposal (proposal-id uint) (vote-for bool))
    (let ((proposal (unwrap! (map-get? proposals proposal-id) err-not-found))
          (vote-key {proposal-id: proposal-id, voter: tx-sender}))
        (asserts! (< stacks-block-height (get expires-at proposal)) err-proposal-expired)
        (asserts! (is-none (map-get? proposal-votes vote-key)) err-already-voted)
        (map-set proposal-votes vote-key true)
        (if vote-for
            (map-set proposals proposal-id (merge proposal {votes-for: (+ (get votes-for proposal) u1)}))
            (map-set proposals proposal-id (merge proposal {votes-against: (+ (get votes-against proposal) u1)}))
        )
        (ok true)
    )
)

(define-public (execute-proposal (proposal-id uint))
    (let ((proposal (unwrap! (map-get? proposals proposal-id) err-not-found)))
        (asserts! (>= stacks-block-height (get expires-at proposal)) err-proposal-expired)
        (asserts! (not (get executed proposal)) err-already-exists)
        (asserts! (> (get votes-for proposal) (get votes-against proposal)) err-unauthorized)
        (map-set proposals proposal-id (merge proposal {executed: true}))
        (unwrap-panic (grant-data-access (get proposer proposal) (get target-data-ids proposal)))
        (ok true)
    )
)

(define-private (grant-data-access (researcher principal) (data-ids (list 10 uint)))
    (begin
        (fold grant-access-to-data data-ids researcher)
        (ok true)
    )
)

(define-private (grant-access-to-data (data-id uint) (researcher principal))
    (let ((metadata (map-get? bio-data-metadata data-id)))
        (match metadata
            data-info
            (if (get available data-info)
                (begin
                    (map-set data-licenses {data-id: data-id, researcher: researcher} {
                        expires-at: (+ stacks-block-height u8640),
                        price-paid: (get price data-info)
                    })
                    (map-set user-earnings (get owner data-info) 
                        (+ (get-user-earnings (get owner data-info)) (get price data-info)))
                    researcher)
                researcher)
            researcher)
    )
)

(define-public (mint-gene-tokens (amount uint))
    (if (is-eq tx-sender contract-owner)
        (ft-mint? gene-token amount tx-sender)
        err-owner-only
    )
)

(define-public (set-min-stake-amount (amount uint))
    (if (is-eq tx-sender contract-owner)
        (begin
            (var-set min-stake-amount amount)
            (ok true))
        err-owner-only
    )
)

(define-public (withdraw-earnings)
    (let ((earnings (get-user-earnings tx-sender)))
        (asserts! (> earnings u0) err-insufficient-balance)
        (try! (as-contract (ft-transfer? gene-token earnings tx-sender tx-sender)))
        (map-set user-earnings tx-sender u0)
        (ok earnings)
    )
)