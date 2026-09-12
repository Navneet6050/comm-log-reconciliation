-- Investigation Checkpoint 5.1: Resolve Root Campaigns
-- Hierarchy/family classification
WITH RECURSIVE
campaign_hierarchy AS (
    SELECT
        id,
        parent_id,
        id AS root_id,
        name,
        creation_status,
        processing_status
    FROM campaign
    WHERE parent_id IS NULL

    UNION ALL

    SELECT
        c.id,
        c.parent_id,
        ch.root_id,
        c.name,
        c.creation_status,
        c.processing_status
    FROM campaign c
    JOIN campaign_hierarchy ch ON c.parent_id = ch.id
),
family_counts AS (
    SELECT root_id, COUNT(*) as family_size
    FROM campaign_hierarchy
    GROUP BY root_id
),
-- Eligibility filtering
eligible_campaigns AS (
    SELECT c.*, f.family_size
    FROM campaign_hierarchy c
    JOIN family_counts f ON c.root_id = f.root_id
    WHERE c.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
      AND c.processing_status = 'processed'
)
SELECT
    e.id as campaign_id,
    e.parent_id,
    e.root_id,
    e.name as campaign_name,
    e.creation_status,
    e.processing_status,
    CASE WHEN e.family_size = 1 THEN 'Standalone' ELSE 'Retry Family' END as family_type
FROM eligible_campaigns e
ORDER BY e.root_id, e.id;

-- Investigation Checkpoint 5.2: Customer-Level Retry Audit
-- Hierarchy/family classification
WITH RECURSIVE
campaign_hierarchy AS (
    SELECT id, parent_id, id AS root_id FROM campaign WHERE parent_id IS NULL
    UNION ALL
    SELECT c.id, c.parent_id, ch.root_id FROM campaign c JOIN campaign_hierarchy ch ON c.parent_id = ch.id
),
family_counts AS (
    SELECT root_id, COUNT(*) as family_size
    FROM campaign_hierarchy
    GROUP BY root_id
),
-- Eligibility filtering
eligible_retry_campaigns AS (
    SELECT ch.id, ch.root_id
    FROM campaign_hierarchy ch
    JOIN campaign c ON ch.id = c.id
    JOIN family_counts f ON ch.root_id = f.root_id
    WHERE c.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
      AND c.processing_status = 'processed'
      AND f.family_size > 1
),
-- Delivery filtering
scoped_logs AS (
    SELECT * FROM (
        SELECT
            l.communication_id,
            l.customer_id,
            l.sent_time,
            l.delivery_status
        FROM communication_log l
        WHERE l.merchant_id = 501
          AND l.communication_type = '2'
          AND l.sent_time >= '2026-10-01'
          AND l.sent_time < '2026-11-01'
        ORDER BY l.sent_time
    )
)
-- Customer deduplication
SELECT
    r.root_id,
    s.customer_id,
    GROUP_CONCAT(r.id || ' (' || s.delivery_status || ')', ' -> ') as campaign_delivery_path,
    SUM(CASE WHEN s.delivery_status = 900 THEN 1 ELSE 0 END) as successful_deliveries,
    CASE WHEN SUM(CASE WHEN s.delivery_status = 900 THEN 1 ELSE 0 END) > 0 THEN 1 ELSE 0 END as distinct_family_success
FROM scoped_logs s
JOIN eligible_retry_campaigns r ON s.communication_id = r.id
GROUP BY r.root_id, s.customer_id
ORDER BY r.root_id, s.customer_id;

-- Investigation Checkpoint 5.3: Final Retry-Family Contribution
-- Hierarchy/family classification
WITH RECURSIVE
campaign_hierarchy AS (
    SELECT id, parent_id, id AS root_id FROM campaign WHERE parent_id IS NULL
    UNION ALL
    SELECT c.id, c.parent_id, ch.root_id FROM campaign c JOIN campaign_hierarchy ch ON c.parent_id = ch.id
),
family_counts AS (
    SELECT root_id, COUNT(*) as family_size
    FROM campaign_hierarchy
    GROUP BY root_id
),
-- Eligibility filtering
eligible_retry_campaigns AS (
    SELECT ch.id, ch.root_id
    FROM campaign_hierarchy ch
    JOIN campaign c ON ch.id = c.id
    JOIN family_counts f ON ch.root_id = f.root_id
    WHERE c.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
      AND c.processing_status = 'processed'
      AND f.family_size > 1
),
-- Delivery filtering
scoped_logs AS (
    SELECT
        l.communication_id,
        l.customer_id,
        l.delivery_status
    FROM communication_log l
    WHERE l.merchant_id = 501
      AND l.communication_type = '2'
      AND l.sent_time >= '2026-10-01'
      AND l.sent_time < '2026-11-01'
)
-- Customer deduplication
SELECT
    COUNT(DISTINCT r.root_id || '-' || s.customer_id) as retry_chain_contribution
FROM scoped_logs s
JOIN eligible_retry_campaigns r ON s.communication_id = r.id
WHERE s.delivery_status = 900;
