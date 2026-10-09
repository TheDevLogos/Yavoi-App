import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// Deliberately kept as a closed endpoint so previously distributed clients
// cannot resume card charging while production uses direct cash collection.
Deno.serve(() => Response.json({
  error: "Los pagos digitales de Yavoi! no están disponibles.",
  model: "cash_direct_weekly_operations",
}, { status: 410, headers: { "cache-control": "no-store" } }));
