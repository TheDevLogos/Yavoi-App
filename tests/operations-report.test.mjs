import { test } from "node:test";
import assert from "node:assert/strict";
import {
  auditActionInfo,
  auditDetailItems,
  buildOperationsPdf,
  insuranceStatus,
  reportSections,
} from "../src/operations-report.js";

const report = {
  meta: {
    period: "month",
    from: "2026-09-01T00:00:00Z",
    to: "2026-09-12T00:00:00Z",
    generated_at: "2026-09-11T12:00:00Z",
  },
  summary: {
    completed: 24,
    cancelled: 2,
    active: 1,
    gross_cents: 156000,
    platform_commission_cents: 31200,
    average_ticket_cents: 6500,
    incidents: 1,
    average_rating: 4.8,
  },
  periods: {
    day: { trips: 4, completed: 3, gross_cents: 19500, platform_commission_cents: 3900 },
    week: { trips: 12, completed: 11, gross_cents: 71500, platform_commission_cents: 14300 },
    month: { trips: 26, completed: 24, gross_cents: 156000, platform_commission_cents: 31200 },
    year: { trips: 26, completed: 24, gross_cents: 156000, platform_commission_cents: 31200 },
  },
  drivers: [{ full_name: "Conductor Prueba", vehicle: "Nissan Versa", plate: "ABC123A", completed: 12, gross_cents: 78000, driver_earnings_cents: 62400, platform_commission_cents: 15600, rating: 4.9, ratings_count: 10, incidents: 0 }],
  incidents: [],
  ratings: [],
  insurance: [{ full_name: "Conductor Prueba", vehicle: "Nissan Versa", plate: "ABC123A", insurance_expires: "2026-10-01", days_remaining: 20, status: "critical", insurance_path: "policy.pdf" }],
  audit: [{ created_at: "2026-09-11T11:00:00Z", action: "driver_insurance_renewed", actor_name: "Operaciones", target_name: "Conductor Prueba", detail: { insurance_expires: "2026-10-01", note: "Validada" } }],
};

test("audit terms identify the action, area and readable details", () => {
  assert.deepEqual(auditActionInfo("driver_insurance_renewed"), ["Póliza de seguro renovada", "Documentos"]);
  assert.deepEqual(auditDetailItems({ approved: true, note: "Revisado" }), [
    { label: "Autorizado", value: "Sí" },
    { label: "Nota", value: "Revisado" },
  ]);
  assert.deepEqual(insuranceStatus("critical"), ["Vence en 30 días", "cancelled"]);
});

test("each report builds a useful table and a valid PDF", async () => {
  for (const type of ["overview", "drivers", "incidents", "ratings", "insurance", "audit"])
    assert.ok(reportSections(report, type)[0].head.length >= 5);
  const bytes = new Uint8Array((await buildOperationsPdf(report, { type: "overview" })).output("arraybuffer"));
  assert.ok(bytes.length > 5000);
  assert.equal(new TextDecoder().decode(bytes.slice(0, 4)), "%PDF");
});
