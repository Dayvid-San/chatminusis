-- Carrier model: the server holds no history and no backups. Messages live only
-- on the users' devices; if a device is lost, so is its history.
-- Drops everything the server-held backup added.

drop function if exists public.get_backup_share();
drop function if exists public.seconds_since_login();
drop table if exists public.backup_downloads cascade;
drop table if exists public.backup_shares cascade;
drop table if exists public.backups cascade;
