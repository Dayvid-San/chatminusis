-- Retention (R7): opaque messages are kept 30 days, but commits 180 days, so
-- members who were offline for a while can still catch up. Beyond that they
-- rejoin the conversation automatically.
create or replace function public.prune_old_data()
returns void language sql security definer set search_path = public as $$
  delete from mls_messages
   where (kind = 'app' and ts < now() - interval '30 days')
      or (kind = 'commit' and ts < now() - interval '180 days');
  delete from welcomes where ts < now() - interval '30 days';
$$;
revoke execute on function public.prune_old_data() from public, anon, authenticated;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('prune-envelopes');
    perform cron.schedule('prune-old-data', '17 3 * * *', 'select public.prune_old_data()');
  end if;
exception when others then
  null; -- job from the first migration may not exist
end $$;
