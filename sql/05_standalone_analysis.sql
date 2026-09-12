-- Investigation Checkpoint 6.1: Standalone Send-Event Audit
WITH RECURSIVE
campaign_hierarchy AS (
    SELECT id, parent_id, id AS root_id, name, creation_status, processing_status FROM campaign WHERE parent_id IS NULL
    UNION ALL
    SELECT c.id, c.parent_id, ch.root_id, c.name, c.creation_status, c.processing_status FROM campaign c JOIN campaign_hierarchy ch ON c.parent_id = ch.id
),
family_counts AS (
    SELECT root_id, COUNT(*) as family_size
    FROM campaign_hierarchy
    GROUP BY root_id
),
standalone_campaigns AS (
    SELECT ch.id, ch.name as campaign_name, ch.creation_status, ch.processing_status
    FROM campaign_hierarchy ch
    JOIN family_counts f ON ch.root_id = f.root_id
    WHERE f.family_size = 1
)
SELECT
    l.communication_id,
    c.campaign_name,
    l.customer_id,
    l.sent_time,
    l.delivery_status,
    CASE WHEN c.creation_status IN ('approved','aborted','resumed','stopped')
          AND c.processing_status = 'processed' THEN 1 ELSE 0 END as is_eligible,
    CASE WHEN c.creation_status IN ('approved','aborted','resumed','stopped')
          AND c.processing_status = 'processed'
          AND l.delivery_status = 900 THEN 1 ELSE 0 END as is_successful_standalone_event
FROM communication_log l
JOIN standalone_campaigns c ON l.communication_id = c.id
WHERE l.merchant_id = 501
  AND l.communication_type = '2'
  AND l.sent_time >= '2026-10-01'
  AND l.sent_time < '2026-11-01'
ORDER BY l.sent_time, l.communication_id, l.customer_id;

-- Investigation Checkpoint 6.2: Focused Audit for Campaign 9101 (C20 multiple sends)
-- This query explicitly demonstrates that standalone campaigns do NOT deduplicate customers.
-- Customer C20 has two separate successful send events, and both count for target_base.
SELECT
    l.communication_id,
    l.customer_id,
    l.sent_time,
    l.delivery_status
FROM communication_log l
WHERE l.merchant_id = 501
  AND l.communication_id = 9101
  AND l.delivery_status = 900
ORDER BY l.sent_time;

-- Investigation Checkpoint 6.3: Standalone Events vs Distinct Customers
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
eligible_standalone_campaigns AS (
    SELECT ch.id
    FROM campaign_hierarchy ch
    JOIN campaign c ON ch.id = c.id
    JOIN family_counts f ON ch.root_id = f.root_id
    WHERE c.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
      AND c.processing_status = 'processed'
      AND f.family_size = 1
),
scoped_logs AS (
    SELECT l.communication_id, l.customer_id
    FROM communication_log l
    WHERE l.merchant_id = 501
      AND l.communication_type = '2'
      AND l.sent_time >= '2026-10-01'
      AND l.sent_time < '2026-11-01'
      AND l.delivery_status = 900
)
SELECT
    s.communication_id,
    COUNT(s.customer_id) as successful_standalone_events,
    COUNT(DISTINCT s.customer_id) as distinct_successful_customers
FROM scoped_logs s
JOIN eligible_standalone_campaigns c ON s.communication_id = c.id
GROUP BY s.communication_id;

-- Investigation Checkpoint 6.4: Standalone Contribution to Target Base
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
eligible_standalone_campaigns AS (
    SELECT ch.id
    FROM campaign_hierarchy ch
    JOIN campaign c ON ch.id = c.id
    JOIN family_counts f ON ch.root_id = f.root_id
    WHERE c.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
      AND c.processing_status = 'processed'
      AND f.family_size = 1
),
scoped_logs AS (
    SELECT l.communication_id, l.customer_id
    FROM communication_log l
    WHERE l.merchant_id = 501
      AND l.communication_type = '2'
      AND l.sent_time >= '2026-10-01'
      AND l.sent_time < '2026-11-01'
      AND l.delivery_status = 900
)
SELECT
    COUNT(s.customer_id) as standalone_contribution
FROM scoped_logs s
JOIN eligible_standalone_campaigns c ON s.communication_id = c.id;
