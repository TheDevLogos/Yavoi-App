-- Native Android/iOS push registrations. Tokens are private and readable only
-- by trusted Edge Functions; authenticated clients can register their own.
create table if not exists public.native_push_tokens (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  token text not null unique,
  platform text not null check (platform in ('android','ios')),
  app_id text not null check (app_id in ('mx.yavoi.pasajero','mx.yavoi.conductor','universal')),
  user_agent text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists native_push_tokens_profile_updated_idx
  on public.native_push_tokens(profile_id, updated_at desc);
alter table public.native_push_tokens enable row level security;
revoke all on public.native_push_tokens from public, anon, authenticated;

create or replace function private.register_native_push_token_v1(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  uid uuid := auth.uid();
  profile_role text;
  token_value text := trim(coalesce(payload->>'token',''));
  platform_value text := lower(trim(coalesce(payload->>'platform','')));
  app_id_value text := left(trim(coalesce(payload->>'app_id','universal')),64);
begin
  if uid is null then raise exception 'Inicia sesión para activar notificaciones.' using errcode='42501'; end if;
  select role into profile_role from public.profiles where id=uid and not suspended;
  if profile_role is null or profile_role not in ('driver','passenger') then raise exception 'Perfil activo requerido.' using errcode='42501'; end if;
  if length(token_value)<32 or length(token_value)>4096 then raise exception 'Token Firebase inválido.'; end if;
  if platform_value not in ('android','ios') then raise exception 'Plataforma no compatible.'; end if;
  if app_id_value not in ('mx.yavoi.pasajero','mx.yavoi.conductor','universal') then raise exception 'Aplicación no reconocida.'; end if;
  if (profile_role='driver' and app_id_value='mx.yavoi.pasajero') or (profile_role='passenger' and app_id_value='mx.yavoi.conductor') then
    raise exception 'El perfil no corresponde con esta aplicación.' using errcode='42501';
  end if;
  insert into public.native_push_tokens(profile_id,token,platform,app_id,user_agent,updated_at)
  values(uid,token_value,platform_value,app_id_value,left(coalesce(payload->>'user_agent',''),300),now())
  on conflict(token) do update set profile_id=excluded.profile_id,platform=excluded.platform,app_id=excluded.app_id,
    user_agent=excluded.user_agent,updated_at=now();
  return jsonb_build_object('ok',true);
end $$;
revoke all on function private.register_native_push_token_v1(jsonb) from public, anon;
grant execute on function private.register_native_push_token_v1(jsonb) to authenticated;

create or replace function public.yavoi_register_native_push(payload jsonb)
returns jsonb language sql security invoker set search_path='' as $$
  select private.register_native_push_token_v1(payload)
$$;
revoke all on function public.yavoi_register_native_push(jsonb) from public, anon;
grant execute on function public.yavoi_register_native_push(jsonb) to authenticated;
