-- Investigation Checkpoint 5 & 6: Retry chains vs Standalone
WITH RECURSIVE campaign_tree AS (
    SELECT id, parent_id, id as root_id, name
    FROM campaign
    WHERE parent_id IS NULL
    UNION ALL
    SELECT c.id, c.parent_id, t.root_id, c.name
    FROM campaign c
    JOIN campaign_tree t ON c.parent_id = t.id
),
chain_sizes AS (
    SELECT root_id, COUNT(*) as chain_size
    FROM campaign_tree
    GROUP BY root_id
)
SELECT 
    t.root_id,
    CASE WHEN s.chain_size = 1 THEN 'Standalone' ELSE 'Retry Chain' END as campaign_type,
    l.customer_id,
    GROUP_CONCAT(l.communication_id) as campaigns_encountered,
    GROUP_CONCAT(l.delivery_status) as delivery_statuses,
    SUM(CASE WHEN l.delivery_status = 900 THEN 1 ELSE 0 END) as successful_attempts
FROM communication_log l
JOIN campaign_tree t ON l.communication_id = t.id
JOIN chain_sizes s ON t.root_id = s.root_id
WHERE l.merchant_id = 501
  AND l.communication_type = '2'
  AND l.sent_time >= '2026-10-01' 
  AND l.sent_time < '2026-11-01'
GROUP BY t.root_id, l.customer_id, s.chain_size
ORDER BY t.root_id, l.customer_id;
