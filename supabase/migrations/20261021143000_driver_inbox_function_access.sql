-- The public inbox RPC is SECURITY INVOKER and calls these scoped helpers.
-- Each helper already limits its rows to auth.uid(); allow authenticated
-- callers to execute them without exposing them to anonymous sessions.
grant execute on function private.driver_operating_notices_v1() to authenticated;
grant execute on function private.driver_receipt_inbox_v1() to authenticated;
grant execute on function private.driver_settlement_receipts_v1() to authenticated;
