-- =============================================================================
-- STEP — DELIVERY OUTCOME (pre-eligibility exploration)
-- =============================================================================
-- Question this answers:
--   "Of the 30 raw scoped attempts, how many actually reached the customer,
--    independent of whether the owning campaign is eligible for reporting?"
--
-- This checkpoint deliberately does NOT join to `campaign` yet — it looks at
-- `delivery_status` in isolation first, before campaign eligibility is folded
-- in (that happens in 03_campaign_eligibility.sql). Keeping the two filters
-- separate at this stage makes it possible to tell, later, which chunk of the
-- 30 → 22 gap came from "never delivered" versus "delivered but ineligible".
--
-- Expected result at this stage: 26 delivered / 4 failed, out of 30 scoped
-- attempts. Note this 26 is NOT the same 26 as after the eligibility filter
-- in 03 — it's a coincidental match in this dataset (both drops happen to be
-- exactly 4 rows), not the same 4 rows. See 03 for why.
-- =============================================================================

-- --------------------------------------------------------------------
-- 2a. Attempt-level delivery outcomes
--     Row-by-row view of every scoped send attempt with a human-readable
--     delivery outcome, ordered chronologically — useful for spotting
--     patterns like a customer failing repeatedly before finally succeeding.
-- --------------------------------------------------------------------
SELECT
    communication_id,
    customer_id,
    sent_time,
    delivery_status,
    CASE WHEN delivery_status = 900 THEN 'Delivered' ELSE 'Failed' END AS delivery_outcome
FROM communication_log
WHERE merchant_id = 501
  AND communication_type = '2'
  AND sent_time >= '2026-10-01'
  AND sent_time <  '2026-11-01'
ORDER BY sent_time, communication_id, customer_id;

-- --------------------------------------------------------------------
-- 2b. Delivery outcome summary
--     Aggregates the same data by outcome to confirm the split at a glance.
-- --------------------------------------------------------------------
SELECT
    delivery_status,
    CASE WHEN delivery_status = 900 THEN 'Delivered' ELSE 'Failed' END AS delivery_outcome,
    COUNT(*)                       AS attempt_count,
    COUNT(DISTINCT customer_id)    AS distinct_customer_count
FROM communication_log
WHERE merchant_id = 501
  AND communication_type = '2'
  AND sent_time >= '2026-10-01'
  AND sent_time <  '2026-11-01'
GROUP BY delivery_status;

-- --------------------------------------------------------------------
-- 2c. Total: scoped vs. delivered vs. failed
--     The single-row rollup of the above — this is the number carried
--     forward into the running bridge total once eligibility is also
--     applied in 03_campaign_eligibility.sql.
-- --------------------------------------------------------------------
SELECT
    COUNT(*)                                                       AS scoped_attempts,        -- 30
    SUM(CASE WHEN delivery_status = 900  THEN 1 ELSE 0 END)         AS delivered_attempts,      -- 26
    SUM(CASE WHEN delivery_status = 1100 THEN 1 ELSE 0 END)         AS failed_attempts          -- 4
FROM communication_log
WHERE merchant_id = 501
  AND communication_type = '2'
  AND sent_time >= '2026-10-01'
  AND sent_time <  '2026-11-01';
