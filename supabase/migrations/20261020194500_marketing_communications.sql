-- Inbox campaigns are durable. Device delivery is a separate, retryable job.
create table public.communication_messages (
  id uuid primary key default gen_random_uuid(),
  created_by uuid not null references public.profiles(id),
  recipient_id uuid references public.profiles(id) on delete cascade,
  audience text not null check (audience in ('all','passenger','driver')),
  category text not null check (category in ('general','safety','payment','service','promotion','news')),
  title text not null check (char_length(title) between 3 and 120),
  body text not null check (char_length(body) between 5 and 2000),
  image_path text,
  send_push boolean not null default false,
  created_at timestamptz not null default now(),
  ends_at timestamptz not null check (ends_at > created_at)
);
create index communication_messages_active_idx on public.communication_messages(audience,ends_at,created_at desc);
create index communication_messages_recipient_idx on public.communication_messages(recipient_id,created_at desc);
create table public.communication_message_reads (
  message_id uuid not null references public.communication_messages(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key(message_id,user_id)
);
create table public.communication_push_jobs (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null unique references public.communication_messages(id) on delete cascade,
  last_profile_id uuid,
  state text not null default 'queued' check (state in ('queued','sending','complete','failed')),
  delivered_count integer not null default 0,
  failed_count integer not null default 0,
  last_error text,
  updated_at timestamptz not null default now()
);
create table public.communication_push_preferences (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  marketing_enabled boolean not null default false,
  updated_at timestamptz not null default now()
);
alter table public.communication_messages enable row level security;
alter table public.communication_message_reads enable row level security;
alter table public.communication_push_jobs enable row level security;
alter table public.communication_push_preferences enable row level security;
revoke all on public.communication_messages,public.communication_message_reads,public.communication_push_jobs,public.communication_push_preferences from public,anon,authenticated;

create function private.communication_publish_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); msg public.communication_messages; target_id uuid; target_role text;
  audience_value text:=coalesce(nullif(payload->>'audience',''),'all');
  category_value text:=coalesce(nullif(payload->>'category',''),'general');
  title_value text:=trim(coalesce(payload->>'title',''));
  body_value text:=trim(coalesce(payload->>'body',''));
  email_value text:=lower(trim(coalesce(payload->>'recipient_email','')));
  image_value text:=nullif(trim(payload->>'image_path'),'');
  push_value boolean:=coalesce((payload->>'send_push')::boolean,false);
  ends_value timestamptz:=nullif(payload->>'ends_at','')::timestamptz;
begin
  if uid is null or not private.is_admin() then raise exception 'Operaciones requiere verificación en dos pasos.' using errcode='42501'; end if;
  if audience_value not in ('all','passenger','driver') or category_value not in ('general','safety','payment','service','promotion','news') then raise exception 'Destino o tipo inválido.'; end if;
  if char_length(title_value) not between 3 and 120 or char_length(body_value) not between 5 and 2000 then raise exception 'Revisa el título y el texto.'; end if;
  if ends_value is null or ends_value<=now() or ends_value>now()+interval '1 year' then raise exception 'La vigencia debe terminar dentro de un año.'; end if;
  if image_value is not null and not exists(select 1 from storage.objects where bucket_id='yavoi-marketing' and name=image_value) then raise exception 'Sube una imagen válida de Yavoi!.'; end if;
  if email_value<>'' then
    select p.id,p.role into target_id,target_role from auth.users u join public.profiles p on p.id=u.id
      where lower(u.email)=email_value and not p.suspended and p.role in ('passenger','driver');
    if target_id is null then raise exception 'No se encontró una cuenta activa con ese correo.'; end if;
    if audience_value<>'all' and audience_value<>target_role then raise exception 'El correo no corresponde con la aplicación seleccionada.'; end if;
    audience_value:=target_role;
  end if;
  insert into public.communication_messages(created_by,recipient_id,audience,category,title,body,image_path,send_push,ends_at)
    values(uid,target_id,audience_value,category_value,title_value,body_value,image_value,push_value,ends_value) returning * into msg;
  if push_value then insert into public.communication_push_jobs(message_id) values(msg.id); end if;
  insert into public.audit_log(actor_id,action,target_id,detail) values
    (uid,'communication_published',msg.id,jsonb_build_object('audience',audience_value,'recipient_id',target_id,'send_push',push_value,'category',category_value));
  return jsonb_build_object('message_id',msg.id,'push_queued',push_value,'audience',audience_value);
end $$;

