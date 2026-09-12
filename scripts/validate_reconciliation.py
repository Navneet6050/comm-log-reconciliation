import sqlite3
import pandas as pd
from pathlib import Path
import sys

def main():
    repo_root = Path(__file__).resolve().parent.parent
    db_path = repo_root / "data" / "comm_log.db"
    sql_path = repo_root / "sql" / "final_query.sql"

    if not db_path.exists():
        print(f"Database not found at {db_path}")
        sys.exit(1)

    conn = sqlite3.connect(db_path)

    print("--- 1. SCOPE INVARIANT ---")
    df_logs = pd.read_sql_query("SELECT * FROM communication_log", conn)
    df_campaign = pd.read_sql_query("SELECT * FROM campaign", conn)

    df_scoped = df_logs[
        (df_logs['merchant_id'] == 501) &
        (df_logs['communication_type'] == '2') &
        (df_logs['sent_time'] >= '2026-10-01') &
        (df_logs['sent_time'] < '2026-11-01')
    ]
    scoped_raw = len(df_scoped)
    assert scoped_raw == 30, f"Invariant Failed: Expected 30 scoped raw attempts, got {scoped_raw}"
    print("PASS: merchant_id = 501, communication_type = '2', October 2026")
    print(f"PASS: Scoped raw attempts = {scoped_raw}")

    print("\n--- 2. CAMPAIGN ELIGIBILITY INVARIANT ---")
    c9004_attempts = df_scoped[df_scoped['communication_id'] == 9004]
    c9004_count = len(c9004_attempts)
    assert c9004_count == 4, f"Invariant Failed: Expected 4 scoped attempts for Campaign 9004, got {c9004_count}"
    print(f"PASS: Campaign 9004 has exactly {c9004_count} scoped attempts")

    eligible_statuses = ['approved', 'aborted', 'resumed', 'stopped']
    df_campaign_eligible = df_campaign[
        (df_campaign['creation_status'].isin(eligible_statuses)) &
        (df_campaign['processing_status'] == 'processed')
    ]
    df_eligible = df_scoped.merge(df_campaign_eligible, left_on='communication_id', right_on='id', how='inner')

    c9004_eligible = df_eligible[df_eligible['communication_id'] == 9004]
    assert len(c9004_eligible) == 0, "Invariant Failed: Campaign 9004 was not excluded by eligibility rules"
    print("PASS: Campaign 9004 attempts correctly excluded because campaign is not finalized")

    print("\n--- 3. DELIVERY OUTCOMES INVARIANT ---")
    df_failed = df_eligible[df_eligible['delivery_status'] != 900]
    failed_attempts = len(df_failed)
    assert failed_attempts == 4, f"Invariant Failed: Expected 4 failed eligible attempts, got {failed_attempts}"
    print(f"PASS: Failed eligible attempts = {failed_attempts}")

    df_delivered = df_eligible[df_eligible['delivery_status'] == 900]
    eligible_delivered = len(df_delivered)
    assert eligible_delivered == 22, f"Invariant Failed: Expected 22 eligible delivered attempts, got {eligible_delivered}"
    print(f"PASS: Delivered eligible attempts = {eligible_delivered}")

    print("\n--- 4. RETRY-CHAIN INVARIANT ---")
    c2_9001 = df_logs[(df_logs['customer_id'] == 'C2') & (df_logs['communication_id'] == 9001)]['delivery_status'].iloc[0]
    c2_9002 = df_logs[(df_logs['customer_id'] == 'C2') & (df_logs['communication_id'] == 9002)]['delivery_status'].iloc[0]
    assert c2_9001 == 1100, f"Invariant Failed: Expected C2 on 9001 to be 1100, got {c2_9001}"
    assert c2_9002 == 900, f"Invariant Failed: Expected C2 on 9002 to be 900, got {c2_9002}"
    print("PASS: Verified C2 has delivery_status 1100 on campaign 9001 and 900 on campaign 9002")

    def get_root(cid):
        parent = df_campaign.loc[df_campaign['id'] == cid, 'parent_id'].values[0]
        if pd.isna(parent):
            return cid
        return get_root(parent)

    df_campaign['root_id'] = df_campaign['id'].apply(get_root)
    chain_sizes = df_campaign.groupby('root_id').size()

    def is_standalone(cid):
        root = get_root(cid)
        return 1 if chain_sizes[root] == 1 else 0

    df_delivered_copy = df_delivered.copy()
    df_delivered_copy['root_id'] = df_delivered_copy['communication_id'].apply(get_root)
    df_delivered_copy['is_standalone'] = df_delivered_copy['communication_id'].apply(is_standalone)

    retry_chain_customers = df_delivered_copy[df_delivered_copy['is_standalone'] == 0]
    retry_contribution = retry_chain_customers.groupby(['root_id', 'customer_id']).size().shape[0]
    assert retry_contribution == 15, f"Invariant Failed: Expected retry-family contribution 15, got {retry_contribution}"
    print(f"PASS: Retry-family contribution = {retry_contribution} (using root campaign + customer semantics)")

    print("\n--- 5. STANDALONE INVARIANT ---")
    is_9101_standalone = is_standalone(9101)
    assert is_9101_standalone == 1, "Invariant Failed: Campaign 9101 is not recognized as standalone"
    print("PASS: Campaign 9101 is correctly identified as a standalone campaign")

    standalone_customers = df_delivered_copy[df_delivered_copy['is_standalone'] == 1]
    standalone_contribution = len(standalone_customers)
    distinct_standalone_customers = standalone_customers['customer_id'].nunique()

    assert standalone_contribution == 7, f"Invariant Failed: Expected standalone contribution 7, got {standalone_contribution}"
    assert distinct_standalone_customers == 6, f"Invariant Failed: Expected 6 distinct successful standalone customers, got {distinct_standalone_customers}"
    print(f"PASS: Successful standalone send-event contribution = {standalone_contribution}")
    print(f"PASS: Distinct successful standalone customers = {distinct_standalone_customers}")

    c20_standalone = standalone_customers[standalone_customers['customer_id'] == 'C20']
    c20_events = len(c20_standalone)
    assert c20_events == 2, f"Invariant Failed: Expected C20 to have 2 standalone events, got {c20_events}"
    print("PASS: Verified C20 has exactly 2 successful standalone send events")

    print("\n--- 6. FINAL RECONCILIATION ---")
    final_target_base = retry_contribution + standalone_contribution
    assert final_target_base == 22, f"Invariant Failed: Python logical reconciliation expected 22, got {final_target_base}"
    print(f"PASS: Python reconciliation: {retry_contribution} (retry) + {standalone_contribution} (standalone) = {final_target_base}")

    with open(sql_path, 'r') as f:
        final_sql = f.read()
    df_final = pd.read_sql_query(final_sql, conn)
    sql_target_base = df_final['target_base'].iloc[0]
    assert sql_target_base == 22, f"Invariant Failed: Expected SQL target_base 22, got {sql_target_base}"
    print(f"PASS: Final SQL target_base = {sql_target_base}")

    print("\n=======================================================")
    print("ALL RECONCILIATION INVARIANTS PASSED SUCCESSFULLY")
    print("=======================================================")

if __name__ == '__main__':
    main()
