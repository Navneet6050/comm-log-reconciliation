"""
validate_reconciliation.py
===========================================================================
Independent validation of the comm-log send reconciliation for merchant
501, October 2026.

This script re-derives `target_base` from the raw tables using plain
pandas — deliberately *not* reusing `sql/final_query.sql` for the core
logic — so that the SQL query and this script serve as two independent
implementations of the same business rules. Each section asserts one
specific, numbered invariant from the reconciliation bridge (see
`reports/submission.md`) in order:

    1. Scope        — the naive baseline is exactly 30 raw attempts.
    2. Eligibility   — campaign 9004 (approval_awaiting) is excluded.
    3. Delivery      — failed attempts are dropped; 22 remain delivered.
    4. Retry chains  — successes are deduplicated per (chain_root, customer).
    5. Standalone    — repeat customer sends outside a retry chain are
                        preserved as distinct events, not deduplicated.
    6. Reconciliation — the pandas-derived total and the SQL query's
                        `target_base` both equal Finance's reported 22.

If every assertion passes, both the independent pandas logic and the SQL
query agree with Finance's number — a much stronger check than either one
agreeing with 22 in isolation. A failed assertion points at exactly which
business rule broke and what value it produced instead, so a regression
is diagnosable without re-deriving the whole bridge by hand.

Usage:
    python scripts/validate_reconciliation.py
===========================================================================
"""

import sqlite3
import sys
from pathlib import Path

import pandas as pd


