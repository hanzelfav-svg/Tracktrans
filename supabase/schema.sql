-- Tracktrans Supabase schema and RLS
-- Run this in the Supabase SQL editor before enabling the Supabase client.

create extension if not exists pgcrypto;

do $$ begin
  create type public.app_role as enum ('owner', 'staff');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.membership_status as enum ('active', 'inactive', 'revoked');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.invitation_status as enum ('pending', 'accepted', 'expired', 'revoked');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.edit_request_status as enum ('pending', 'approved', 'rejected');
exception when duplicate_object then null; end $$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  email text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, email)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1)), new.email)
  on conflict (id) do update set email = excluded.email;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create table if not exists public.businesses (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  description text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.business_members (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role public.app_role not null default 'staff',
  status public.membership_status not null default 'active',
  invited_by uuid references public.profiles(id) on delete set null,
  joined_at timestamptz not null default now(),
  unique (business_id, user_id)
);

create table if not exists public.invitations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  invited_email text,
  token_hash text not null unique,
  role public.app_role not null default 'staff' check (role = 'staff'),
  status public.invitation_status not null default 'pending',
  created_by uuid not null references public.profiles(id) on delete cascade,
  used_by uuid references public.profiles(id) on delete set null,
  accepted_at timestamptz,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

alter table public.invitations add column if not exists accepted_at timestamptz;

create table if not exists public.transactions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  created_by uuid not null references public.profiles(id) on delete restrict,
  type text not null check (type in ('income', 'expense')),
  description text not null check (length(trim(description)) > 0),
  amount bigint not null check (amount > 0),
  transaction_date timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.transaction_edit_requests (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid not null references public.transactions(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  requested_by uuid not null references public.profiles(id) on delete restrict,
  old_data jsonb not null,
  requested_data jsonb not null,
  reason text not null,
  status public.edit_request_status not null default 'pending',
  reviewed_by uuid references public.profiles(id) on delete set null,
  review_note text,
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.attendance (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete restrict,
  date date not null default (timezone('Asia/Jakarta', now()))::date,
  check_in_at timestamptz,
  check_in_photo text,
  check_out_at timestamptz,
  check_out_photo text,
  status text not null default 'Hadir' check (status in ('Hadir', 'Terlambat', 'Izin', 'Tidak Hadir')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.attendance add column if not exists date date;
alter table public.attendance add column if not exists check_in_at timestamptz;
alter table public.attendance add column if not exists check_in_photo text;
alter table public.attendance add column if not exists check_out_at timestamptz;
alter table public.attendance add column if not exists check_out_photo text;
update public.attendance set date = coalesce(date, (timezone('Asia/Jakarta', now()))::date) where date is null;
alter table public.attendance alter column date set default (timezone('Asia/Jakarta', now()))::date;
alter table public.attendance alter column date set not null;
do $$ begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'attendance' and column_name = 'check_in') then
    execute 'update public.attendance set check_in_at = coalesce(check_in_at, check_in)';
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'attendance' and column_name = 'photo_check_in') then
    execute 'update public.attendance set check_in_photo = coalesce(check_in_photo, photo_check_in)';
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'attendance' and column_name = 'check_out') then
    execute 'update public.attendance set check_out_at = coalesce(check_out_at, check_out)';
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'attendance' and column_name = 'photo_check_out') then
    execute 'update public.attendance set check_out_photo = coalesce(check_out_photo, photo_check_out)';
  end if;
end $$;

create unique index if not exists attendance_one_open_session
  on public.attendance (business_id, user_id, date)
  where check_in_at is not null and check_out_at is null;

create index if not exists businesses_owner_id_idx on public.businesses (owner_id);
create index if not exists business_members_user_business_idx on public.business_members (user_id, business_id, status);
create index if not exists transactions_business_date_idx on public.transactions (business_id, transaction_date desc);
create index if not exists transactions_business_creator_idx on public.transactions (business_id, created_by);
create index if not exists edit_requests_business_status_idx on public.transaction_edit_requests (business_id, status, created_at desc);
create index if not exists attendance_business_date_idx on public.attendance (business_id, date desc);

create table if not exists public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  business_id uuid references public.businesses(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete restrict,
  action text not null,
  entity_type text not null,
  entity_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  old_value jsonb,
  new_value jsonb,
  created_at timestamptz not null default now()
);

alter table public.audit_logs add column if not exists metadata jsonb not null default '{}'::jsonb;

create or replace function public.accept_invitation(p_token_hash text)
returns public.business_members
language plpgsql
security definer
set search_path = public
as $$
declare
  invite public.invitations;
  membership public.business_members;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  select * into invite
  from public.invitations
  where token_hash = p_token_hash
    and status = 'pending'
    and expires_at > now()
  for update;

  if not found then
    raise exception 'Invitation is invalid, expired, or already used';
  end if;

  insert into public.business_members (business_id, user_id, role, status, invited_by)
  values (invite.business_id, auth.uid(), invite.role, 'active', invite.created_by)
  on conflict (business_id, user_id) do update set status = 'active', role = excluded.role
  returning * into membership;

  update public.invitations
  set status = 'accepted', used_by = auth.uid(), accepted_at = now()
  where id = invite.id;

  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, metadata)
  values (invite.business_id, auth.uid(), 'invitation_accepted', 'invitation', invite.id, jsonb_build_object('invited_by', invite.created_by));

  return membership;
