-- Investigation Checkpoint 1 & 2: Baseline scoped rows and distinct customers
SELECT 
    COUNT(*) as naive_scoped_count,
    COUNT(DISTINCT customer_id) as distinct_customer_count
FROM communication_log
WHERE merchant_id = 501
  AND communication_type = '2'
  AND sent_time >= '2026-10-01' 
  AND sent_time < '2026-11-01';
