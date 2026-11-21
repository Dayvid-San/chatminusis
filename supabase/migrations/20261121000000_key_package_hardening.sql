-- R4: a drained KeyPackage pool must not lock anyone out of being invited.
--  * last-resort (reusable) key package per user, served when the pool is empty
--  * claims are rate limited per (claimer, target) and refused when blocked
--  * the pool is no longer deletable by third parties; only claim_key_package consumes it

create table public.last_resort_key_packages (
  user_id uuid primary key references auth.users (id) on delete cascade,
  key_package text not null check (char_length(key_package) <= 4000),
  updated_at timestamptz not null default now()
);
alter table public.last_resort_key_packages enable row level security;
create policy lr_own on public.last_resort_key_packages for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create table public.key_package_claims (
  claimer uuid not null references auth.users (id) on delete cascade,
  target uuid not null references auth.users (id) on delete cascade,
  ts timestamptz not null default now()
);
create index key_package_claims_idx on public.key_package_claims (claimer, target, ts);
alter table public.key_package_claims enable row level security; -- no policies: server-only
revoke all on public.key_package_claims from authenticated, anon;

create or replace function public.claim_key_package(p_user uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v text;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if p_user = auth.uid() then raise exception 'invalid_argument'; end if;
  if exists (select 1 from blocks where user_id = p_user and blocked_id = auth.uid()) then
    raise exception 'permission_denied';
  end if;
  -- Serialise claims of the same pair so the limit cannot be raced.
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text || ':' || p_user::text, 0));
  if (select count(*) from key_package_claims
       where claimer = auth.uid() and target = p_user and ts > now() - interval '1 hour') >= 10 then
    raise exception 'rate_limited';
  end if;
  insert into key_package_claims (claimer, target) values (auth.uid(), p_user);

  delete from key_packages where id = (
    select id from key_packages where user_id = p_user order by id limit 1 for update skip locked
  ) returning key_package into v;
  if v is null then
    select key_package into v from last_resort_key_packages where user_id = p_user;
  end if;
  return v;
end $$;

-- Third parties can no longer delete from the pool directly.
drop policy if exists kp_own_delete on public.key_packages;
create policy kp_own_delete on public.key_packages for delete to authenticated using (user_id = auth.uid());

create or replace function public.prune_claim_log()
returns void language sql security definer set search_path = public as $$
  delete from key_package_claims where ts < now() - interval '1 day';
$$;
revoke execute on function public.prune_claim_log() from public, anon, authenticated;

create or replace function public.prune_old_data()
returns void language sql security definer set search_path = public as $$
  delete from mls_messages
   where (kind = 'app' and ts < now() - interval '30 days')
      or (kind = 'commit' and ts < now() - interval '180 days');
  delete from welcomes where ts < now() - interval '30 days';
  delete from key_package_claims where ts < now() - interval '1 day';
$$;
revoke execute on function public.prune_old_data() from public, anon, authenticated;

grant select, insert, update, delete on public.last_resort_key_packages to authenticated;