end;
$$;

create or replace function public.create_business(p_name text, p_description text default null)
returns public.businesses
language plpgsql security definer set search_path = public
as $$
declare created public.businesses;
begin
  if auth.uid() is null or length(trim(coalesce(p_name, ''))) = 0 then
    raise exception 'Authenticated user and business name are required';
  end if;
  insert into public.businesses (owner_id, name, description)
  values (auth.uid(), trim(p_name), p_description)
  returning * into created;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, metadata)
  values (created.id, auth.uid(), 'business_created', 'business', created.id, jsonb_build_object('name', created.name));
  return created;
end;
$$;
revoke all on function public.create_business(text, text) from public;
grant execute on function public.create_business(text, text) to authenticated;

create or replace function public.create_invitation(p_business_id uuid, p_token_hash text, p_invited_email text default null, p_expires_at timestamptz default now() + interval '7 days')
returns public.invitations
language plpgsql security definer set search_path = public
as $$
declare created public.invitations;
begin
  if not public.is_business_owner(p_business_id) then
    raise exception 'Only the business owner can create invitations';
  end if;
  insert into public.invitations (business_id, invited_email, token_hash, created_by, expires_at)
  values (p_business_id, lower(nullif(trim(p_invited_email), '')), p_token_hash, auth.uid(), least(p_expires_at, now() + interval '7 days'))
  returning * into created;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, metadata)
  values (p_business_id, auth.uid(), 'invitation_created', 'invitation', created.id, jsonb_build_object('expires_at', created.expires_at));
  return created;
end;
$$;
revoke all on function public.create_invitation(uuid, text, text, timestamptz) from public;
grant execute on function public.create_invitation(uuid, text, text, timestamptz) to authenticated;

create or replace function public.review_transaction_edit(p_request_id uuid, p_status public.edit_request_status, p_review_note text default null)
returns public.transaction_edit_requests
language plpgsql security definer set search_path = public
as $$
declare request_row public.transaction_edit_requests;
declare updated_request public.transaction_edit_requests;
begin
  select * into request_row from public.transaction_edit_requests where id = p_request_id for update;
  if not found or not public.is_business_owner(request_row.business_id) or request_row.status <> 'pending' then
    raise exception 'Edit request is invalid or not reviewable';
  end if;
  if p_status not in ('approved', 'rejected') then
    raise exception 'Review status must be approved or rejected';
  end if;
  if p_status = 'approved' then
    update public.transactions
    set type = request_row.requested_data->>'type',
        description = request_row.requested_data->>'description',
        amount = (request_row.requested_data->>'amount')::bigint,
        updated_at = now()
    where id = request_row.transaction_id and business_id = request_row.business_id;
    if not found then raise exception 'Transaction no longer exists'; end if;
  end if;
  update public.transaction_edit_requests
  set status = p_status, reviewed_by = auth.uid(), reviewed_at = now(), review_note = p_review_note
  where id = p_request_id
  returning * into updated_request;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, metadata, old_value, new_value)
  values (request_row.business_id, auth.uid(), 'transaction_edit_' || p_status::text, 'transaction_edit_request', p_request_id, jsonb_build_object('transaction_id', request_row.transaction_id, 'review_note', p_review_note), request_row.old_data, request_row.requested_data);
  return updated_request;
end;
$$;
revoke all on function public.review_transaction_edit(uuid, public.edit_request_status, text) from public;
grant execute on function public.review_transaction_edit(uuid, public.edit_request_status, text) to authenticated;

