-- Investigation Checkpoint 4.1: Attempt-level campaign eligibility audit
-- The business rule for campaign eligibility is that it must be completely finalized:
-- creation_status IN ('approved', 'aborted', 'resumed', 'stopped') AND processing_status = 'processed'
SELECT
    l.communication_id,
    c.name as campaign_name,
    c.creation_status,
    c.processing_status,
    l.customer_id,
    l.sent_time,
    l.delivery_status,
    CASE
        WHEN c.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
         AND c.processing_status = 'processed' THEN 'Eligible'
        ELSE 'Ineligible'
    END as eligibility_status,
    CASE
        WHEN c.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
         AND c.processing_status = 'processed' THEN 'Eligible campaign'
        WHEN c.processing_status != 'processed' THEN 'Processing not processed'
        ELSE 'Campaign not finalized'
    END as inclusion_reason
FROM communication_log l
JOIN campaign c ON l.communication_id = c.id
WHERE l.merchant_id = 501
  AND l.communication_type = '2'
  AND l.sent_time >= '2026-10-01'
  AND l.sent_time < '2026-11-01'
ORDER BY l.sent_time, l.communication_id, l.customer_id;

-- Investigation Checkpoint 4.2: Campaign-level eligibility summary
SELECT
    c.id as communication_id,
    c.name as campaign_name,
    c.creation_status,
    c.processing_status,
    CASE
        WHEN c.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
         AND c.processing_status = 'processed' THEN 'Eligible'
        ELSE 'Ineligible'
    END as eligibility_status,
    COUNT(l.id) as scoped_attempts,
    SUM(CASE WHEN l.delivery_status = 900 THEN 1 ELSE 0 END) as delivered_attempts,
    SUM(CASE WHEN l.delivery_status = 1100 THEN 1 ELSE 0 END) as failed_attempts,
    SUM(CASE WHEN l.delivery_status = 900
              AND c.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
              AND c.processing_status = 'processed'
            THEN 1 ELSE 0 END) as eligible_delivered_attempts
FROM communication_log l
JOIN campaign c ON l.communication_id = c.id
WHERE l.merchant_id = 501
  AND l.communication_type = '2'
  AND l.sent_time >= '2026-10-01'
  AND l.sent_time < '2026-11-01'
GROUP BY c.id, c.name, c.creation_status, c.processing_status
ORDER BY c.id;

-- Investigation Checkpoint 4.3: Total eligibility reconciliation
WITH campaign_eligibility AS (
    SELECT
        l.id,
        l.delivery_status,
        CASE
            WHEN c.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
             AND c.processing_status = 'processed' THEN 1
            ELSE 0
        END as is_eligible
    FROM communication_log l
    JOIN campaign c ON l.communication_id = c.id
    WHERE l.merchant_id = 501
      AND l.communication_type = '2'
      AND l.sent_time >= '2026-10-01'
      AND l.sent_time < '2026-11-01'
)
SELECT
    SUM(CASE WHEN delivery_status = 900 THEN 1 ELSE 0 END) as scoped_delivered_attempts,
    SUM(CASE WHEN delivery_status = 900 AND is_eligible = 0 THEN 1 ELSE 0 END) as ineligible_delivered_attempts,
    SUM(CASE WHEN delivery_status = 900 AND is_eligible = 1 THEN 1 ELSE 0 END) as eligible_delivered_attempts
FROM campaign_eligibility;
