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

    # 1. FINAL SQL EXECUTION & ASSERTION
    with open(sql_path, 'r') as f:
        final_sql = f.read()
    
    df_final = pd.read_sql_query(final_sql, conn)
    sql_target_base = df_final['target_base'].iloc[0]
    
    print(f"SQL target_base result: {sql_target_base}")
    assert sql_target_base == 22, f"Expected 22, got {sql_target_base}"

    # 2. INDEPENDENT PYTHON CALCULATION & ASSERTIONS
    df_campaign = pd.read_sql_query("SELECT * FROM campaign", conn)
    df_logs = pd.read_sql_query("SELECT * FROM communication_log", conn)

    # Base scoping
    df_scoped = df_logs[
        (df_logs['merchant_id'] == 501) & 
        (df_logs['communication_type'] == '2') & 
        (df_logs['sent_time'] >= '2026-10-01') & 
        (df_logs['sent_time'] < '2026-11-01')
    ]
    scoped_raw = len(df_scoped)
    print(f"Scoped raw attempts: {scoped_raw}")
    assert scoped_raw == 30, f"Expected 30 scoped raw attempts, got {scoped_raw}"

    # Ineligible campaign (9004) logic check
    ineligible_campaigns = df_scoped[df_scoped['communication_id'] == 9004]
    ineligible_attempts = len(ineligible_campaigns)
    print(f"Ineligible campaign 9004 attempts: {ineligible_attempts}")
    assert ineligible_attempts == 4, f"Expected 4 ineligible attempts from 9004, got {ineligible_attempts}"

    eligible_statuses = ['approved', 'aborted', 'resumed', 'stopped']
    df_campaign_eligible = df_campaign[
        (df_campaign['creation_status'].isin(eligible_statuses)) & 
        (df_campaign['processing_status'] == 'processed')
    ]
    df_eligible = df_scoped.merge(df_campaign_eligible, left_on='communication_id', right_on='id', how='inner')

    # Failed Deliveries
    df_failed = df_eligible[df_eligible['delivery_status'] != 900]
    failed_attempts = len(df_failed)
    print(f"Failed attempts in eligible campaigns: {failed_attempts}")
    assert failed_attempts == 4, f"Expected 4 failed attempts, got {failed_attempts}"

    # Check C2 specific statuses
    c2_9001 = df_logs[(df_logs['customer_id'] == 'C2') & (df_logs['communication_id'] == 9001)]['delivery_status'].iloc[0]
    c2_9002 = df_logs[(df_logs['customer_id'] == 'C2') & (df_logs['communication_id'] == 9002)]['delivery_status'].iloc[0]
    assert c2_9001 == 1100, "C2 on 9001 should be 1100"
    assert c2_9002 == 900, "C2 on 9002 should be 900"
    print("Verified: C2 has 1100 on 9001 and 900 on 9002")

    df_delivered = df_eligible[df_eligible['delivery_status'] == 900]
    eligible_delivered = len(df_delivered)
    print(f"Eligible delivered attempts: {eligible_delivered}")
    assert eligible_delivered == 22, f"Expected 22 eligible delivered attempts, got {eligible_delivered}"

    # Standalone vs Retry Chains
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

    # Retry-chain semantics
    retry_chain_customers = df_delivered_copy[df_delivered_copy['is_standalone'] == 0]
    retry_contribution = retry_chain_customers.groupby(['root_id', 'customer_id']).size().shape[0]
    print(f"Retry-chain contribution: {retry_contribution}")
    assert retry_contribution == 15, f"Expected retry contribution 15, got {retry_contribution}"

    # Standalone events
    standalone_customers = df_delivered_copy[df_delivered_copy['is_standalone'] == 1]
    standalone_contribution = len(standalone_customers)
    print(f"Standalone contribution: {standalone_contribution}")
    assert standalone_contribution == 7, f"Expected standalone contribution 7, got {standalone_contribution}"

    # C20 Standalone events check
    c20_standalone = standalone_customers[standalone_customers['customer_id'] == 'C20']
    c20_events = len(c20_standalone)
    assert c20_events == 2, f"Expected C20 to have 2 standalone events, got {c20_events}"
    print("Verified: C20 has exactly 2 successful standalone send events")

    final_target_base = retry_contribution + standalone_contribution
    print(f"Final target_base calculation: {final_target_base}")
    assert final_target_base == 22, f"Expected final Python calculation 22, got {final_target_base}"

    print("\nAll assertions passed successfully. Validation complete.")

if __name__ == '__main__':
    main()
