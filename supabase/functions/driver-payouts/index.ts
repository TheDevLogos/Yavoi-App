import 'jsr:@supabase/functions-js/edge-runtime.d.ts';

// Payouts are intentionally unavailable. Weekly commissions are reconciled
// internally by Operations and neither app stores a destination or starts a transfer.
Deno.serve(() => Response.json({
  error: 'Los retiros y transferencias de conductores no están disponibles.',
  model: 'weekly_operations_reconciliation',
}, { status: 410, headers: { 'cache-control': 'no-store' } }));
