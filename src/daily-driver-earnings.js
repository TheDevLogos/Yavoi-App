const BUSINESS_TIME_ZONE = "America/Chihuahua";
const dayFormatter = new Intl.DateTimeFormat("en-CA", {
  timeZone: BUSINESS_TIME_ZONE,
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
});

function dayKey(value) {
  const timestamp = value instanceof Date ? value : new Date(value || "");
  if (!Number.isFinite(timestamp.getTime())) return "";
  const parts = Object.fromEntries(dayFormatter.formatToParts(timestamp).map(({ type, value: part }) => [type, part]));
  return `${parts.year}-${parts.month}-${parts.day}`;
}

function tripNetCents(trip) {
  const recordedValue = trip?.financial_breakdown?.contractual_net_cents;
  const recordedNet = Number(recordedValue);
  if (recordedValue !== null && recordedValue !== undefined && Number.isFinite(recordedNet)) return recordedNet;
  return Number(trip?.fare_cents || 0) - Number(trip?.commission_cents || 0) + Number(trip?.tip_cents || 0);
}

/**
 * Sum the driver's contractual net for trips completed on the Chihuahua
 * business day. The frozen trip financial snapshot is authoritative; legacy
 * trips fall back to posted ledger entries and then their fare fields.
 */
export function dailyDriverEarningsCents({ driverId, trips = [], ledger = [], now = new Date() } = {}) {
  if (!driverId) return 0;
  const today = dayKey(now);
  if (!today) return 0;

  const ledgerByTrip = new Map();
  for (const entry of ledger) {
    if (!entry?.trip_id || entry.user_id && entry.user_id !== driverId) continue;
    const amount = Number(entry.amount_cents);
    if (!Number.isFinite(amount)) continue;
    ledgerByTrip.set(entry.trip_id, (ledgerByTrip.get(entry.trip_id) || 0) + amount);
  }

  return trips.reduce((total, trip) => {
    if (trip?.driver_id !== driverId || trip.status !== "completed") return total;
    if (dayKey(trip.completed_at || trip.updated_at || trip.created_at) !== today) return total;
    const hasFrozenNet = trip?.financial_breakdown?.contractual_net_cents !== null
      && trip?.financial_breakdown?.contractual_net_cents !== undefined
      && Number.isFinite(Number(trip.financial_breakdown.contractual_net_cents));
    const entries = ledgerByTrip.get(trip.id);
    return total + (hasFrozenNet || entries === undefined ? tripNetCents(trip) : entries);
  }, 0);
}
