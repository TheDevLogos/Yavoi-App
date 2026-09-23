create table public.yavoi_announcements(
 id uuid primary key default gen_random_uuid(),created_by uuid not null references public.profiles(id),title text not null check(char_length(title) between 3 and 120),
 body text not null check(char_length(body) between 5 and 2000),category text not null check(category in ('general','safety','payment','service','promotion','news')),
 audience text not null default 'all' check(audience in ('all','passenger','driver')),starts_at timestamptz not null default now(),ends_at timestamptz not null,created_at timestamptz not null default now(),check(ends_at>starts_at));
create index yavoi_announcements_active_audience on public.yavoi_announcements(audience,starts_at desc,ends_at);
create table public.yavoi_announcement_reads(announcement_id uuid not null references public.yavoi_announcements(id) on delete cascade,user_id uuid not null references public.profiles(id) on delete cascade,read_at timestamptz not null default now(),primary key(announcement_id,user_id));
create index yavoi_announcement_reads_user on public.yavoi_announcement_reads(user_id,read_at desc);
alter table public.yavoi_announcements enable row level security;alter table public.yavoi_announcement_reads enable row level security;
revoke all on public.yavoi_announcements,public.yavoi_announcement_reads from public,anon,authenticated;
create function private.yavoi_announcements_list_v1(payload jsonb default '{}') returns jsonb language plpgsql stable security definer set search_path='' as $$
declare uid uuid:=auth.uid();role_value text;messages jsonb;sent jsonb:='[]'::jsonb;
begin
 if uid is null then raise exception 'Inicia sesión para consultar tus mensajes.' using errcode='42501';end if;
 select p.role into role_value from public.profiles p where p.id=uid and not p.suspended;
 if role_value is null then raise exception 'Tu perfil no está disponible.' using errcode='42501';end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into messages from (
  select a.id,a.title,a.body,a.category,a.audience,a.starts_at,a.ends_at,a.created_at,(r.user_id is not null) is_read from public.yavoi_announcements a
  left join public.yavoi_announcement_reads r on r.announcement_id=a.id and r.user_id=uid where a.starts_at<=now() and a.ends_at>now() and (role_value='admin' or a.audience='all' or a.audience=role_value) order by a.created_at desc limit 100) x;
 if role_value='admin' and private.is_admin() then select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into sent from (select id,title,category,audience,starts_at,ends_at,created_at from public.yavoi_announcements order by created_at desc limit 50) x;end if;
 return jsonb_build_object('messages',messages,'sent',sent);
end $$;
revoke all on function private.yavoi_announcements_list_v1(jsonb) from public,anon;grant execute on function private.yavoi_announcements_list_v1(jsonb) to authenticated;
create function private.yavoi_announcement_read_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();announcement_id_value uuid:=nullif(payload->>'announcement_id','')::uuid;role_value text;
begin
 if uid is null or announcement_id_value is null then raise exception 'Mensaje no disponible.' using errcode='42501';end if;
 select p.role into role_value from public.profiles p where p.id=uid and not p.suspended;
 if role_value is null then raise exception 'Tu perfil no está disponible.' using errcode='42501';end if;
 if not exists(select 1 from public.yavoi_announcements a where a.id=announcement_id_value and a.starts_at<=now() and a.ends_at>now() and (role_value='admin' or a.audience='all' or a.audience=role_value)) then raise exception 'El mensaje ya no está vigente o no está dirigido a tu perfil.';end if;
 insert into public.yavoi_announcement_reads(announcement_id,user_id) values(announcement_id_value,uid) on conflict(announcement_id,user_id) do nothing;
 return jsonb_build_object('ok',true,'announcement_id',announcement_id_value);
end $$;
revoke all on function private.yavoi_announcement_read_v1(jsonb) from public,anon;grant execute on function private.yavoi_announcement_read_v1(jsonb) to authenticated;
create function private.yavoi_announcement_publish_v1(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();row_value public.yavoi_announcements;title_value text:=trim(coalesce(payload->>'title',''));body_value text:=trim(coalesce(payload->>'body',''));category_value text:=coalesce(payload->>'category','general');audience_value text:=coalesce(payload->>'audience','all');ends_value timestamptz:=nullif(payload->>'ends_at','')::timestamptz;
begin
 if uid is null or not private.is_admin() or coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then raise exception 'Sólo Operaciones con verificación en dos pasos puede publicar comunicados.' using errcode='42501';end if;
 if char_length(title_value) not between 3 and 120 or char_length(body_value) not between 5 and 2000 then raise exception 'Revisa que el título y el mensaje tengan una extensión válida.';end if;
 if category_value not in ('general','safety','payment','service','promotion','news') then raise exception 'Tipo de mensaje inválido.';end if;
 if audience_value not in ('all','passenger','driver') then raise exception 'Destinatarios inválidos.';end if;
 if ends_value is null or ends_value<=now() or ends_value>now()+interval '1 year' then raise exception 'La vigencia debe terminar en el futuro y dentro de un año.';end if;
 insert into public.yavoi_announcements(created_by,title,body,category,audience,ends_at) values(uid,title_value,body_value,category_value,audience_value,ends_value) returning * into row_value;
 insert into public.audit_log(actor_id,action,target_id,detail) values(uid,'announcement_published',row_value.id,jsonb_build_object('title',row_value.title,'category',row_value.category,'audience',row_value.audience,'ends_at',row_value.ends_at));return to_jsonb(row_value);
end $$;
revoke all on function private.yavoi_announcement_publish_v1(jsonb) from public,anon;grant execute on function private.yavoi_announcement_publish_v1(jsonb) to authenticated;
create function public.yavoi_inbox(command text,payload jsonb default '{}') returns jsonb language sql security invoker set search_path='' as $$
 select case command when 'list' then private.yavoi_announcements_list_v1(payload) when 'read' then private.yavoi_announcement_read_v1(payload) when 'publish' then private.yavoi_announcement_publish_v1(payload) else jsonb_build_object('error','Acción de bandeja desconocida.') end $$;
revoke all on function public.yavoi_inbox(text,jsonb) from public,anon;grant execute on function public.yavoi_inbox(text,jsonb) to authenticated;
