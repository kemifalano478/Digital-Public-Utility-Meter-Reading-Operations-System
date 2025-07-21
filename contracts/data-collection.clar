;; Data Collection Contract
;; Records water, gas, and electric consumption readings

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-INVALID-INPUT (err u201))
(define-constant ERR-METER-NOT-FOUND (err u202))
(define-constant ERR-READING-EXISTS (err u203))
(define-constant ERR-INVALID-READING (err u204))

;; Data Variables
(define-data-var next-meter-id uint u1)
(define-data-var next-reading-id uint u1)

;; Data Maps
(define-map meters
  { meter-id: uint }
  {
    meter-number: (string-ascii 50),
    meter-type: (string-ascii 20),
    location: (string-ascii 200),
    customer-id: (string-ascii 50),
    installation-date: uint,
    last-reading: (optional uint),
    status: (string-ascii 20)
  }
)

(define-map readings
  { reading-id: uint }
  {
    meter-id: uint,
    reading-value: uint,
    reading-date: uint,
    reader-id: uint,
    reading-type: (string-ascii 20),
    notes: (optional (string-ascii 500)),
    validated: bool,
    anomaly-detected: bool
  }
)

(define-map meter-history
  { meter-id: uint, reading-date: uint }
  {
    reading-id: uint,
    previous-reading: (optional uint),
    consumption: (optional uint),
    days-elapsed: (optional uint)
  }
)

;; Authorization Maps
(define-map authorized-admins principal bool)
(define-map authorized-readers principal bool)
(define-map reader-assignments uint principal)

;; Initialize contract
(map-set authorized-admins CONTRACT-OWNER true)

;; Admin Functions
(define-public (add-admin (admin principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (ok (map-set authorized-admins admin true))
  )
)

(define-public (add-reader (reader principal) (reader-id uint))
  (begin
    (asserts! (default-to false (map-get? authorized-admins tx-sender)) ERR-NOT-AUTHORIZED)
    (map-set authorized-readers reader true)
    (ok (map-set reader-assignments reader-id reader))
  )
)

;; Meter Management
(define-public (register-meter (meter-number (string-ascii 50)) (meter-type (string-ascii 20)) (location (string-ascii 200)) (customer-id (string-ascii 50)))
  (let
    (
      (meter-id (var-get next-meter-id))
    )
    (asserts! (default-to false (map-get? authorized-admins tx-sender)) ERR-NOT-AUTHORIZED)
    (asserts! (> (len meter-number) u0) ERR-INVALID-INPUT)
    (asserts! (or (is-eq meter-type "water") (or (is-eq meter-type "gas") (is-eq meter-type "electric"))) ERR-INVALID-INPUT)
    (asserts! (> (len location) u0) ERR-INVALID-INPUT)
    (asserts! (> (len customer-id) u0) ERR-INVALID-INPUT)

    (map-set meters
      { meter-id: meter-id }
      {
        meter-number: meter-number,
        meter-type: meter-type,
        location: location,
        customer-id: customer-id,
        installation-date: block-height,
        last-reading: none,
        status: "active"
      }
    )

    (var-set next-meter-id (+ meter-id u1))
    (ok meter-id)
  )
)

;; Reading Functions
(define-public (record-reading (meter-id uint) (reading-value uint) (reader-id uint) (reading-type (string-ascii 20)) (notes (optional (string-ascii 500))))
  (let
    (
      (reading-id (var-get next-reading-id))
      (meter-data (unwrap! (map-get? meters { meter-id: meter-id }) ERR-METER-NOT-FOUND))
      (reader-wallet (unwrap! (map-get? reader-assignments reader-id) ERR-NOT-AUTHORIZED))
    )
    (asserts! (is-eq tx-sender reader-wallet) ERR-NOT-AUTHORIZED)
    (asserts! (> reading-value u0) ERR-INVALID-INPUT)
    (asserts! (or (is-eq reading-type "actual") (or (is-eq reading-type "estimated") (is-eq reading-type "customer-read"))) ERR-INVALID-INPUT)

    ;; Validate reading against previous reading
    (let
      (
        (last-reading-value (get-last-reading-value meter-id))
        (is-valid-reading (or (is-none last-reading-value) (>= reading-value (unwrap-panic last-reading-value))))
        (anomaly-detected (and (is-some last-reading-value) (> reading-value (+ (unwrap-panic last-reading-value) u10000))))
      )
      (asserts! is-valid-reading ERR-INVALID-READING)

      ;; Create reading record
      (map-set readings
        { reading-id: reading-id }
        {
          meter-id: meter-id,
          reading-value: reading-value,
          reading-date: block-height,
          reader-id: reader-id,
          reading-type: reading-type,
          notes: notes,
          validated: (not anomaly-detected),
          anomaly-detected: anomaly-detected
        }
      )

      ;; Update meter last reading
      (map-set meters
        { meter-id: meter-id }
        (merge meter-data {
          last-reading: (some reading-value)
        })
      )

      ;; Create history record
      (let
        (
          (previous-reading last-reading-value)
          (consumption (if (is-some previous-reading) (some (- reading-value (unwrap-panic previous-reading))) none))
          (days-elapsed (if (is-some previous-reading) (some (calculate-days-elapsed meter-id)) none))
        )
        (map-set meter-history
          { meter-id: meter-id, reading-date: block-height }
          {
            reading-id: reading-id,
            previous-reading: previous-reading,
            consumption: consumption,
            days-elapsed: days-elapsed
          }
        )
      )

      (var-set next-reading-id (+ reading-id u1))
      (ok reading-id)
    )
  )
)

(define-public (validate-reading (reading-id uint))
  (let
    (
      (reading-data (unwrap! (map-get? readings { reading-id: reading-id }) ERR-READING-EXISTS))
    )
    (asserts! (default-to false (map-get? authorized-admins tx-sender)) ERR-NOT-AUTHORIZED)

    (map-set readings
      { reading-id: reading-id }
      (merge reading-data {
        validated: true,
        anomaly-detected: false
      })
    )

    (ok true)
  )
)

;; Helper Functions
(define-private (get-last-reading-value (meter-id uint))
  (let
    (
      (meter-data (map-get? meters { meter-id: meter-id }))
    )
    (if (is-some meter-data)
      (get last-reading (unwrap-panic meter-data))
      none
    )
  )
)

(define-private (calculate-days-elapsed (meter-id uint))
  ;; Simplified calculation - in real implementation would use proper date math
  u30
)

;; Read-only Functions
(define-read-only (get-meter (meter-id uint))
  (map-get? meters { meter-id: meter-id })
)

(define-read-only (get-reading (reading-id uint))
  (map-get? readings { reading-id: reading-id })
)

(define-read-only (get-meter-history (meter-id uint) (reading-date uint))
  (map-get? meter-history { meter-id: meter-id, reading-date: reading-date })
)

(define-read-only (is-authorized-admin (user principal))
  (default-to false (map-get? authorized-admins user))
)

(define-read-only (is-authorized-reader (user principal))
  (default-to false (map-get? authorized-readers user))
)

(define-read-only (get-reader-wallet (reader-id uint))
  (map-get? reader-assignments reader-id)
)
