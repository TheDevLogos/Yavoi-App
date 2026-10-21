import { test } from "node:test";
import assert from "node:assert/strict";
import { dailyDriverEarningsCents } from "../src/daily-driver-earnings.js";

test("daily driver earnings sum posted ledger for trips completed on Chihuahua day", () => {
  const trips = [
    { id: "today", driver_id: "d1", status: "completed", completed_at: "2026-10-21T12:30:00.000Z", fare_cents: 7000, commission_cents: 1050, tip_cents: 500 },
    { id: "yesterday", driver_id: "d1", status: "completed", completed_at: "2026-10-21T05:59:59.000Z", fare_cents: 9000, commission_cents: 1350, tip_cents: 0 },
    { id: "active", driver_id: "d1", status: "in_progress", completed_at: null, fare_cents: 4000, commission_cents: 600, tip_cents: 0 },
    { id: "other-driver", driver_id: "d2", status: "completed", completed_at: "2026-10-21T14:00:00.000Z", fare_cents: 8000, commission_cents: 1200, tip_cents: 0 },
  ];
  const ledger = [
    { trip_id: "today", user_id: "d1", kind: "fare", amount_cents: 7000 },
    { trip_id: "today", user_id: "d1", kind: "commission", amount_cents: -1050 },
    { trip_id: "today", user_id: "d1", kind: "cash_tip", amount_cents: 500 },
    { trip_id: "yesterday", user_id: "d1", kind: "fare", amount_cents: 9000 },
    { trip_id: "other-driver", user_id: "d2", kind: "fare", amount_cents: 8000 },
  ];

  assert.equal(dailyDriverEarningsCents({
    driverId: "d1",
    trips,
    ledger,
    now: new Date("2026-10-21T18:00:00.000Z"),
  }), 6450);
});

test("daily earnings fall back to the trip's contractual net if the ledger is absent", () => {
  const trips = [
    { id: "legacy", driver_id: "d1", status: "completed", completed_at: "2026-10-21T12:00:00.000Z", fare_cents: 7000, commission_cents: 1050, tip_cents: 500 },
    { id: "contractual", driver_id: "d1", status: "completed", completed_at: "2026-10-21T13:00:00.000Z", fare_cents: 2000, commission_cents: 0, tip_cents: 0, financial_breakdown: { contractual_net_cents: 1800 } },
  ];

  assert.equal(dailyDriverEarningsCents({
    driverId: "d1",
    trips,
    ledger: [],
    now: new Date("2026-10-21T14:00:00.000Z"),
  }), 8250);
});

test("the frozen contractual net stays authoritative when the ledger is stale", () => {
  const trips = [
    { id: "adjusted", driver_id: "d1", status: "completed", completed_at: "2026-10-21T12:00:00.000Z", fare_cents: 7000, commission_cents: 1050, tip_cents: 500, financial_breakdown: { contractual_net_cents: 5900 } },
  ];
  const ledger = [
    { trip_id: "adjusted", user_id: "d1", kind: "fare", amount_cents: 7000 },
    { trip_id: "adjusted", user_id: "d1", kind: "commission", amount_cents: -1050 },
  ];

  assert.equal(dailyDriverEarningsCents({
    driverId: "d1",
    trips,
    ledger,
    now: new Date("2026-10-21T14:00:00.000Z"),
  }), 5900);
});
