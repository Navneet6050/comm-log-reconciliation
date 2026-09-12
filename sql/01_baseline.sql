-- =============================================================================
-- STEP 0 (Bridge Iteration 0) — NAIVE BASELINE
-- =============================================================================
-- Question this answers:
--   "Before applying any business logic, what does a straightforward count of
--    the send log say the October 2026 volume was for merchant 501?"
--
-- This is the deliberately naive starting point of the reconciliation bridge.
-- It scopes only by merchant / communication type / month and treats every
-- row in `communication_log` as a valid, countable send — ignoring campaign
-- eligibility and delivery outcome entirely. Its purpose is to frame the gap
-- that the remaining scripts (02–05) explain, not to be a usable metric.
--
-- Expected result: 30 raw attempts.
-- =============================================================================

-- --------------------------------------------------------------------
-- 1a. Per-campaign breakdown
--     Shows how the 30 raw attempts are distributed across all 7 campaigns
--     in this dataset, alongside each campaign's lifecycle status — this is
--     the view that first makes campaign 9004's odd status combination
--     visible (see 03_campaign_eligibility.sql).
-- --------------------------------------------------------------------
WITH scoped_logs AS (
    SELECT *
    FROM communication_log
    WHERE merchant_id = 501
      AND communication_type = '2'
      AND sent_time >= '2026-10-01'
      AND sent_time <  '2026-11-01'
)
SELECT
    c.id                                                                AS campaign_id,
    c.name                                                              AS campaign_name,
    c.creation_status,
    c.processing_status,
    COUNT(l.id)                                                         AS raw_attempt_count,
    COUNT(DISTINCT l.customer_id)                                       AS distinct_customer_count,
    COALESCE(SUM(CASE WHEN l.delivery_status = 900  THEN 1 END), 0)     AS delivered_attempt_count,
    COALESCE(SUM(CASE WHEN l.delivery_status = 1100 THEN 1 END), 0)     AS failed_attempt_count
FROM campaign c
LEFT JOIN scoped_logs l ON c.id = l.communication_id
GROUP BY c.id, c.name, c.creation_status, c.processing_status
ORDER BY c.id;

-- --------------------------------------------------------------------
-- 1b. Naive scoped total
--     The single number this file exists to produce: the raw baseline
--     before any eligibility or delivery-outcome filtering is applied.
-- --------------------------------------------------------------------
SELECT
    COUNT(*)                       AS naive_scoped_attempts,      -- expected: 30
    COUNT(DISTINCT customer_id)    AS naive_distinct_customers
FROM communication_log
WHERE merchant_id = 501
  AND communication_type = '2'
  AND sent_time >= '2026-10-01'
  AND sent_time <  '2026-11-01';
