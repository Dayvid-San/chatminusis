-- R6: the backup server share is delivered only after a fresh login, every
-- delivery is logged for the owner, and the table is no longer readable directly.

create table public.backup_downloads (
  id bigserial primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  ts timestamptz not null default now()
);
create index backup_downloads_idx on public.backup_downloads (user_id, ts);
alter table public.backup_downloads enable row level security;
create policy downloads_read on public.backup_downloads for select to authenticated using (user_id = auth.uid());
-- no insert/update/delete policy: the trail cannot be written or erased by clients
grant select on public.backup_downloads to authenticated;
grant usage, select on sequence public.backup_downloads_id_seq to authenticated;

-- Writable by the owner, never readable: only get_backup_share() returns it.
drop policy if exists shares_own on public.backup_shares;
create policy shares_insert on public.backup_shares for insert to authenticated with check (user_id = auth.uid());
create policy shares_update on public.backup_shares for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy shares_delete on public.backup_shares for delete to authenticated using (user_id = auth.uid());

-- Seconds since the account last authenticated with a password/OTP, from the
-- JWT's `amr` claim (Supabase records each method with its timestamp).
create or replace function public.seconds_since_login()
returns bigint language sql stable set search_path = public as $$
  select extract(epoch from now())::bigint - coalesce(
    (select max((a->>'timestamp')::bigint)
       from jsonb_array_elements(coalesce(auth.jwt()->'amr', '[]'::jsonb)) a
      where a->>'method' in ('password', 'otp', 'magiclink')), 0)
$$;

create or replace function public.get_backup_share()
returns text language plpgsql security definer set search_path = public as $$
declare v text;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if seconds_since_login() > 300 then raise exception 'reauth_required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('backup-share:' || auth.uid()::text, 0));
  if (select count(*) from backup_downloads where user_id = auth.uid() and ts > now() - interval '1 hour') >= 5 then
    raise exception 'rate_limited';
  end if;
  select share into v from backup_shares where user_id = auth.uid();
  if v is not null then insert into backup_downloads (user_id) values (auth.uid()); end if;
  return v;
end $$;
revoke execute on function public.get_backup_share() from public, anon;
grant execute on function public.get_backup_share() to authenticated;
revoke execute on function public.seconds_since_login() from public, anon;
grant execute on function public.seconds_since_login() to authenticated;