def main() -> None:
    repo_root = Path(__file__).resolve().parent.parent
    db_path = repo_root / "data" / "comm_log.db"
    sql_path = repo_root / "sql" / "final_query.sql"

    if not db_path.exists():
        print(f"ERROR: database not found at {db_path}")
        sys.exit(1)

    conn = sqlite3.connect(db_path)

    # =======================================================================
    # SECTION 1 — SCOPE INVARIANT
    # Confirms the naive baseline (Bridge Step 0) before any business logic
    # is applied: every send attempt for merchant 501, campaign type '2',
    # within October 2026.
    # =======================================================================
    print("--- 1. SCOPE INVARIANT ---")
    df_logs = pd.read_sql_query("SELECT * FROM communication_log", conn)
    df_campaign = pd.read_sql_query("SELECT * FROM campaign", conn)

    df_scoped = df_logs[
        (df_logs["merchant_id"] == 501)
        & (df_logs["communication_type"] == "2")
        & (df_logs["sent_time"] >= "2026-10-01")
        & (df_logs["sent_time"] < "2026-11-01")
    ]
    scoped_raw = len(df_scoped)
    assert scoped_raw == 30, (
        f"SCOPE INVARIANT FAILED: expected 30 naive scoped raw attempts "
        f"for merchant 501 / type '2' / October 2026, got {scoped_raw}. "
        f"Check the scope filters or whether the dataset changed."
    )
    print("PASS: scope = merchant_id 501, communication_type '2', October 2026")
    print(f"PASS: naive scoped raw attempts = {scoped_raw}")

    # =======================================================================
    # SECTION 2 — CAMPAIGN ELIGIBILITY INVARIANT
    # Confirms campaign 9004 (creation_status = 'approval_awaiting') is
    # excluded from the eligible set, even though its send attempts already
    # exist in communication_log (Bridge Step 1: 30 -> 26).
    # =======================================================================
    print("\n--- 2. CAMPAIGN ELIGIBILITY INVARIANT ---")
    c9004_attempts = df_scoped[df_scoped["communication_id"] == 9004]
    c9004_count = len(c9004_attempts)
    assert c9004_count == 4, (
        f"ELIGIBILITY INVARIANT FAILED: expected campaign 9004 to have "
        f"4 scoped attempts (all delivered, pre-eligibility-filter), "
        f"got {c9004_count}."
    )
    print(f"PASS: campaign 9004 has exactly {c9004_count} scoped attempts")

    eligible_statuses = ["approved", "aborted", "resumed", "stopped"]
    df_campaign_eligible = df_campaign[
        (df_campaign["creation_status"].isin(eligible_statuses))
        & (df_campaign["processing_status"] == "processed")
    ]
    df_eligible = df_scoped.merge(
        df_campaign_eligible, left_on="communication_id", right_on="id", how="inner"
    )

    c9004_eligible = df_eligible[df_eligible["communication_id"] == 9004]
    assert len(c9004_eligible) == 0, (
        "ELIGIBILITY INVARIANT FAILED: campaign 9004 (approval_awaiting) "
        "was NOT excluded by the eligibility filter — the eligibility "
        "condition is not being applied correctly."
    )
    print("PASS: campaign 9004's attempts are correctly excluded (creation_status not finalized)")

    # =======================================================================
    # SECTION 3 — DELIVERY OUTCOME INVARIANT
    # Confirms failed sends (delivery_status = 1100) are dropped from the
    # eligible set, leaving exactly the 22 eligible + delivered attempts
    # that Finance's target_base is ultimately built from (Bridge Step 2).
    # =======================================================================
    print("\n--- 3. DELIVERY OUTCOME INVARIANT ---")
    df_failed = df_eligible[df_eligible["delivery_status"] != 900]
    failed_attempts = len(df_failed)
    assert failed_attempts == 4, (
        f"DELIVERY OUTCOME INVARIANT FAILED: expected 4 failed attempts "
        f"among eligible campaigns, got {failed_attempts}."
    )
    print(f"PASS: failed attempts among eligible campaigns = {failed_attempts}")

    df_delivered = df_eligible[df_eligible["delivery_status"] == 900]
    eligible_delivered = len(df_delivered)
    assert eligible_delivered == 22, (
        f"DELIVERY OUTCOME INVARIANT FAILED: expected 22 eligible + "
        f"delivered attempts, got {eligible_delivered}."
    )
    print(f"PASS: eligible + delivered attempts = {eligible_delivered}")

    # =======================================================================
    # SECTION 4 — RETRY-CHAIN INVARIANT
    # Confirms retry-chain resolution (via campaign.parent_id) and
    # deduplication by (chain_root, customer_id) — a customer reached
    # anywhere in a chain counts once, however many attempts it took
    # (Bridge Step 3). First spot-checks the C2 fail-then-succeed pattern
    # directly, then computes the full retry-chain contribution.
    # =======================================================================
    print("\n--- 4. RETRY-CHAIN INVARIANT ---")
    c2_9001 = df_logs.loc[
        (df_logs["customer_id"] == "C2") & (df_logs["communication_id"] == 9001),
        "delivery_status",
    ].iloc[0]
    c2_9002 = df_logs.loc[
        (df_logs["customer_id"] == "C2") & (df_logs["communication_id"] == 9002),
        "delivery_status",
    ].iloc[0]
    assert c2_9001 == 1100, (
        f"RETRY-CHAIN INVARIANT FAILED: expected customer C2 on campaign "
        f"9001 (the original attempt) to have delivery_status 1100 "
        f"(failed), got {c2_9001}."
    )
    assert c2_9002 == 900, (
        f"RETRY-CHAIN INVARIANT FAILED: expected customer C2 on campaign "
        f"9002 (the retry) to have delivery_status 900 (delivered), "
        f"got {c2_9002}."
    )
    print("PASS: C2 failed on campaign 9001 and succeeded on its retry, campaign 9002")

    def resolve_chain_root(campaign_id: int) -> int:
        """Walk `parent_id` upward until reaching the root of the retry chain."""
        parent = df_campaign.loc[df_campaign["id"] == campaign_id, "parent_id"].values[0]
        if pd.isna(parent):
            return campaign_id
        return resolve_chain_root(parent)

    df_campaign["chain_root_id"] = df_campaign["id"].apply(resolve_chain_root)
    chain_sizes = df_campaign.groupby("chain_root_id").size()

    def is_standalone(campaign_id: int) -> int:
        """A campaign is standalone if its chain has exactly one member (itself)."""
        root = resolve_chain_root(campaign_id)
        return 1 if chain_sizes[root] == 1 else 0

    df_delivered_annotated = df_delivered.copy()
    df_delivered_annotated["chain_root_id"] = df_delivered_annotated["communication_id"].apply(
        resolve_chain_root
    )
    df_delivered_annotated["is_standalone"] = df_delivered_annotated["communication_id"].apply(
        is_standalone
    )

    retry_chain_deliveries = df_delivered_annotated[df_delivered_annotated["is_standalone"] == 0]
    retry_chain_contribution = (
        retry_chain_deliveries.groupby(["chain_root_id", "customer_id"]).size().shape[0]
    )
    assert retry_chain_contribution == 15, (
        f"RETRY-CHAIN INVARIANT FAILED: expected retry-chain contribution "
        f"of 15 distinct (chain_root, customer) pairs, got "
        f"{retry_chain_contribution}."
    )
    print(
        f"PASS: retry-chain contribution = {retry_chain_contribution} "
        f"distinct customers across all eligible retry chains"
    )

    # =======================================================================
    # SECTION 5 — STANDALONE CAMPAIGN INVARIANT
    # Confirms campaign 9101 is correctly classified as standalone (no
    # parent, no retries pointing at it) and that repeat successful sends
    # to the same customer there are preserved as distinct events rather
    # than deduplicated (Bridge Step 4).
    # =======================================================================
    print("\n--- 5. STANDALONE CAMPAIGN INVARIANT ---")
    campaign_9101_is_standalone = is_standalone(9101)
    assert campaign_9101_is_standalone == 1, (
        "STANDALONE INVARIANT FAILED: campaign 9101 was not classified as "
        "standalone — check the chain-size resolution logic."
    )
    print("PASS: campaign 9101 is correctly classified as standalone")

    standalone_deliveries = df_delivered_annotated[df_delivered_annotated["is_standalone"] == 1]
    standalone_contribution = len(standalone_deliveries)
    distinct_standalone_customers = standalone_deliveries["customer_id"].nunique()

    assert standalone_contribution == 7, (
        f"STANDALONE INVARIANT FAILED: expected 7 successful standalone "
        f"send events, got {standalone_contribution}."
    )
    assert distinct_standalone_customers == 6, (
        f"STANDALONE INVARIANT FAILED: expected 6 distinct customers "
        f"reached by standalone campaigns (fewer than the 7 events, due "
        f"to C20's repeat), got {distinct_standalone_customers}."
    )
    print(f"PASS: standalone successful send events (not deduplicated) = {standalone_contribution}")
    print(f"PASS: distinct customers reached by standalone campaigns = {distinct_standalone_customers}")

    c20_standalone_events = standalone_deliveries[standalone_deliveries["customer_id"] == "C20"]
    c20_event_count = len(c20_standalone_events)
    assert c20_event_count == 2, (
        f"STANDALONE INVARIANT FAILED: expected customer C20 to have 2 "
        f"successful standalone send events, got {c20_event_count}."
    )
    print("PASS: customer C20 correctly retains 2 distinct successful standalone events")

    # =======================================================================
    # SECTION 6 — FINAL RECONCILIATION
    # Combines the retry-chain and standalone contributions computed above
    # (independent pandas logic) and cross-checks the result against
    # sql/final_query.sql — both paths must agree with Finance's reported
    # target_base of 22.
    # =======================================================================
    print("\n--- 6. FINAL RECONCILIATION ---")
    pandas_target_base = retry_chain_contribution + standalone_contribution
    assert pandas_target_base == 22, (
        f"FINAL RECONCILIATION FAILED: pandas-derived target_base expected "
        f"22 (retry {retry_chain_contribution} + standalone "
        f"{standalone_contribution}), got {pandas_target_base}."
    )
    print(
        f"PASS: pandas reconciliation = {retry_chain_contribution} (retry chains) "
        f"+ {standalone_contribution} (standalone) = {pandas_target_base}"
    )

    with open(sql_path, "r") as f:
        final_sql = f.read()
    df_final_sql = pd.read_sql_query(final_sql, conn)
    sql_target_base = df_final_sql["target_base"].iloc[0]
    assert sql_target_base == 22, (
        f"FINAL RECONCILIATION FAILED: sql/final_query.sql produced "
        f"target_base = {sql_target_base}, expected 22. The pandas logic "
        f"and SQL query have diverged."
    )
    print(f"PASS: sql/final_query.sql target_base = {sql_target_base}")

    print("\n===========================================================")
    print("ALL RECONCILIATION INVARIANTS PASSED — target_base = 22")
    print("===========================================================")


if __name__ == "__main__":
    main()
