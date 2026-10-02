-- New quotes use a transparent fare schedule calibrated against the reference
-- journey. Existing quotes and accepted trips retain their saved terms.
alter table public.finance_settings
  add column if not exists tariff_version text not null default 'delicias-balanced-2026-09';

create table if not exists public.tariff_versions (
  id text primary key,
  effective_at timestamptz not null,
  note text not null,
  categories jsonb not null,
  created_at timestamptz not null default now()
);
alter table public.tariff_versions enable row level security;
revoke all on public.tariff_versions from public, anon, authenticated;

insert into public.tariff_versions(id,effective_at,note,categories)
values (
  'delicias-balanced-2026-09',
  '2026-09-11 00:00:00-06',
  'Referencia histórica previa a la calibración transparente.',
  jsonb_build_object(
    'basic',jsonb_build_object('base_cents',2300,'km_cents',630,'minute_cents',75,'minimum_cents',4900),
    'large',jsonb_build_object('base_cents',3300,'km_cents',840,'minute_cents',100,'minimum_cents',6900),
    'commercial',jsonb_build_object('base_cents',7800,'km_cents',980,'minute_cents',120,'minimum_cents',13000),
    'plus',jsonb_build_object('base_cents',3900,'km_cents',910,'minute_cents',110,'minimum_cents',7900),
    'pickup',jsonb_build_object('base_cents',9600,'km_cents',1190,'minute_cents',150,'minimum_cents',17400)
  )
) on conflict(id) do nothing;

insert into public.tariff_versions(id,effective_at,note,categories)
values (
  'delicias-transparent-2026-10',
  now(),
  'Cotización con componentes visibles. Básico: 2.94 km y 5 minutos = $46.36 antes de descuentos y propina.',
  jsonb_build_object(
    'basic',jsonb_build_object('base_cents',2300,'km_cents',650,'minute_cents',85,'minimum_cents',4600),
    'large',jsonb_build_object('base_cents',3300,'km_cents',870,'minute_cents',115,'minimum_cents',6500),
    'commercial',jsonb_build_object('base_cents',7800,'km_cents',1010,'minute_cents',140,'minimum_cents',12200),
    'plus',jsonb_build_object('base_cents',3900,'km_cents',945,'minute_cents',125,'minimum_cents',7420),
    'pickup',jsonb_build_object('base_cents',9600,'km_cents',1230,'minute_cents',170,'minimum_cents',16400)
  )
) on conflict(id) do nothing;

update public.categories set base_cents=2300,km_cents=650,minute_cents=85,minimum_cents=4600,booking_fee_cents=0 where id='basic';
update public.categories set base_cents=3300,km_cents=870,minute_cents=115,minimum_cents=6500,booking_fee_cents=0 where id='large';
update public.categories set base_cents=7800,km_cents=1010,minute_cents=140,minimum_cents=12200,booking_fee_cents=0 where id='commercial';
update public.categories set base_cents=3900,km_cents=945,minute_cents=125,minimum_cents=7420,booking_fee_cents=0 where id='plus';
update public.categories set base_cents=9600,km_cents=1230,minute_cents=170,minimum_cents=16400,booking_fee_cents=0 where id='pickup';

update public.finance_settings
set tariff_version='delicias-transparent-2026-10', updated_at=now()
where id=true;

create or replace function private.finance_quote_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; q public.quotes; settings public.finance_settings; mult integer:=10000; demand integer; supply integer; extra integer:=0; parts jsonb;
begin
 result:=private.quote_v5(payload); select * into q from public.quotes where id=(result->>'id')::uuid;
 select * into settings from public.finance_settings where id;
 if settings.dynamic_enabled then
   select count(*) into demand from public.trips where status='requested' and driver_id is null;
   select count(*) into supply from public.drivers d join public.driver_presence dp on dp.driver_id=d.id where d.online and d.approved and d.account_active and dp.heartbeat_at>now()-interval '1 minute';
   mult:=least(settings.dynamic_max_bps,case when demand>greatest(supply,1)*2 then 15000 when demand>greatest(supply,1) then 12500 else 10000 end);
   extra:=round(q.fare_cents*(mult-10000)/10000.0);
 end if;
 parts:=jsonb_build_object('version',settings.version,'tariff_version',settings.tariff_version,'vat_included',true,'vat_bps',1600,'state_bps',150,
 'base_cents',q.fare_cents-q.distance_charge_cents-q.time_charge_cents-q.minimum_adjustment_cents-q.zone_surcharge_cents-q.accessibility_surcharge_cents-q.pickup_surcharge_cents,
 'distance_cents',q.distance_charge_cents,'time_cents',q.time_charge_cents,'minimum_cents',q.minimum_adjustment_cents,
 'zone_cents',q.zone_surcharge_cents,'accessibility_cents',q.accessibility_surcharge_cents,'pickup_cents',q.pickup_surcharge_cents,
 'dynamic_bps',mult,'dynamic_cents',extra,'tolls_cents',0,'waiting_cents',0,'price_mode','upfront',
 'level_discounts',settings.level_discounts);
 update public.quotes set fare_cents=fare_cents+extra,pricing_version=settings.tariff_version,financial_terms=parts where id=q.id returning * into q;
 return to_jsonb(q)||jsonb_build_object('fare_base_without_vat_cents',round(q.fare_cents/1.16),'fare_vat_cents',q.fare_cents-round(q.fare_cents/1.16));
end $$;
