-- =============================================================================
-- STEP 1 (Bridge Iteration 1) — CAMPAIGN ELIGIBILITY
-- =============================================================================
-- Question this answers:
--   "Do all campaigns behind the scoped attempts actually qualify for
--    Finance's reporting, or does communication_log contain sends from
--    campaigns that haven't been finalized yet?"
--
-- Eligibility rule (per the data dictionary):
--   creation_status  IN ('approved', 'aborted', 'resumed', 'stopped')   -- finalized
--   AND processing_status = 'processed'                                -- send pipeline done
--
-- A campaign can have communication_log rows — including delivered ones —
-- before it clears this gate, because the send pipeline and the approval
-- workflow are independent processes. Campaign 9004 in this dataset is
-- exactly that case: creation_status = 'approval_awaiting' with 4 delivered
-- rows already logged. Those 4 rows must be excluded from target_base
-- regardless of their delivery outcome.
--
-- Expected result: excluding 9004 drops the eligible-delivered total to 22.
-- =============================================================================

-- --------------------------------------------------------------------
-- 3a. Attempt-level eligibility audit
--     Tags every scoped attempt as Eligible/Ineligible and states why, so
--     the reasoning is visible per row rather than only in the aggregate.
-- --------------------------------------------------------------------
SELECT
    l.communication_id,
    c.name AS campaign_name,
    c.creation_status,
    c.processing_status,
    l.customer_id,
    l.sent_time,
    l.delivery_status,
    CASE
        WHEN c.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
         AND c.processing_status = 'processed' THEN 'Eligible'
        ELSE 'Ineligible'
    END AS eligibility_status,
    CASE
        WHEN c.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
         AND c.processing_status = 'processed' THEN 'Eligible campaign'
        WHEN c.processing_status != 'processed' THEN 'Send pipeline not finished'
        ELSE 'Creation/approval workflow not finalized'
    END AS ineligibility_reason
FROM communication_log l
JOIN campaign c ON l.communication_id = c.id
WHERE l.merchant_id = 501
  AND l.communication_type = '2'
  AND l.sent_time >= '2026-10-01'
  AND l.sent_time <  '2026-11-01'
ORDER BY l.sent_time, l.communication_id, l.customer_id;

-- --------------------------------------------------------------------
-- 3b. Campaign-level eligibility summary
--     One row per campaign — makes it immediately visible that 9004 is the
--     only ineligible campaign, and exactly how many of its delivered
--     attempts (4) are at stake.
-- --------------------------------------------------------------------
SELECT
    c.id AS campaign_id,
    c.name AS campaign_name,
    c.creation_status,
    c.processing_status,
    CASE
        WHEN c.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
         AND c.processing_status = 'processed' THEN 'Eligible'
        ELSE 'Ineligible'
    END AS eligibility_status,
    COUNT(l.id)                                                                AS scoped_attempts,
    SUM(CASE WHEN l.delivery_status = 900  THEN 1 ELSE 0 END)                  AS delivered_attempts,
    SUM(CASE WHEN l.delivery_status = 1100 THEN 1 ELSE 0 END)                  AS failed_attempts,
    SUM(CASE WHEN l.delivery_status = 900
              AND c.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
              AND c.processing_status = 'processed'
            THEN 1 ELSE 0 END)                                                 AS eligible_delivered_attempts
FROM communication_log l
JOIN campaign c ON l.communication_id = c.id
WHERE l.merchant_id = 501
  AND l.communication_type = '2'
  AND l.sent_time >= '2026-10-01'
  AND l.sent_time <  '2026-11-01'
GROUP BY c.id, c.name, c.creation_status, c.processing_status
ORDER BY c.id;

-- --------------------------------------------------------------------
-- 3c. Total: delivered attempts, split by eligibility
--     The number that matters for the bridge: how many delivered attempts
--     are lost purely because their campaign isn't finalized yet.
-- --------------------------------------------------------------------
WITH campaign_eligibility AS (
    SELECT
        l.id,
        l.delivery_status,
        CASE
            WHEN c.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
             AND c.processing_status = 'processed' THEN 1
            ELSE 0
        END AS is_eligible
    FROM communication_log l
    JOIN campaign c ON l.communication_id = c.id
    WHERE l.merchant_id = 501
      AND l.communication_type = '2'
      AND l.sent_time >= '2026-10-01'
      AND l.sent_time <  '2026-11-01'
)
SELECT
    SUM(CASE WHEN delivery_status = 900 THEN 1 ELSE 0 END)                    AS scoped_delivered_attempts,      -- 26
    SUM(CASE WHEN delivery_status = 900 AND is_eligible = 0 THEN 1 ELSE 0 END) AS ineligible_delivered_attempts, -- 4  (campaign 9004)
    SUM(CASE WHEN delivery_status = 900 AND is_eligible = 1 THEN 1 ELSE 0 END) AS eligible_delivered_attempts     -- 22
FROM campaign_eligibility;
