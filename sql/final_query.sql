-- Final target_base calculation for merchant 501, October 2026, type 2

WITH RECURSIVE campaign_tree AS (
    -- Base cases: Campaigns that have no parent are roots of their own tree.
    SELECT id, parent_id, id as root_id, name, creation_status, processing_status
    FROM campaign
    WHERE parent_id IS NULL
    
    UNION ALL
    
    -- Recursive step: Campaigns that have a parent
    SELECT c.id, c.parent_id, t.root_id, c.name, c.creation_status, c.processing_status
    FROM campaign c
    JOIN campaign_tree t ON c.parent_id = t.id
),
-- Count children to identify standalones (root_id where total_in_chain = 1)
chain_sizes AS (
    SELECT root_id, COUNT(*) as chain_size
    FROM campaign_tree
    GROUP BY root_id
),
campaign_classification AS (
    SELECT t.*, 
           CASE WHEN s.chain_size = 1 THEN 1 ELSE 0 END as is_standalone
    FROM campaign_tree t
    JOIN chain_sizes s ON t.root_id = s.root_id
),
scoped_logs AS (
    SELECT *
    FROM communication_log
    WHERE merchant_id = 501
      AND communication_type = '2'
      AND sent_time >= '2026-10-01' 
      AND sent_time < '2026-11-01'
),
eligible_logs AS (
    SELECT l.*, c.root_id, c.is_standalone
    FROM scoped_logs l
    JOIN campaign_classification c ON l.communication_id = c.id
    WHERE l.delivery_status = 900
      AND c.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
      AND c.processing_status = 'processed'
)
SELECT 
    SUM(CASE WHEN is_standalone = 1 THEN 1 ELSE 0 END) + 
    COUNT(DISTINCT CASE WHEN is_standalone = 0 THEN root_id || '_' || customer_id END) as target_base
FROM eligible_logs;
