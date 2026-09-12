# Comm-Log Send Reconciliation Submission

## 1. Reconciliation Bridge

| Step | Adjustment Type | Description | Result | Reason & Evidence |
|---|---|---|---|---|
| 0 | Baseline | Naive scoped raw attempts | **30** | Baseline scoped rows for merchant 501, communication type 2, in October 2026. |
| 1 | Numerical | Exclude ineligible campaign | **26** | **Reason**: Excluded 4 attempts from Campaign 9004. <br>**Evidence**: Campaign 9004 is `approval_awaiting`. Because it is not finalized (`approved`, `aborted`, `resumed`, `stopped`), it is ineligible. |
| 2 | Numerical | Exclude failed attempts | **22** | **Reason**: Excluded 4 soft failure attempts where `delivery_status = 1100`.<br>**Evidence**: The failures are C2 in 9001, C3 in 9001, C3 in 9002, and D1 in 9201. |
| 3 | Analytical / Semantic | Retry-chain deduplication | **22** | **Reason**: Grouped eligible successful sends by retry root and counted distinct customers. No successful customer overlap was present within the eligible retry chains in this dataset, so applying retry-chain deduplication caused no additional numerical adjustment. Customer C2, for example, failed on 9001 and succeeded on 9002. |
| 4 | Analytical / Semantic | Preserve standalone events | **22** | **Reason**: Standalone campaigns legitimately count repeated customer successes as independent events.<br>**Evidence**: Customer C20 was targeted successfully twice in standalone campaign 9101 on two different dates, preserving both events in the final calculation. |
| **final**| **Result** | **Target Base** | **22** | Final correctly reconciled metric. |

## 2. SQL Query
The final correct SQL query is provided in `sql/final_query.sql`. The logic robustly implements the exact campaign eligibility rules and dynamically segregates standalone campaigns from retry chains, ensuring the calculation relies purely on the defined business logic rather than hardcoding.

## 3. Data Observations
What stood out during the reconciliation was the distinction between rules that fundamentally change the calculation vs rules that govern data modeling without causing a numerical impact in this specific dataset. 

No successful customer overlap was present within the eligible retry chains in this dataset, so applying retry-chain deduplication caused no additional numerical adjustment. Every customer who was reached successfully in a retry campaign (e.g. C2 in 9002) had definitively failed (`delivery_status = 1100`) their prior attempts. Thus, while the SQL actively implements the deduplication logic, it yields an adjustment of 0. Conversely, the only customer who *did* receive multiple successful messages was C20 in Campaign 9101, but because 9101 is a standalone campaign, both events are preserved.
