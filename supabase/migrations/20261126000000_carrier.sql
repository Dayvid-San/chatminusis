-- Carrier model: the server only carries sealed envelopes and forgets them as
-- soon as every member received them. Nothing is kept as history.
--
--  * each envelope records who has not received it yet (`pending`), computed by
--    the server at publication, never by the client
--  * every recipient confirms receipt with ack_envelope(); clients cannot delete
--  * the envelope is deleted when no CURRENT member is still pending
--  * people who leave/are removed stop holding messages back (trigger)
--  * the first commit of a conversation is not stored (invitees use their Welcome)
--  * safety net: undelivered envelopes and welcomes are dropped after 7 days

alter table public.mls_messages add column if not exists pending uuid[] not null default '{}';

-- Defence in depth: clients can only READ envelopes. Everything else goes through the
-- functions below (publish_*, ack_envelope), so nobody can delete or alter one by hand.
revoke insert, update, delete on public.mls_messages from authenticated;

-- Everyone in the conversation right now except the caller.
create or replace function public.other_members(p_conv text)
returns uuid[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(user_id), '{}') from conversation_members
   where conversation_id = p_conv and user_id <> auth.uid()
$$;

-- Deletes envelopes of a conversation that no current member is still waiting for.
create or replace function public.settle_conversation(p_conv text)
returns void language sql security definer set search_path = public as $$
  delete from mls_messages m
   where m.conversation_id = p_conv
     and not exists (
       select 1 from conversation_members cm
        where cm.conversation_id = p_conv and cm.user_id = any (m.pending)
     )
$$;
revoke execute on function public.settle_conversation(text) from public, anon, authenticated;

-- "I stored it": removes the caller from the waiting list and deletes the
-- envelope if nobody else is waiting.
create or replace function public.ack_envelope(p_conv text, p_id text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if not is_member(p_conv) then raise exception 'not_member'; end if;
  update mls_messages set pending = array_remove(pending, auth.uid())
   where conversation_id = p_conv and id = p_id;
  perform settle_conversation(p_conv);
end $$;
revoke execute on function public.ack_envelope(text, text) from public, anon;
grant execute on function public.ack_envelope(text, text) to authenticated;

-- A member left or was removed: what was only waiting for them can go.
create or replace function public.after_member_gone()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform settle_conversation(old.conversation_id);
  return old;
end $$;
drop trigger if exists member_gone on public.conversation_members;
create trigger member_gone after delete on public.conversation_members
  for each row execute function public.after_member_gone();

-- ------------------------------------------------ publishing (pending computed here)

create or replace function public.publish_application(p_conv text, p_epoch integer, p_id text, p_payload text)
returns void language plpgsql security definer set search_path = public as $$
declare recipients uuid[];
begin
  if not is_member(p_conv) then raise exception 'not_member'; end if;
  if (select epoch from conversations where id = p_conv) <> p_epoch then raise exception 'stale_epoch'; end if;
  recipients := other_members(p_conv);
  if cardinality(recipients) = 0 then return; end if; -- nobody to carry it to
  insert into mls_messages (conversation_id, id, sender, epoch, kind, payload, pending)
  values (p_conv, p_id, auth.uid(), p_epoch, 'app', p_payload, recipients);
end $$;

create or replace function public.publish_proposal(p_conv text, p_epoch integer, p_id text, p_payload text)
returns void language plpgsql security definer set search_path = public as $$
declare recipients uuid[];
begin
  if not is_member(p_conv) then raise exception 'not_member'; end if;
  if (select epoch from conversations where id = p_conv) <> p_epoch then raise exception 'stale_epoch'; end if;
  recipients := other_members(p_conv);
  if cardinality(recipients) = 0 then return; end if;
  insert into mls_messages (conversation_id, id, sender, epoch, kind, payload, pending)
  values (p_conv, p_id, auth.uid(), p_epoch, 'proposal', p_payload, recipients);
end $$;

create or replace function public.publish_commit(
  p_conv text, p_epoch integer, p_id text, p_payload text, p_member_changes jsonb, p_welcomes jsonb
) returns void language plpgsql security definer set search_path = public as $$
declare k text; v jsonb; recipients uuid[];
begin
  if not is_member(p_conv) then raise exception 'not_member'; end if;
  if not is_admin(p_conv) then raise exception 'not_admin'; end if;
  if p_member_changes is not null and p_member_changes <> '{}'::jsonb
     and (select type from conversations where id = p_conv) <> 'group' then
    raise exception 'not_admin';
  end if;
  update conversations set epoch = p_epoch where id = p_conv and epoch = p_epoch - 1;
  if not found then raise exception 'epoch_conflict'; end if;
  -- The commit is for the people who are members NOW (new members join by Welcome).
  recipients := other_members(p_conv);
  for k, v in select * from jsonb_each(coalesce(p_member_changes, '{}'::jsonb)) loop
    if v = 'null'::jsonb then
      delete from conversation_members where conversation_id = p_conv and user_id = k::uuid;
    else
      perform check_not_blocked(k::uuid);
      insert into conversation_members (conversation_id, user_id, role) values (p_conv, k::uuid, v #>> '{}')
      on conflict (conversation_id, user_id) do update set role = excluded.role;
    end if;
  end loop;
  if cardinality(recipients) > 0 then
    insert into mls_messages (conversation_id, id, sender, epoch, kind, payload, pending)
    values (p_conv, p_id, auth.uid(), p_epoch, 'commit', p_payload, recipients);
  end if;
  perform insert_welcomes(p_conv, p_epoch, p_welcomes);
  perform settle_conversation(p_conv);
end $$;

-- Creating a conversation stores no envelope: invitees join through their Welcome.
drop function if exists public.create_conversation(text, text, jsonb, text, text, jsonb);
create or replace function public.create_conversation(p_id text, p_type text, p_members jsonb, p_welcomes jsonb)
returns void language plpgsql security definer set search_path = public as $$
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
  perform insert_welcomes(p_id, 1, p_welcomes);
end $$;
revoke execute on function public.create_conversation(text, text, jsonb, jsonb) from public, anon;
grant execute on function public.create_conversation(text, text, jsonb, jsonb) to authenticated;

-- ------------------------------------------------ retention: 7 days, everything
create or replace function public.prune_old_data()
returns void language sql security definer set search_path = public as $$
  delete from mls_messages where ts < now() - interval '7 days';
  delete from welcomes where ts < now() - interval '7 days';
  delete from key_package_claims where ts < now() - interval '1 day';
  delete from search_log where ts < now() - interval '1 day';
$$;
revoke execute on function public.prune_old_data() from public, anon, authenticated;
