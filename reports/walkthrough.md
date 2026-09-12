# Comm-Log Send Reconciliation — Investigation Walkthrough

This document reconstructs the actual investigation, in order — not the clean final answer, but the loop that got there each time a number didn't match:

```
Question → Initial query → Observed result → What looked wrong/surprising
   → Business interpretation → Next investigation → Updated count
```

Four iterations of that loop take the count from **30 → 22**.

---

## Iteration 0 — Establishing the Baseline

**Question.** Before touching any business logic: what does the raw log say the send volume was for merchant 501, October 2026?

**Initial query.**
```sql
SELECT COUNT(*) AS naive_scoped_attempts
FROM communication_log
WHERE merchant_id = 501
  AND communication_type = '2'
  AND sent_time >= '2026-10-01' AND sent_time < '2026-11-01';
```

**Observed result.** `30`.

**What looked wrong / surprising.** Nothing yet — this is the deliberately naive starting point, scoped only by merchant/type/date. It treats every row as a valid, countable send, which is almost certainly wrong, since it ignores campaign state and delivery outcome entirely.

**Business interpretation.** 30 is an *upper bound*, not a metric. It's the number to explain a gap from, not a number to report.

**Next investigation.** Finance's number (22) is 8 lower. Break the 30 down by campaign to see where the excess volume is concentrated.

**Updated count.** `30` (unchanged — this iteration just frames the problem).

---

## Iteration 1 — Campaign Eligibility

**Question.** Do all 7 campaigns behind these 30 rows actually qualify for reporting?

**Initial query.**
```sql
SELECT
    c.id, c.name, c.creation_status, c.processing_status,
    COUNT(l.id) AS raw_attempt_count,
    SUM(CASE WHEN l.delivery_status = 900 THEN 1 ELSE 0 END) AS delivered_attempt_count
FROM campaign c
LEFT JOIN communication_log l ON c.id = l.communication_id
GROUP BY c.id, c.name, c.creation_status, c.processing_status
ORDER BY c.id;
```

**Observed result.** Six campaigns show `creation_status = 'approved'`. One — campaign **9004**, "Diwali Cart Recovery - Retry C (pending)" — shows `creation_status = 'approval_awaiting'`, and yet it already has **4 delivered rows** (`delivery_status = 900`) in `communication_log`.

**What looked wrong / surprising.** A campaign that hasn't cleared approval already has successful sends logged against it. That shouldn't be possible if approval gates sending — but the README is explicit that the send pipeline can run ahead of approval bookkeeping, so this is a real (if unusual) state, not a data error.

**Business interpretation.** Per the eligibility rule (`creation_status` in the finalized set **and** `processing_status = 'processed'`), campaign 9004 is not reportable yet. Its 4 delivered sends exist operationally but aren't part of `target_base` until approval catches up.

**Next investigation.** Exclude 9004 and recheck the remaining volume, split by delivery outcome — the eligibility filter alone doesn't explain the full 30→22 gap.

