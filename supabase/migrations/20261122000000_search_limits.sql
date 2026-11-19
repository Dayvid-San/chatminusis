-- R5: exact-nickname lookup with a per-user rate limit enforced by the server.
-- Not found, yourself, and "blocked you" are indistinguishable; every lookup counts.

create table public.search_log (
  searcher uuid not null references auth.users (id) on delete cascade,
  ts timestamptz not null default now()
);
create index search_log_idx on public.search_log (searcher, ts);
alter table public.search_log enable row level security; -- no policies: server-only
revoke all on public.search_log from authenticated, anon;

create or replace function public.find_profile_by_nickname(p_nickname text)
returns table (id uuid, nickname text, display_name text)
language plpgsql security definer set search_path = public as $$
declare found profiles%rowtype;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if p_nickname !~ '^[a-z0-9_.]{3,20}$' or p_nickname ~ '^\.|\.$|\.\.' then raise exception 'invalid_argument'; end if;
  perform pg_advisory_xact_lock(hashtextextended('search:' || auth.uid()::text, 0));
  if (select count(*) from search_log where searcher = auth.uid() and ts > now() - interval '1 hour') >= 30 then
    raise exception 'rate_limited';
  end if;
  insert into search_log (searcher) values (auth.uid());

  select * into found from profiles where profiles.nickname = p_nickname;
  if found.id is null or found.id = auth.uid() then return; end if;
  if exists (select 1 from blocks b where b.user_id = found.id and b.blocked_id = auth.uid()) then return; end if;
  return query select found.id, found.nickname, found.display_name;
end $$;

create or replace function public.prune_old_data()
returns void language sql security definer set search_path = public as $$
  delete from mls_messages
   where (kind = 'app' and ts < now() - interval '30 days')
      or (kind = 'commit' and ts < now() - interval '180 days');
  delete from welcomes where ts < now() - interval '30 days';
  delete from key_package_claims where ts < now() - interval '1 day';
  delete from search_log where ts < now() - interval '1 day';
$$;
revoke execute on function public.prune_old_data() from public, anon, authenticated;
grant execute on function public.find_profile_by_nickname(text) to authenticated;
