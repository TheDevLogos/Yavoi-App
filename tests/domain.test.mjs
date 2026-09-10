import { test } from "node:test";
import assert from "node:assert/strict";
import { cents, changeDue, allowedView, escapeHtml, active, mfaQrSource } from "../src/domain.js";
test("cash amounts round to cents and invalid amounts are rejected", () => {
  assert.equal(cents("100.25"), 10025);
  assert.equal(changeDue(6850, 10000), 3150);
  assert.equal(changeDue(6850, 6850), 0);
  assert.throws(() => cents("-1"));
  assert.throws(() => cents("invalid"));
});
test("role navigation never grants passenger or driver admin views", () => {
  for (const role of ["passenger", "driver"])
    for (const view of ["fleet", "audit", "rates"]) assert.equal(allowedView(role, view), false);
  assert.equal(allowedView("admin", "fleet"), true);
  assert.equal(allowedView("passenger", "profile"), true);
});
test("untrusted content is escaped before rendering", () => {
  assert.equal(escapeHtml('<img onerror="alert(1)">'), "&lt;img onerror=&quot;alert(1)&quot;&gt;");
  assert.equal(escapeHtml("'&"), "&#39;&amp;");
});
test("only terminal trips are inactive", () => {
  assert.equal(active({ status: "completed" }), false);
  assert.equal(active({ status: "cancelled" }), false);
  assert.equal(active({ status: "in_progress" }), true);
});
test("MFA QR accepts Supabase data URIs without double encoding", () => {
  const dataUri = "data:image/svg+xml;utf-8,%3Csvg%3Eqr%3C/svg%3E";
  assert.equal(mfaQrSource(dataUri), dataUri);
  assert.match(mfaQrSource("<svg>qr</svg>"), /^data:image\/svg\+xml;charset=utf-8,/);
  assert.throws(() => mfaQrSource("javascript:alert(1)"), /código QR/);
});