**Updated count.** `30 → 26` (drop 9004's 4 delivered rows).

---

## Iteration 2 — Delivery Outcome

**Question.** Of the 26 remaining attempts (all from eligible campaigns), how many actually reached the customer?

**Initial query.**
```sql
SELECT
    delivery_status,
    COUNT(*) AS attempt_count,
    COUNT(DISTINCT customer_id) AS distinct_customer_count
FROM communication_log
WHERE merchant_id = 501 AND communication_type = '2'
  AND sent_time >= '2026-10-01' AND sent_time < '2026-11-01'
GROUP BY delivery_status;
```

**Observed result.** `delivery_status = 1100` (failed) accounts for 4 attempts among eligible campaigns: customer **C2** and **C3** on campaign 9001, **C3** again on 9002, and **D1** on 9201.

**What looked wrong / surprising.** C3 fails twice in a row (9001, then again on the retry 9002) before finally succeeding on 9003. That's three log rows for one customer inside one retry family — worth flagging for the next iteration, since it's exactly the shape a naive `COUNT(DISTINCT customer_id)` could get wrong in either direction.

**Business interpretation.** A failed delivery attempt was never received by the customer — it cannot count as a "reached" customer no matter what happens later in that campaign's retry chain. These 4 rows are excluded from the numerator, not carried forward with a caveat.

**Next investigation.** With eligibility and delivery outcome both applied, the running total already matches Finance's 22 — but that could be a coincidence if retry chains are hiding both double-counting *and* under-counting that happen to cancel out. Retry structure needs to be checked explicitly before trusting the number.

**Updated count.** `26 → 22`.

---

## Iteration 3 — Retry Chains

**Question.** C3's failed-failed-succeeded path on 9001→9002→9003 raises the real question: does any customer have **more than one successful delivery** inside the same retry chain, which a flat count would double-count?

**Initial query.**
```sql
WITH RECURSIVE campaign_hierarchy AS (
    SELECT id, parent_id, id AS root_id FROM campaign WHERE parent_id IS NULL
    UNION ALL
    SELECT c.id, c.parent_id, ch.root_id
    FROM campaign c JOIN campaign_hierarchy ch ON c.parent_id = ch.id
),
family_counts AS (
    SELECT root_id, COUNT(*) AS family_size FROM campaign_hierarchy GROUP BY root_id
)
-- ...joined against eligible, delivered logs, grouped by (root_id, customer_id)
SELECT root_id, customer_id, COUNT(*) AS successful_deliveries
FROM eligible_delivered_logs
WHERE family_size > 1
GROUP BY root_id, customer_id
HAVING COUNT(*) > 1;
```

**Observed result.** **Zero rows.** Every customer who eventually succeeded inside a retry family (C2 on 9001→9002, C3 on 9001→9002→9003, D1 on 9201→9202) had failed *every* prior attempt in that same chain. No one has two successful deliveries within one chain.

**What looked wrong / surprising.** This was genuinely worth checking rather than assuming — a `COUNT(DISTINCT customer_id)` and a raw `COUNT(*)` happen to agree here *only* because this dataset never puts two successes in one chain. That's a property of this specific data, not a property of the query — a dataset with one more successful retry send would silently break a naive count without this check catching it.

**Business interpretation.** Retry-chain deduplication (group by chain root, count distinct customers) is required by the definition of `target_base` and is fully implemented in `final_query.sql` — it simply produces a net adjustment of **0** on this dataset, because the "collapse to distinct" step never had anything to collapse.

**Next investigation.** One campaign (9101) has no retry chain at all. Confirm it's handled by the *other* branch of the logic — repeat-customer sends there should NOT be deduplicated the way a retry chain would be.

**Updated count.** `22 → 22` (no change — confirms the retry-dedup logic is correct without it being visible in this dataset's total).

---

## Iteration 4 — Standalone Campaigns

**Question.** Campaign 9101 has no parent and nothing retries off it. Customer C20 appears twice under it with two successful deliveries. Does that get (wrongly) deduplicated too?

**Initial query.**
```sql
SELECT communication_id, customer_id, sent_time, delivery_status
FROM communication_log
WHERE communication_id = 9101 AND delivery_status = 900
ORDER BY sent_time;
```

**Observed result.** C20 appears twice — `2026-10-10` and `2026-10-20` — both `delivery_status = 900`.

**What looked wrong / surprising.** On the surface this looks identical to the C2/C3 retry pattern from Iteration 3: same customer, same campaign family, two successful-looking rows. The difference is entirely structural, not visible in the `communication_log` row itself — it's that 9101 has no `parent_id` chain at all.

**Business interpretation.** Because there's no retry chain to collapse, each send under a standalone campaign is its own qualifying event. C20's two sends are two separate instances of being reached, both counted — this is the opposite treatment from Iteration 3, and it's the reason the final query branches on `is_standalone` rather than applying one dedup rule everywhere.

**Next investigation.** None — this closes the last open question in the bridge. Final total should equal Finance's reported figure.

**Updated count.** `22 → 22`, confirmed final.

---

## Final Reconciliation

| Iteration | Question resolved | Count |
|---|---|:---:|
| 0 | What's the naive volume? | 30 |
| 1 | Which campaigns are actually eligible? | 26 |
| 2 | Which attempts actually delivered? | 22 |
| 3 | Does any retry chain double-count a customer? | 22 (no change — verified) |
| 4 | Do standalone repeats get wrongly deduplicated? | 22 (no change — verified) |
| **Final** | | **22** |

## What Would Have Been Easy to Miss

- Assuming `approval_awaiting` campaigns have no data yet — they can, because sending and approval are separate pipelines.
- Trusting that "customer appears twice under one campaign" always means the same thing — it means opposite things depending on whether that campaign is a retry-chain member or a standalone.
- Treating "the retry-dedup step didn't change the number" as evidence the step is unnecessary, rather than confirming *why* it didn't change the number and keeping the logic in place for the next dataset that does have an overlap.
