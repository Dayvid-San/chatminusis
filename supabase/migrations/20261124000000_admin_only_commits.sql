-- R3: only admins publish commits; ordinary members send proposals instead.
-- The server cannot read an MLS commit, but it knows who is an admin, which is
-- enough to stop an ordinary member from changing the group's membership.

alter table public.mls_messages drop constraint if exists mls_messages_kind_check;
alter table public.mls_messages add constraint mls_messages_kind_check check (kind in ('app', 'commit', 'proposal'));

-- Any commit (not only those that change members) needs admin rights.
create or replace function public.publish_commit(
  p_conv text, p_epoch integer, p_id text, p_payload text, p_member_changes jsonb, p_welcomes jsonb
) returns void language plpgsql security definer set search_path = public as $$
declare k text; v jsonb;
begin
  if not is_member(p_conv) then raise exception 'not_member'; end if;
  if not is_admin(p_conv) then raise exception 'not_admin'; end if;
  if p_member_changes is not null and p_member_changes <> '{}'::jsonb
     and (select type from conversations where id = p_conv) <> 'group' then
    raise exception 'not_admin';
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

-- A member's own key-rotation request: valid only for the current epoch.
create or replace function public.publish_proposal(p_conv text, p_epoch integer, p_id text, p_payload text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_member(p_conv) then raise exception 'not_member'; end if;
  if (select epoch from conversations where id = p_conv) <> p_epoch then raise exception 'stale_epoch'; end if;
  insert into mls_messages (conversation_id, id, sender, epoch, kind, payload)
  values (p_conv, p_id, auth.uid(), p_epoch, 'proposal', p_payload);
end $$;
revoke execute on function public.publish_proposal(text, integer, text, text) from public, anon;
grant execute on function public.publish_proposal(text, integer, text, text) to authenticated;
