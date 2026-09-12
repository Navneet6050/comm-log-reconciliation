-- Investigation Checkpoint 1: Campaign-level naive baseline audit
WITH scoped_logs AS (
    SELECT *
    FROM communication_log
    WHERE merchant_id = 501
      AND communication_type = '2'
      AND sent_time >= '2026-10-01' 
      AND sent_time < '2026-11-01'
)
SELECT 
    c.id as communication_id,
    c.name as campaign_name,
    c.creation_status,
    c.processing_status,
    COUNT(l.id) as raw_attempt_count,
    COUNT(DISTINCT l.customer_id) as distinct_customer_count,
    COALESCE(SUM(CASE WHEN l.delivery_status = 900 THEN 1 ELSE 0 END), 0) as delivered_attempt_count,
    COALESCE(SUM(CASE WHEN l.delivery_status = 1100 THEN 1 ELSE 0 END), 0) as failed_attempt_count
FROM campaign c
LEFT JOIN scoped_logs l ON c.id = l.communication_id
GROUP BY c.id, c.name, c.creation_status, c.processing_status
ORDER BY c.id;

-- Investigation Checkpoint 2: Total Naive Baseline
SELECT 
    COUNT(*) as naive_scoped_attempts,
    COUNT(DISTINCT customer_id) as naive_distinct_customers
FROM communication_log
WHERE merchant_id = 501
  AND communication_type = '2'
  AND sent_time >= '2026-10-01' 
  AND sent_time < '2026-11-01';