create or replace function public.check_in(p_business_id uuid, p_photo_path text default null)
returns public.attendance
language plpgsql security definer set search_path = public
as $$
declare created public.attendance;
begin
  if not public.is_active_staff_member(p_business_id) then raise exception 'Active staff membership required'; end if;
  insert into public.attendance (business_id, user_id, date, check_in_at, check_in_photo)
  values (p_business_id, auth.uid(), (timezone('Asia/Jakarta', now()))::date, now(), p_photo_path)
  returning * into created;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, metadata)
  values (p_business_id, auth.uid(), 'attendance_check_in', 'attendance', created.id, jsonb_build_object('photo_path', p_photo_path));
  return created;
exception when unique_violation then
  raise exception 'An active attendance session already exists for today';
end;
$$;
revoke all on function public.check_in(uuid, text) from public;
grant execute on function public.check_in(uuid, text) to authenticated;

create or replace function public.check_out(p_attendance_id uuid, p_photo_path text default null)
returns public.attendance
language plpgsql security definer set search_path = public
as $$
declare updated public.attendance;
begin
  update public.attendance
  set check_out_at = now(), check_out_photo = p_photo_path, updated_at = now()
  where id = p_attendance_id and user_id = auth.uid() and check_in_at is not null and check_out_at is null;
  if not found then raise exception 'Attendance session is invalid or already closed'; end if;
  select * into updated from public.attendance where id = p_attendance_id;
  insert into public.audit_logs (business_id, user_id, action, entity_type, entity_id, metadata)
  values (updated.business_id, auth.uid(), 'attendance_check_out', 'attendance', updated.id, jsonb_build_object('photo_path', p_photo_path));
  return updated;
end;
$$;
revoke all on function public.check_out(uuid, text) from public;
grant execute on function public.check_out(uuid, text) to authenticated;

revoke all on function public.accept_invitation(text) from public;
grant execute on function public.accept_invitation(text) to authenticated;

create or replace function public.is_business_owner(target_business uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.businesses
    where id = target_business and owner_id = auth.uid()
  );
$$;
revoke all on function public.is_business_owner(uuid) from public;
grant execute on function public.is_business_owner(uuid) to authenticated;

