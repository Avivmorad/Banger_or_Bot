create extension if not exists pg_cron with schema pg_catalog;

create table private.rpc_rate_limits (
  user_id uuid not null references auth.users(id) on delete cascade,
  action text not null check (action ~ '^[a-z_]{1,40}$'),
  window_started_at timestamptz not null,
  request_count integer not null check (request_count > 0),
  primary key (user_id, action, window_started_at)
);

alter table private.rpc_rate_limits enable row level security;

create function private.enforce_rpc_rate_limit(
  p_user_id uuid,
  p_action text,
  p_limit integer,
  p_window interval
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_window_started_at timestamptz;
  v_request_count integer;
begin
  if p_user_id is null or p_limit < 1 or p_window <= interval '0 seconds' then
    raise exception using errcode = '22023', message = 'INVALID_RATE_LIMIT';
  end if;

  v_window_started_at := date_bin(
    p_window,
    clock_timestamp(),
    '2000-01-01 00:00:00+00'::timestamptz
  );

  insert into private.rpc_rate_limits (
    user_id,
    action,
    window_started_at,
    request_count
  )
  values (p_user_id, p_action, v_window_started_at, 1)
  on conflict (user_id, action, window_started_at)
  do update set request_count = private.rpc_rate_limits.request_count + 1
  returning request_count into v_request_count;

  if v_request_count > p_limit then
    raise exception using
      errcode = 'P0001',
      message = 'RATE_LIMITED',
      hint = 'Wait a few minutes before trying again.';
  end if;
end;
$$;

create or replace function private.create_room(
  p_nickname text,
  p_settings jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_user();
  v_nickname text := private.clean_nickname(p_nickname);
  v_room public.rooms;
  v_player public.players;
begin
  perform private.enforce_rpc_rate_limit(
    v_user_id,
    'create_room',
    5,
    interval '10 minutes'
  );

  v_room.code := private.generate_room_code();
  v_room.host_user_id := v_user_id;
  v_room := private.apply_settings(v_room, coalesce(p_settings, '{}'::jsonb));

  insert into public.rooms (
    code, host_user_id, round_count, round_duration_seconds, reveal_duration_seconds,
    negative_points, allow_answer_changes, music_volume, song_pack
  ) values (
    v_room.code, v_user_id, coalesce(v_room.round_count, 6),
    coalesce(v_room.round_duration_seconds, 20), coalesce(v_room.reveal_duration_seconds, 7),
    coalesce(v_room.negative_points, true), coalesce(v_room.allow_answer_changes, false),
    coalesce(v_room.music_volume, 0.80), coalesce(v_room.song_pack, 'demo')
  ) returning * into v_room;

  insert into public.players (room_id, user_id, nickname, is_ready)
  values (v_room.id, v_user_id, v_nickname, false)
  returning * into v_player;

  perform private.emit_event(v_room.id, 'room_created');
  return private.room_state(v_room.id, v_user_id);
end;
$$;

create or replace function private.join_room(p_code text, p_nickname text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_user();
  v_code text := private.clean_room_code(p_code);
  v_nickname text := private.clean_nickname(p_nickname);
  v_room public.rooms;
  v_existing public.players;
begin
  perform private.enforce_rpc_rate_limit(
    v_user_id,
    'join_room',
    20,
    interval '10 minutes'
  );

  select * into v_room
  from public.rooms
  where code = v_code and expires_at > clock_timestamp()
  for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'ROOM_NOT_FOUND';
  end if;

  select * into v_existing
  from public.players
  where room_id = v_room.id and user_id = v_user_id and left_at is null;
  if found then
    update public.players set last_seen_at = clock_timestamp() where id = v_existing.id;
    perform private.advance_room_locked(v_room.id);
    return private.room_state(v_room.id, v_user_id);
  end if;

  if v_room.phase <> 'lobby' then
    raise exception using errcode = 'P0001', message = 'GAME_ALREADY_STARTED';
  end if;
  if exists (
    select 1 from public.players
    where room_id = v_room.id and left_at is null and lower(nickname) = lower(v_nickname)
  ) then
    raise exception using errcode = 'P0001', message = 'NICKNAME_TAKEN';
  end if;
  if (
    select count(*)
    from public.players
    where room_id = v_room.id and left_at is null
  ) >= v_room.max_players then
    raise exception using errcode = 'P0001', message = 'ROOM_FULL';
  end if;

  insert into public.players (room_id, user_id, nickname)
  values (v_room.id, v_user_id, v_nickname);
  perform private.emit_event(v_room.id, 'player_joined');
  return private.room_state(v_room.id, v_user_id);
end;
$$;

create function private.cleanup_expired_game_data()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_rooms_deleted integer;
  v_rate_limits_deleted integer;
begin
  v_rooms_deleted := private.cleanup_expired_rooms();

  delete from private.rpc_rate_limits
  where window_started_at < clock_timestamp() - interval '1 day';
  get diagnostics v_rate_limits_deleted = row_count;

  return jsonb_build_object(
    'rooms_deleted', v_rooms_deleted,
    'rate_limits_deleted', v_rate_limits_deleted
  );
end;
$$;

revoke all on table private.rpc_rate_limits from public, anon, authenticated;
revoke all on function private.enforce_rpc_rate_limit(
  uuid,
  text,
  integer,
  interval
) from public, anon, authenticated;
revoke all on function private.cleanup_expired_game_data()
from public, anon, authenticated;

select cron.schedule(
  'cleanup-expired-game-data',
  '17 * * * *',
  'select private.cleanup_expired_game_data();'
);
