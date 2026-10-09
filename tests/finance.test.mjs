import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';
import { payoutEvent, settledPayout, signPayout } from '../supabase/functions/driver-payouts/provider.js';
import { generateKeyPairSync, verify } from 'node:crypto';
import { barPercent, splitIncludedVat, entryNames } from '../src/finance-domain.js';
test('IVA incluido y corte semanal informativo', async () => {
  assert.deepEqual(splitIncludedVat(11600), { base: 10000, vat: 1600 });
  assert.equal(barPercent(50, [0, 50, 100]), 50);
  assert.equal(barPercent(0, [0, 0]), 0);
  assert.equal(entryNames.commission, 'Comisión Yavoi! (IVA incluido)');

  const migration = await readFile(new URL('../supabase/migrations/20261009090000_cash_only_weekly_operations.sql', import.meta.url), 'utf8');
  assert.match(migration, /Los nuevos viajes sólo admiten efectivo al finalizar/);
  assert.match(migration, /Yavoi! no administra pagos digitales, cuentas, transferencias ni retiros/);
  assert.match(migration, /week_cash_cents/);
  assert.match(migration, /when 'finance_withdraw' then private\.finance_digital_payments_disabled/);
});

test('Payouts: signature, intermediate states and authoritative amounts', async () => {
 const { privateKey, publicKey } = generateKeyPairSync('ed25519');
 const body = JSON.stringify({ external_reference: '1234567' });
 const signature = await signPayout(body, privateKey.export({ format: 'pem', type: 'pkcs8' }));
 assert.ok(verify(null, Buffer.from(body), publicKey, Buffer.from(signature, 'base64')));
 assert.ok(!settledPayout({ status: 'approved' }));
 assert.ok(!settledPayout({ status: 'success', status_detail: 'in_progress' }));
 assert.ok(settledPayout({ status: 'processed', status_detail: 'approved' }));
 const w = { id: 'withdrawal', provider_transaction_id: 'txn', provider_reference: 123, net_cents: 9700 };
 const t = { id: 'txn', external_reference: '123', amount: { currency: 'MXN', value: 97 }, status: 'processed', status_detail: 'approved' };
 assert.equal(payoutEvent(w,t).amount_cents,9700);
 assert.throws(()=>payoutEvent(w,{...t,amount:{currency:'MXN',value:100}}),/no coincide/);
});
