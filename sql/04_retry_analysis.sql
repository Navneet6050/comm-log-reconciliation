-- =============================================================================
-- STEP 3 (Bridge Iteration 3) — RETRY-CHAIN DEDUPLICATION
-- =============================================================================
-- Question this answers:
--   "Within the eligible, delivered attempts, does any customer have more
--    than one successful delivery inside the same retry chain? If so, a flat
--    COUNT(*) would double-count them — target_base must count them once."
--
-- A retry chain is a campaign plus every campaign that (transitively) points
-- back at it via `parent_id`. `campaign_tree` below walks that hierarchy with
-- a recursive CTE to resolve every campaign to its `chain_root_id` — the
-- top-level campaign at the start of its chain. `chain_size` then tells us
-- how many campaigns share that root: chain_size = 1 means "no retries at
-- all" (a standalone campaign, handled instead in 05_standalone_analysis.sql);
-- chain_size > 1 means a genuine retry chain, which is what this file audits.
--
-- Expected result: zero customers have more than one successful delivery
-- within a chain in this dataset — so retry-chain dedup contributes 0 net
-- adjustment here, even though the logic is fully exercised. See
-- reports/submission.md §4 for why this is treated as *verified*, not assumed.
-- =============================================================================

-- --------------------------------------------------------------------
-- 4a. Resolve every campaign to its retry-chain root, and classify each
--     chain as Standalone (chain_size = 1) or Retry Chain (chain_size > 1).
--     Restricted to eligible campaigns only (Step 1's filter still applies).
-- --------------------------------------------------------------------
WITH RECURSIVE
campaign_tree AS (
    -- Base case: campaigns with no parent are the root of their own chain.
    SELECT
        id, parent_id, id AS chain_root_id,
        name, creation_status, processing_status
    FROM campaign
    WHERE parent_id IS NULL

    UNION ALL

    -- Recursive step: walk down every retry, inheriting its ancestor's root.
    SELECT
        c.id, c.parent_id, ct.chain_root_id,
        c.name, c.creation_status, c.processing_status
    FROM campaign c
    JOIN campaign_tree ct ON c.parent_id = ct.id
),
chain_sizes AS (
    SELECT chain_root_id, COUNT(*) AS chain_size
    FROM campaign_tree
    GROUP BY chain_root_id
),
eligible_campaigns AS (
    SELECT ct.*, cs.chain_size
    FROM campaign_tree ct
    JOIN chain_sizes cs ON ct.chain_root_id = cs.chain_root_id
    WHERE ct.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
      AND ct.processing_status = 'processed'
)
SELECT
    ec.id AS campaign_id,
    ec.parent_id,
    ec.chain_root_id,
    ec.name AS campaign_name,
    ec.creation_status,
    ec.processing_status,
    CASE WHEN ec.chain_size = 1 THEN 'Standalone' ELSE 'Retry Chain' END AS chain_type
FROM eligible_campaigns ec
ORDER BY ec.chain_root_id, ec.id;

-- --------------------------------------------------------------------
-- 4b. Per-customer retry audit (retry chains only, chain_size > 1)
--     Shows each customer's full delivery path across a chain (e.g.
--     "9001 (1100) -> 9002 (900)") so a failed-then-succeeded pattern is
--     visible directly, alongside whether they were ever successfully
--     delivered anywhere in the chain.
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
eligible_retry_chain_campaigns AS (
    -- Only campaigns that are (a) eligible and (b) part of a multi-campaign chain
    SELECT ct.id, ct.chain_root_id
    FROM campaign_tree ct
    JOIN campaign c ON ct.id = c.id
    JOIN chain_sizes cs ON ct.chain_root_id = cs.chain_root_id
    WHERE c.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
      AND c.processing_status = 'processed'
      AND cs.chain_size > 1
),
scoped_logs AS (
    SELECT communication_id, customer_id, sent_time, delivery_status
    FROM communication_log
    WHERE merchant_id = 501
      AND communication_type = '2'
      AND sent_time >= '2026-10-01'
      AND sent_time <  '2026-11-01'
)
SELECT
    r.chain_root_id,
    s.customer_id,
    GROUP_CONCAT(r.id || ' (' || s.delivery_status || ')', ' -> ' ORDER BY s.sent_time) AS delivery_path_across_chain,
    SUM(CASE WHEN s.delivery_status = 900 THEN 1 ELSE 0 END)       AS successful_deliveries_in_chain,
    -- Flag: was this customer ever successfully reached anywhere in the chain?
    CASE WHEN SUM(CASE WHEN s.delivery_status = 900 THEN 1 ELSE 0 END) > 0 THEN 1 ELSE 0 END AS reached_in_chain
FROM scoped_logs s
JOIN eligible_retry_chain_campaigns r ON s.communication_id = r.id
GROUP BY r.chain_root_id, s.customer_id
ORDER BY r.chain_root_id, s.customer_id;

-- --------------------------------------------------------------------
-- 4c. Retry-chain contribution to target_base
--     Distinct (chain_root_id, customer_id) pairs among successful deliveries
--     — this is the "count each customer once per chain" rule, isolated from
--     the standalone-campaign logic in 05_standalone_analysis.sql.
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
eligible_retry_chain_campaigns AS (
    SELECT ct.id, ct.chain_root_id
    FROM campaign_tree ct
    JOIN campaign c ON ct.id = c.id
    JOIN chain_sizes cs ON ct.chain_root_id = cs.chain_root_id
    WHERE c.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
      AND c.processing_status = 'processed'
      AND cs.chain_size > 1
),
scoped_logs AS (
    SELECT communication_id, customer_id, delivery_status
    FROM communication_log
    WHERE merchant_id = 501
      AND communication_type = '2'
      AND sent_time >= '2026-10-01'
      AND sent_time <  '2026-11-01'
)
SELECT
    COUNT(DISTINCT r.chain_root_id || '-' || s.customer_id) AS retry_chain_contribution
FROM scoped_logs s
JOIN eligible_retry_chain_campaigns r ON s.communication_id = r.id
WHERE s.delivery_status = 900;
