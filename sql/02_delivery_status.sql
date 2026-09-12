-- Investigation Checkpoint 3.1: Attempt-level delivery outcomes
SELECT 
    communication_id,
    customer_id,
    sent_time,
    delivery_status,
    CASE WHEN delivery_status = 900 THEN 'Delivered' ELSE 'Failed' END as readable_status
FROM communication_log
WHERE merchant_id = 501
  AND communication_type = '2'
  AND sent_time >= '2026-10-01'
  AND sent_time < '2026-11-01'
ORDER BY sent_time, communication_id, customer_id;

-- Investigation Checkpoint 3.2: Summary by delivery_status
SELECT
    delivery_status,
    CASE WHEN delivery_status = 900 THEN 'Delivered' ELSE 'Failed' END as readable_status,
    COUNT(*) as attempt_count,
    COUNT(DISTINCT customer_id) as distinct_customer_count
FROM communication_log
WHERE merchant_id = 501
  AND communication_type = '2'
  AND sent_time >= '2026-10-01'
  AND sent_time < '2026-11-01'
GROUP BY delivery_status;

-- Investigation Checkpoint 3.3: Total reconciliation query
SELECT
    COUNT(*) as scoped_attempts,
    SUM(CASE WHEN delivery_status = 900 THEN 1 ELSE 0 END) as delivered_attempts,
    SUM(CASE WHEN delivery_status = 1100 THEN 1 ELSE 0 END) as failed_attempts
FROM communication_log
WHERE merchant_id = 501
  AND communication_type = '2'
  AND sent_time >= '2026-10-01'
  AND sent_time < '2026-11-01';
