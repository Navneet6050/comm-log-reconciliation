# Comm-Log Send Reconciliation Walkthrough

This document outlines the chronological discovery and investigation process used to reconstruct the correct `target_base` calculation.

## 1. Naive Scoped Raw-Attempt Baseline
The investigation began by establishing a naive baseline. We scoped the `communication_log` purely on the top-level parameters: `merchant_id = 501`, `communication_type = 2`, and `sent_time` within October 2026. This yielded a baseline of **30 attempts**. This naive scope is intentionally incomplete; it merely frames the upper bound of the dataset because it blindly assumes all attempts are valid, entirely ignoring critical dimensions like delivery status and campaign finalization.

## 2. Campaign Eligibility
The second checkpoint examined campaign metadata. The assignment dictates a strict campaign eligibility rule: `creation_status IN ('approved', 'aborted', 'resumed', 'stopped') AND processing_status = 'processed'`.

What stood out here is that all 4 scoped attempts belonging to Campaign 9004 were successfully delivered (`delivery_status = 900`), yet the campaign itself possessed a `creation_status` of `approval_awaiting`. Because the campaign was not finalized, these 4 successfully delivered attempts must be completely excluded under the established eligibility rule. This bridges our naive baseline down: **30 -> 26**.

## 3. Delivery Outcomes
Next, we evaluated the physical delivery states of the remaining 26 attempts belonging to eligible campaigns. The logs clearly distinguish `delivery_status = 900` as a successful delivery and `delivery_status = 1100` as a failure. Filtering by these outcomes revealed exactly **4 failed attempts** among the eligible campaigns. These failures (such as customer C3 failing on both 9001 and 9002) must be excluded from the final billing aggregation, bringing our eligible successful attempts to **22**.

## 4. Retry Chains
The most complex architectural feature of the dataset is the retry-chain hierarchy, formed by linking campaigns recursively via the `parent_id` column. A fundamental business rule dictates that a customer reached multiple times within a single eligible retry chain must only be counted once.

We mapped the full parent-child hierarchy to resolve the "root" of every campaign. For example, Customer C2 failed on Campaign 9001 (`1100`) but succeeded on a later retry, Campaign 9002 (`900`). The semantic rule requires a customer to be counted only once if that customer has successful sends at multiple points within the same retry chain. However, after isolating the eligible delivered logs, we observed that **there are absolutely no successful customer overlaps within eligible retry chains in this dataset**. Therefore, applying the retry deduplication logic causes a numerical adjustment of **0**, yielding a retry contribution of **15**.

## 5. Standalone Campaigns
Standalone campaigns (campaigns with no retries) are treated fundamentally differently. Because there is no retry hierarchy to deduplicate, repeated successful sends to the same customer are treated as distinct send events.

This was validated through Campaign 9101, where customer C20 was successfully targeted twice. Under standalone semantics, both successful C20 events are preserved and counted. This resulted in a standalone contribution of **7**.

## 6. Final Reconciliation
Aggregating the two distinct paths finalizes the bridge:
- Eligible delivered attempts: **22**
- Retry chain contribution: **15**
- Standalone campaign contribution: **7**
- **Final target_base: 22**

## Key Data Surprises
Throughout the investigation, several deliberate data nuances confirmed the need for dynamic logic rather than hardcoding assumptions:
- **Logs for ineligible campaigns**: Communication logs exist for Campaign 9004 even though the campaign itself is `approval_awaiting` (ineligible).
- **Failed retries resolving to success**: Customer C2 explicitly demonstrates a retry path in action, failing a delivery on 9001 before succeeding on 9002.
- **Standalone duplicate targeting**: Customer C20 is intentionally targeted and counted twice within standalone Campaign 9101.
- **Semantic rules vs Numerical impact**: Retry deduplication is strictly required by the business semantics and is fully implemented in the final SQL; however, it has zero numerical impact in this particular dataset because no customer successfully received multiple messages in a single chain.