create or replace function public.is_active_business_member(target_business uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_business_owner(target_business)
  or exists (
    select 1 from public.business_members
    where business_id = target_business and user_id = auth.uid() and status = 'active'
  );
$$;
revoke all on function public.is_active_business_member(uuid) from public;
grant execute on function public.is_active_business_member(uuid) to authenticated;

create or replace function public.is_active_staff_member(target_business uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.business_members
    where business_id = target_business and user_id = auth.uid() and role = 'staff' and status = 'active'
  );
$$;
revoke all on function public.is_active_staff_member(uuid) from public;
grant execute on function public.is_active_staff_member(uuid) to authenticated;

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.protect_staff_attendance_update()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.is_business_owner(old.business_id) then
    return new;
  end if;
  if old.user_id <> auth.uid()
     or new.user_id <> old.user_id
     or new.business_id <> old.business_id
    or new.date <> old.date
    or new.check_in_at <> old.check_in_at
    or new.check_in_photo is distinct from old.check_in_photo
     or new.created_at <> old.created_at then
    raise exception 'Staff may only complete their own active attendance session';
  end if;
  return new;
end;
$$;

drop trigger if exists protect_staff_attendance_update on public.attendance;
create trigger protect_staff_attendance_update
  before update on public.attendance
  for each row execute function public.protect_staff_attendance_update();

do $$ declare table_name text; begin
  foreach table_name in array array['profiles','businesses','transactions','attendance'] loop
    execute format('drop trigger if exists %I_updated_at on public.%I', table_name, table_name);
    execute format('create trigger %I_updated_at before update on public.%I for each row execute function public.touch_updated_at()', table_name, table_name);
  end loop;
end $$;

alter table public.profiles enable row level security;
alter table public.businesses enable row level security;
alter table public.business_members enable row level security;
alter table public.invitations enable row level security;
alter table public.transactions enable row level security;
alter table public.transaction_edit_requests enable row level security;
alter table public.attendance enable row level security;
alter table public.audit_logs enable row level security;

drop policy if exists profiles_self_select on public.profiles;
create policy profiles_self_select on public.profiles for select using (id = auth.uid());

drop policy if exists profiles_self_update on public.profiles;
create policy profiles_self_update on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists businesses_member_select on public.businesses;
create policy businesses_member_select on public.businesses for select using (public.is_active_business_member(id));

drop policy if exists businesses_owner_insert on public.businesses;
create policy businesses_owner_insert on public.businesses for insert with check (owner_id = auth.uid());

drop policy if exists businesses_owner_update on public.businesses;
create policy businesses_owner_update on public.businesses for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists businesses_owner_delete on public.businesses;
create policy businesses_owner_delete on public.businesses for delete using (owner_id = auth.uid());

drop policy if exists members_member_select on public.business_members;
create policy members_member_select on public.business_members for select using (user_id = auth.uid() or public.is_business_owner(business_id));

drop policy if exists members_owner_manage on public.business_members;
create policy members_owner_manage on public.business_members for update using (public.is_business_owner(business_id)) with check (public.is_business_owner(business_id) and role = 'staff');

drop policy if exists invitations_owner_manage on public.invitations;
create policy invitations_owner_select on public.invitations for select using (public.is_business_owner(business_id));
create policy invitations_owner_revoke on public.invitations for update using (public.is_business_owner(business_id)) with check (public.is_business_owner(business_id) and status = 'revoked');

drop policy if exists transactions_owner_select on public.transactions;
create policy transactions_owner_select on public.transactions for select using (public.is_business_owner(business_id));

drop policy if exists transactions_staff_select_own on public.transactions;
create policy transactions_staff_select_own on public.transactions for select using (public.is_active_staff_member(business_id) and created_by = auth.uid());

drop policy if exists transactions_owner_insert on public.transactions;
create policy transactions_owner_insert on public.transactions for insert with check (public.is_business_owner(business_id) and created_by = auth.uid());

drop policy if exists transactions_staff_insert on public.transactions;
create policy transactions_staff_insert on public.transactions for insert with check (public.is_active_staff_member(business_id) and created_by = auth.uid());

drop policy if exists transactions_owner_update on public.transactions;
create policy transactions_owner_update on public.transactions for update using (public.is_business_owner(business_id)) with check (public.is_business_owner(business_id));

drop policy if exists transactions_owner_delete on public.transactions;
create policy transactions_owner_delete on public.transactions for delete using (public.is_business_owner(business_id));

drop policy if exists edit_requests_member_select on public.transaction_edit_requests;
create policy edit_requests_member_select on public.transaction_edit_requests for select using (requested_by = auth.uid() or public.is_business_owner(business_id));

drop policy if exists edit_requests_staff_insert on public.transaction_edit_requests;
create policy edit_requests_staff_insert on public.transaction_edit_requests for insert with check (public.is_active_staff_member(business_id) and requested_by = auth.uid());

drop policy if exists edit_requests_owner_update on public.transaction_edit_requests;
-- Approval status changes are only allowed through review_transaction_edit().

drop policy if exists attendance_owner_select on public.attendance;
create policy attendance_owner_select on public.attendance for select using (public.is_business_owner(business_id));

drop policy if exists attendance_staff_select_own on public.attendance;
create policy attendance_staff_select_own on public.attendance for select using (public.is_active_staff_member(business_id) and user_id = auth.uid());

drop policy if exists attendance_member_insert on public.attendance;
drop policy if exists attendance_owner_update on public.attendance;
drop policy if exists attendance_staff_update_own on public.attendance;
-- Attendance mutations are only allowed through check_in()/check_out().

drop policy if exists audit_member_select on public.audit_logs;
create policy audit_member_select on public.audit_logs for select using (public.is_business_owner(business_id) or user_id = auth.uid());

drop policy if exists audit_member_insert on public.audit_logs;
create policy audit_member_insert on public.audit_logs for insert with check (user_id = auth.uid() and (business_id is null or public.is_active_business_member(business_id)));

insert into storage.buckets (id, name, public) values ('attendance', 'attendance', false) on conflict (id) do nothing;

drop policy if exists attendance_storage_select on storage.objects;
create policy attendance_storage_select on storage.objects for select to authenticated using (
  bucket_id = 'attendance'
  and (public.is_active_business_member((storage.foldername(name))[1]::uuid))
  and (public.is_business_owner((storage.foldername(name))[1]::uuid) or (storage.foldername(name))[2] = auth.uid()::text)
);

drop policy if exists attendance_storage_insert on storage.objects;
create policy attendance_storage_insert on storage.objects for insert to authenticated with check (
  bucket_id = 'attendance'
  and (public.is_active_business_member((storage.foldername(name))[1]::uuid))
  and (storage.foldername(name))[2] = auth.uid()::text
);

drop policy if exists attendance_storage_delete on storage.objects;
create policy attendance_storage_delete on storage.objects for delete to authenticated using (
  bucket_id = 'attendance' and (storage.foldername(name))[2] = auth.uid()::text
);

-- Production note: invitation token hashing and acceptance should be performed
-- by an Edge Function or trusted server. Never put a service_role key in index.html.
