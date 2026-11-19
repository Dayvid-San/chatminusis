-- Chatminusis schema for Supabase (stage 11).
-- Mirrors firebase/database.rules.json: the server stores only opaque MLS
-- blobs; Row Level Security + SECURITY DEFINER functions enforce membership,
-- admin rights, epoch compare-and-set and single-use key packages.
-- Requires "Confirm email" enabled in Supabase Auth (no session before verification).

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- profiles
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  nickname text not null unique
    check (nickname ~ '^[a-z0-9_.]{3,20}$' and nickname !~ '^\.|\.$|\.\.'),
  display_name text not null check (char_length(display_name) between 1 and 30),
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
-- Own row only: others are reachable just through the functions below
-- (exact nickname or known id), so the table cannot be listed.
create policy profiles_own_select on public.profiles for select to authenticated using (id = auth.uid());
create policy profiles_own_update on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create or replace function public.claim_nickname(p_nickname text, p_display_name text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  insert into profiles (id, nickname, display_name) values (auth.uid(), p_nickname, p_display_name)
  on conflict (id) do update set nickname = excluded.nickname, display_name = excluded.display_name;
exception when unique_violation then
  raise exception 'nickname_taken';
end $$;

create or replace function public.find_profile_by_nickname(p_nickname text)
returns table (id uuid, nickname text, display_name text)
language sql stable security definer set search_path = public as $$
  select id, nickname, display_name from profiles where auth.uid() is not null and nickname = p_nickname limit 1
$$;

create or replace function public.get_profile(p_id uuid)
returns table (id uuid, nickname text, display_name text)
language sql stable security definer set search_path = public as $$
  select id, nickname, display_name from profiles where auth.uid() is not null and id = p_id limit 1
$$;

-- ---------------------------------------------------------------- blocks / reports
create table public.blocks (
  user_id uuid not null references auth.users (id) on delete cascade,
  blocked_id uuid not null references auth.users (id) on delete cascade,
  primary key (user_id, blocked_id),
  check (user_id <> blocked_id)
);
alter table public.blocks enable row level security;
create policy blocks_own on public.blocks for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create table public.reports (
  id bigserial primary key,
  reporter uuid not null default auth.uid() references auth.users (id) on delete cascade,
  reported uuid not null references auth.users (id) on delete cascade,
  reason text not null check (char_length(reason) between 1 and 500),
  created_at timestamptz not null default now(),
  check (reporter <> reported)
);
alter table public.reports enable row level security;
create policy reports_insert on public.reports for insert to authenticated with check (reporter = auth.uid());

-- ---------------------------------------------------------------- identity & key packages
create table public.identities (
  user_id uuid primary key references auth.users (id) on delete cascade,
  signature_key text not null check (char_length(signature_key) between 1 and 200),
  updated_at timestamptz not null default now()
);
alter table public.identities enable row level security;
create policy identities_read on public.identities for select to authenticated using (true);
create policy identities_write on public.identities for insert to authenticated with check (user_id = auth.uid());
create policy identities_update on public.identities for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create table public.key_packages (
  id bigserial primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  key_package text not null check (char_length(key_package) <= 4000),
  created_at timestamptz not null default now()
);
alter table public.key_packages enable row level security;
create policy kp_own_insert on public.key_packages for insert to authenticated with check (user_id = auth.uid());
create policy kp_own_select on public.key_packages for select to authenticated using (user_id = auth.uid());
create policy kp_own_delete on public.key_packages for delete to authenticated using (user_id = auth.uid());

-- Atomically takes one key package of another user (single use).
create or replace function public.claim_key_package(p_user uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v text;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  delete from key_packages where id = (
    select id from key_packages where user_id = p_user order by id limit 1 for update skip locked
  ) returning key_package into v;
  return v;
end $$;

-- ---------------------------------------------------------------- conversations
create table public.conversations (
  id text primary key check (id ~ '^(d|g)_[A-Za-z0-9_-]{8,160}$'),
  type text not null check (type in ('direct', 'group')),
  created_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  epoch integer not null check (epoch >= 1),
  check ((type = 'direct') = (id like 'd\_%'))
);
create table public.conversation_members (
  conversation_id text not null references public.conversations (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role text not null check (role in ('admin', 'member')),
  since timestamptz not null default now(),
  primary key (conversation_id, user_id)
);
create table public.mls_messages (
  conversation_id text not null references public.conversations (id) on delete cascade,
  id text not null check (char_length(id) <= 64),
  sender uuid not null references auth.users (id),
  epoch integer not null,
  kind text not null check (kind in ('app', 'commit')),
  payload text not null check (char_length(payload) between 1 and 262144),
  ts timestamptz not null default now(),
  primary key (conversation_id, id)
);
create index mls_messages_ts on public.mls_messages (ts);
create table public.welcomes (
  id bigserial primary key,
  recipient uuid not null references auth.users (id) on delete cascade,
  conversation_id text not null references public.conversations (id) on delete cascade,
  sender uuid not null references auth.users (id),
  epoch integer not null,
  payload text not null check (char_length(payload) <= 1048576),
  ts timestamptz not null default now()
);

-- membership helpers (security definer: no RLS recursion)
create or replace function public.is_member(p_conv text, p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from conversation_members where conversation_id = p_conv and user_id = p_user)
$$;

create or replace function public.is_admin(p_conv text, p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from conversation_members where conversation_id = p_conv and user_id = p_user and role = 'admin')
$$;

alter table public.conversations enable row level security;
alter table public.conversation_members enable row level security;
alter table public.mls_messages enable row level security;
alter table public.welcomes enable row level security;

create policy conv_read on public.conversations for select to authenticated using (public.is_member(id));
create policy members_read on public.conversation_members for select to authenticated using (public.is_member(conversation_id));
create policy members_leave on public.conversation_members for delete to authenticated using (user_id = auth.uid());
create policy mls_read on public.mls_messages for select to authenticated using (public.is_member(conversation_id));
create policy welcomes_read on public.welcomes for select to authenticated using (recipient = auth.uid());
create policy welcomes_delete on public.welcomes for delete to authenticated using (recipient = auth.uid());
-- No insert/update policies: all writes go through the functions below.

create or replace function public.check_not_blocked(p_member uuid)
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if p_member <> auth.uid() and exists (select 1 from blocks where user_id = p_member and blocked_id = auth.uid()) then
    raise exception 'blocked';
  end if;
end $$;

create or replace function public.insert_welcomes(p_conv text, p_epoch integer, p_welcomes jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare w jsonb;
begin
  for w in select * from jsonb_array_elements(coalesce(p_welcomes, '[]'::jsonb)) loop
    if not is_member(p_conv, (w->>'recipient')::uuid) then raise exception 'welcome_for_non_member'; end if;
    insert into welcomes (recipient, conversation_id, sender, epoch, payload)
    values ((w->>'recipient')::uuid, p_conv, auth.uid(), p_epoch, w->>'payload');
  end loop;
end $$;

-- Creates a conversation with its first commit (epoch 1) atomically.
-- p_members: {"<uuid>": "admin"|"member", ...}; p_welcomes: [{"recipient": uuid, "payload": b64}]
create or replace function public.create_conversation(
  p_id text, p_type text, p_members jsonb, p_commit_id text, p_commit text, p_welcomes jsonb
) returns void language plpgsql security definer set search_path = public as $$
declare k text; v text;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if (p_members->>auth.uid()::text) is distinct from 'admin' then raise exception 'creator_must_be_admin'; end if;
  if p_type = 'direct' and (position(auth.uid()::text in p_id) = 0 or (select count(*) from jsonb_object_keys(p_members)) <> 2) then
    raise exception 'invalid_direct';
  end if;
  if exists (select 1 from conversations where id = p_id) then raise exception 'epoch_conflict'; end if;
  insert into conversations (id, type, created_by, epoch) values (p_id, p_type, auth.uid(), 1);
  for k, v in select * from jsonb_each_text(p_members) loop
    perform check_not_blocked(k::uuid);
    insert into conversation_members (conversation_id, user_id, role) values (p_id, k::uuid, v);
  end loop;
  insert into mls_messages (conversation_id, id, sender, epoch, kind, payload)
  values (p_id, p_commit_id, auth.uid(), 1, 'commit', p_commit);
  perform insert_welcomes(p_id, 1, p_welcomes);
end $$;

-- Epoch compare-and-set: succeeds only if the current epoch is p_epoch - 1.
-- p_member_changes: {"<uuid>": "member"|"admin"|null} (null removes).
create or replace function public.publish_commit(
  p_conv text, p_epoch integer, p_id text, p_payload text, p_member_changes jsonb, p_welcomes jsonb
) returns void language plpgsql security definer set search_path = public as $$
declare k text; v jsonb; conv_type text;
begin
  if not is_member(p_conv) then raise exception 'not_member'; end if;
  select type into conv_type from conversations where id = p_conv;
  if p_member_changes is not null and p_member_changes <> '{}'::jsonb then
    if not is_admin(p_conv) or conv_type <> 'group' then raise exception 'not_admin'; end if;
  end if;
  update conversations set epoch = p_epoch where id = p_conv and epoch = p_epoch - 1;
  if not found then raise exception 'epoch_conflict'; end if;
  for k, v in select * from jsonb_each(coalesce(p_member_changes, '{}'::jsonb)) loop
    if v = 'null'::jsonb then
      delete from conversation_members where conversation_id = p_conv and user_id = k::uuid;
    else
      perform check_not_blocked(k::uuid);
      insert into conversation_members (conversation_id, user_id, role) values (p_conv, k::uuid, v #>> '{}')
      on conflict (conversation_id, user_id) do update set role = excluded.role;
    end if;
  end loop;
  insert into mls_messages (conversation_id, id, sender, epoch, kind, payload)
  values (p_conv, p_id, auth.uid(), p_epoch, 'commit', p_payload);
  perform insert_welcomes(p_conv, p_epoch, p_welcomes);
end $$;

create or replace function public.publish_application(p_conv text, p_epoch integer, p_id text, p_payload text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_member(p_conv) then raise exception 'not_member'; end if;
  if (select epoch from conversations where id = p_conv) <> p_epoch then raise exception 'stale_epoch'; end if;
  insert into mls_messages (conversation_id, id, sender, epoch, kind, payload)
  values (p_conv, p_id, auth.uid(), p_epoch, 'app', p_payload);
end $$;

-- ---------------------------------------------------------------- push / backup
create table public.push_tokens (
  user_id uuid not null references auth.users (id) on delete cascade,
  device_id text not null,
  token text not null check (char_length(token) <= 4096),
  platform text not null check (platform in ('android', 'ios')),
  updated_at timestamptz not null default now(),
  primary key (user_id, device_id)
);
create table public.backups (
  user_id uuid primary key references auth.users (id) on delete cascade,
  blob text not null check (char_length(blob) <= 10000000),
  size integer not null check (size > 0),
  created_at timestamptz not null default now()
);
create table public.backup_shares (
  user_id uuid primary key references auth.users (id) on delete cascade,
  share text not null check (char_length(share) = 44),
  created_at timestamptz not null default now()
);
alter table public.push_tokens enable row level security;
alter table public.backups enable row level security;
alter table public.backup_shares enable row level security;
create policy push_own on public.push_tokens for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy backups_own on public.backups for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy shares_own on public.backup_shares for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ---------------------------------------------------------------- grants
revoke all on all tables in schema public from anon;
revoke execute on all functions in schema public from anon, public;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on function
  public.claim_nickname(text, text), public.find_profile_by_nickname(text), public.get_profile(uuid),
  public.claim_key_package(uuid), public.create_conversation(text, text, jsonb, text, text, jsonb),
  public.publish_commit(text, integer, text, text, jsonb, jsonb), public.publish_application(text, integer, text, text),
  public.is_member(text, uuid), public.is_admin(text, uuid)
to authenticated;

-- ---------------------------------------------------------------- realtime & retention
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.mls_messages, public.welcomes,
      public.conversation_members, public.conversations;
  end if;
end $$;

-- 30-day retention of opaque envelopes and welcomes (pg_cron, if enabled).
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('prune-envelopes', '17 3 * * *',
      $q$delete from public.mls_messages where ts < now() - interval '30 days';
         delete from public.welcomes where ts < now() - interval '30 days'$q$);
  end if;
end $$;