create function private.communication_list_v1() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare uid uuid:=auth.uid(); role_value text; messages jsonb; sent jsonb:='[]'::jsonb;
begin
  select role into role_value from public.profiles where id=uid and not suspended;
  if role_value is null then raise exception 'Tu perfil no está disponible.' using errcode='42501'; end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into messages from (
    select m.id,m.title,m.body,m.category,m.audience,m.image_path,m.created_at,m.ends_at,(r.user_id is not null) is_read
    from public.communication_messages m left join public.communication_message_reads r on r.message_id=m.id and r.user_id=uid
    where m.created_at<=now() and m.ends_at>now() and (m.recipient_id=uid or (m.recipient_id is null and (m.audience='all' or m.audience=role_value)))
    order by m.created_at desc limit 100
  ) x;
  if role_value='admin' and private.is_admin() then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into sent from (
      select m.id,m.title,m.category,m.audience,m.recipient_id,m.created_at,m.ends_at,m.send_push,
        j.state push_state,j.delivered_count,j.failed_count,j.last_error
      from public.communication_messages m left join public.communication_push_jobs j on j.message_id=m.id
      order by m.created_at desc limit 50
    ) x;
  end if;
  return jsonb_build_object('messages',messages,'sent',sent);
end $$;

create function private.communication_read_v1(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); message_value uuid:=nullif(payload->>'announcement_id','')::uuid; role_value text;
begin
  select role into role_value from public.profiles where id=uid and not suspended;
  if role_value is null or message_value is null then raise exception 'Mensaje no disponible.' using errcode='42501'; end if;
  if not exists(select 1 from public.communication_messages m where m.id=message_value and m.created_at<=now() and m.ends_at>now()
    and (m.recipient_id=uid or (m.recipient_id is null and (m.audience='all' or m.audience=role_value)))) then
    raise exception 'El mensaje no está dirigido a este perfil.' using errcode='42501';
  end if;
  insert into public.communication_message_reads(message_id,user_id) values(message_value,uid) on conflict do nothing;
  return jsonb_build_object('ok',true);
end $$;

create function private.communication_message_exists_v1(message_value uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.communication_messages where id=message_value)
$$;

create function private.communication_preferences_v1(payload jsonb, save_value boolean default false) returns jsonb
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); enabled_value boolean;
begin
  if uid is null or not exists(select 1 from public.profiles where id=uid and role in ('passenger','driver') and not suspended) then
    raise exception 'Perfil activo requerido.' using errcode='42501';
  end if;
  if save_value then
    enabled_value:=coalesce((payload->>'marketing_enabled')::boolean,false);
    insert into public.communication_push_preferences(profile_id,marketing_enabled) values(uid,enabled_value)
      on conflict(profile_id) do update set marketing_enabled=excluded.marketing_enabled,updated_at=now();
  end if;
  select marketing_enabled into enabled_value from public.communication_push_preferences where profile_id=uid;
  return jsonb_build_object('marketing_enabled',coalesce(enabled_value,false));
end $$;

revoke all on function private.communication_publish_v1(jsonb),private.communication_list_v1(),private.communication_read_v1(jsonb),private.communication_message_exists_v1(uuid),private.communication_preferences_v1(jsonb,boolean) from public,anon;
grant execute on function private.communication_publish_v1(jsonb),private.communication_list_v1(),private.communication_read_v1(jsonb),private.communication_message_exists_v1(uuid),private.communication_preferences_v1(jsonb,boolean) to authenticated;

alter function public.yavoi_inbox(text,jsonb) rename to yavoi_inbox_before_communications;
create function public.yavoi_inbox(command text,payload jsonb default '{}') returns jsonb
language plpgsql security invoker set search_path='' as $$
declare result jsonb; extra jsonb;
begin
  if command='publish_communication' then return private.communication_publish_v1(payload); end if;
  if command='preferences' then return private.communication_preferences_v1(payload,false); end if;
  if command='set_preferences' then return private.communication_preferences_v1(payload,true); end if;
  if command='read' and private.communication_message_exists_v1(nullif(payload->>'announcement_id','')::uuid) then
    return private.communication_read_v1(payload);
  end if;
  if command='list' or command='unread_count' then
    result:=public.yavoi_inbox_before_communications('list','{}'::jsonb);
    extra:=private.communication_list_v1();
    if command='unread_count' then
      return jsonb_build_object('count',(select count(*) from jsonb_array_elements(coalesce(result->'messages','[]'::jsonb)||coalesce(extra->'messages','[]'::jsonb)) x where coalesce((x->>'is_read')::boolean,false)=false));
    end if;
    return result||jsonb_build_object('messages',coalesce(result->'messages','[]'::jsonb)||coalesce(extra->'messages','[]'::jsonb),
      'sent',coalesce(result->'sent','[]'::jsonb)||coalesce(extra->'sent','[]'::jsonb));
  end if;
  return public.yavoi_inbox_before_communications(command,payload);
end $$;
revoke all on function public.yavoi_inbox(text,jsonb) from public,anon;
grant execute on function public.yavoi_inbox(text,jsonb) to authenticated;
