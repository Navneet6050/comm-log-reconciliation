-- =============================================================================
-- STEP 4 (Bridge Iteration 4) — STANDALONE CAMPAIGN PRESERVATION
-- =============================================================================
-- Question this answers:
--   "For campaigns with no retry chain at all, does a customer who receives
--    more than one successful send get wrongly deduplicated the way a retry
--    chain would? It shouldn't — every send under a standalone campaign is
--    its own independent event."
--
-- A standalone campaign is one with chain_size = 1 in the campaign_tree
-- classification from 04_retry_analysis.sql: no parent, and no retry points
-- back at it. Campaign 9101 is the standalone case in this dataset, and
-- customer C20 is deliberately targeted and delivered twice under it —
-- structurally similar to a retry's "same customer, multiple rows" shape,
-- but semantically the opposite: both events must be preserved and counted.
--
-- Expected result: 9101 contributes 7 successful send *events* to
-- target_base (not 6 distinct customers) — C20's two sends both count.
-- =============================================================================

-- --------------------------------------------------------------------
-- 5a. Standalone send-event audit
--     Row-by-row view of every attempt under a standalone campaign, tagged
--     with eligibility and whether it's a qualifying (eligible + delivered)
--     standalone event.
-- --------------------------------------------------------------------
WITH RECURSIVE
campaign_tree AS (
    SELECT id, parent_id, id AS chain_root_id, name, creation_status, processing_status
    FROM campaign WHERE parent_id IS NULL
    UNION ALL
    SELECT c.id, c.parent_id, ct.chain_root_id, c.name, c.creation_status, c.processing_status
    FROM campaign c JOIN campaign_tree ct ON c.parent_id = ct.id
),
chain_sizes AS (
    SELECT chain_root_id, COUNT(*) AS chain_size FROM campaign_tree GROUP BY chain_root_id
),
standalone_campaigns AS (
    -- chain_size = 1 => no parent, no retries: a standalone communication
    SELECT ct.id, ct.name AS campaign_name, ct.creation_status, ct.processing_status
    FROM campaign_tree ct
    JOIN chain_sizes cs ON ct.chain_root_id = cs.chain_root_id
    WHERE cs.chain_size = 1
)
SELECT
    l.communication_id,
    sc.campaign_name,
    l.customer_id,
    l.sent_time,
    l.delivery_status,
    CASE WHEN sc.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
          AND sc.processing_status = 'processed' THEN 1 ELSE 0 END AS is_eligible,
    CASE WHEN sc.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
          AND sc.processing_status = 'processed'
          AND l.delivery_status = 900 THEN 1 ELSE 0 END           AS is_qualifying_standalone_event
FROM communication_log l
JOIN standalone_campaigns sc ON l.communication_id = sc.id
WHERE l.merchant_id = 501
  AND l.communication_type = '2'
  AND l.sent_time >= '2026-10-01'
  AND l.sent_time <  '2026-11-01'
ORDER BY l.sent_time, l.communication_id, l.customer_id;

-- --------------------------------------------------------------------
-- 5b. Focused audit — campaign 9101 (the C20 repeat-customer case)
--     Isolates the exact rows that prove standalone campaigns do NOT
--     deduplicate customers: C20 has two separate successful sends here,
--     and both must count toward target_base.
-- --------------------------------------------------------------------
SELECT
    communication_id,
    customer_id,
    sent_time,
    delivery_status
FROM communication_log
WHERE merchant_id = 501
  AND communication_id = 9101
  AND delivery_status = 900
ORDER BY sent_time;

-- --------------------------------------------------------------------
-- 5c. Events vs. distinct customers, per standalone campaign
--     Side-by-side comparison to make the non-dedup rule visually obvious:
--     campaign 9101 shows successful_events > distinct_customers (7 vs 6)
--     precisely because of C20's repeat — and events, not distinct
--     customers, is the number that feeds target_base for standalone
--     campaigns.
-- --------------------------------------------------------------------
WITH RECURSIVE
campaign_tree AS (
    SELECT id, parent_id, id AS chain_root_id FROM campaign WHERE parent_id IS NULL
    UNION ALL
    SELECT c.id, c.parent_id, ct.chain_root_id
    FROM campaign c JOIN campaign_tree ct ON c.parent_id = ct.id
),
chain_sizes AS (
    SELECT chain_root_id, COUNT(*) AS chain_size FROM campaign_tree GROUP BY chain_root_id
),
eligible_standalone_campaigns AS (
    SELECT ct.id
    FROM campaign_tree ct
    JOIN campaign c ON ct.id = c.id
    JOIN chain_sizes cs ON ct.chain_root_id = cs.chain_root_id
    WHERE c.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
      AND c.processing_status = 'processed'
      AND cs.chain_size = 1
),
scoped_delivered_logs AS (
    SELECT communication_id, customer_id
    FROM communication_log
    WHERE merchant_id = 501
      AND communication_type = '2'
      AND sent_time >= '2026-10-01'
      AND sent_time <  '2026-11-01'
      AND delivery_status = 900
)
SELECT
    s.communication_id,
    COUNT(s.customer_id)               AS successful_events,
    COUNT(DISTINCT s.customer_id)      AS distinct_customers
FROM scoped_delivered_logs s
JOIN eligible_standalone_campaigns esc ON s.communication_id = esc.id
GROUP BY s.communication_id;

-- --------------------------------------------------------------------
-- 5d. Standalone contribution to target_base
--     The number carried into the final bridge total: total successful
--     *events* (not deduplicated) across all eligible standalone campaigns.
-- --------------------------------------------------------------------
WITH RECURSIVE
campaign_tree AS (
    SELECT id, parent_id, id AS chain_root_id FROM campaign WHERE parent_id IS NULL
    UNION ALL
    SELECT c.id, c.parent_id, ct.chain_root_id
    FROM campaign c JOIN campaign_tree ct ON c.parent_id = ct.id
),
chain_sizes AS (
    SELECT chain_root_id, COUNT(*) AS chain_size FROM campaign_tree GROUP BY chain_root_id
),
eligible_standalone_campaigns AS (
    SELECT ct.id
    FROM campaign_tree ct
    JOIN campaign c ON ct.id = c.id
    JOIN chain_sizes cs ON ct.chain_root_id = cs.chain_root_id
    WHERE c.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
      AND c.processing_status = 'processed'
      AND cs.chain_size = 1
),
scoped_delivered_logs AS (
    SELECT communication_id, customer_id
    FROM communication_log
    WHERE merchant_id = 501
      AND communication_type = '2'
      AND sent_time >= '2026-10-01'
      AND sent_time <  '2026-11-01'
      AND delivery_status = 900
)
SELECT
    COUNT(s.customer_id) AS standalone_contribution   -- 7
FROM scoped_delivered_logs s
JOIN eligible_standalone_campaigns esc ON s.communication_id = esc.id;
