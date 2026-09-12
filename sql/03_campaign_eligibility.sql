-- Investigation Checkpoint 4: Campaign eligibility
SELECT 
    c.id as campaign_id,
    c.creation_status,
    c.processing_status,
    COUNT(l.id) as scoped_attempts,
    SUM(CASE WHEN l.delivery_status = 900 THEN 1 ELSE 0 END) as scoped_delivered_attempts
FROM communication_log l
JOIN campaign c ON l.communication_id = c.id
WHERE l.merchant_id = 501
  AND l.communication_type = '2'
  AND l.sent_time >= '2026-10-01' 
  AND l.sent_time < '2026-11-01'
GROUP BY c.id;
