-- Investigation Checkpoint 3: Failed vs Delivered attempts
SELECT 
    SUM(CASE WHEN delivery_status != 900 THEN 1 ELSE 0 END) as failed_attempts,
    SUM(CASE WHEN delivery_status = 900 THEN 1 ELSE 0 END) as delivered_attempts
FROM communication_log
WHERE merchant_id = 501
  AND communication_type = '2'
  AND sent_time >= '2026-10-01' 
  AND sent_time < '2026-11-01';
