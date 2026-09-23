import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const migration = await readFile(new URL("../supabase/migrations/20260922200351_referral_rewards_and_promotion_reimbursements.sql", import.meta.url), "utf8");
const finance = await readFile(new URL("../src/operations-finance.js", import.meta.url), "utf8");
const portal = await readFile(new URL("../portal.html", import.meta.url), "utf8");
const walletMigration = await readFile(new URL("../supabase/migrations/20260923051243_driver_payment_aware_wallet.sql", import.meta.url), "utf8");
const walletCorrection = await readFile(new URL("../supabase/migrations/20260923121727_correct_driver_electronic_balance.sql", import.meta.url), "utf8");

test("referral point entries are accepted and invitees receive a controlled first-trip discount", () => {
  assert.match(migration, /'referral_registered','referral_first_trip','referral_welcome'/);
  assert.match(migration, /passenger_referral_welcome_20/);
  assert.match(migration, /'fare_discount_percent','badge-percent',0,20,4000/);
  assert.match(migration, /referral:welcome_discount:/);
  assert.match(migration, /exists\(select 1 from public\.trips where passenger_id=uid and status='completed'\)/);
  assert.match(migration, /values\(ref\.inviter_id,t\.id,70,'referral_first_trip'/);
  assert.doesNotMatch(migration, /values\(ref\.invitee_id,t\.id,25,'referral_welcome'/);
});

test("promotion discounts are reimbursed weekly without changing the contractual fare", () => {
  assert.match(migration, /create table public\.driver_promotion_reimbursements/);
  assert.match(migration, /cash_discount_cents integer not null default 0/);
  assert.match(migration, /card_discount_cents integer not null default 0/);
  assert.match(migration, /reimbursement_cents=public\.driver_promotion_reimbursements\.reimbursement_cents\+excluded\.reimbursement_cents/);
  assert.match(migration, /new\.reward_discount_cents>0/);
  assert.match(migration, /promotion_reimbursements_pending_cents/);
  assert.match(migration, /platform_contribution_after_promotions_cents/);
  assert.match(migration, /review_driver_promotion_reimbursement/);
});

test("Operations uses existing views for referral alerts and weekly reimbursements", () => {
  assert.match(portal, /src="\/src\/operations-finance\.js"/);
  assert.match(finance, /Liquidaciones de comisión en efectivo/);
  assert.match(finance, /\.referral-operations/);
  assert.match(finance, /\.commercial-reconciliation/);
  assert.match(finance, /table: "referrals"/);
  assert.match(finance, /Nuevo referido registrado/);
  assert.match(finance, /Referido completó su primer viaje/);
  assert.match(finance, /review_driver_promotion_reimbursement/);
  assert.match(finance, /20% en su primer viaje, máximo \$40/);
  assert.match(finance, /escapeHtml\(item\.driver_name/);
});


test("driver wallet separates cash from platform-held electronic earnings", () => {
  assert.match(walletMigration, /create function private\.dashboard_v17/);
  assert.match(walletMigration, /cash_collected_cents/);
  assert.match(walletMigration, /electronic_gross_cents/);
  assert.match(walletMigration, /electronic_net_cents/);
  assert.match(walletMigration, /promotion_reimbursements_pending_cents/);
  assert.match(walletMigration, /electronic_balance_cents/);
  assert.match(walletMigration, /'withdrawals_enabled',false/);
  assert.match(walletMigration, /when 'dashboard' then private\.dashboard_v17/);
  assert.match(walletCorrection, /electronic_net:=electronic_gross-card_commission/);
  assert.match(walletCorrection, /pay\.kind='tip' and pay\.provider='mercado_pago' and pay\.status='approved'/);
});
