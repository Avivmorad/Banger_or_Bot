-- Dynamic, per-round track preparation with private Storage playback.

alter type public.room_phase add value if not exists 'preparing' after 'lobby';

alter table private.tracks
  add column provider text,
  add column provider_track_id text,
  add column storage_path text,
  add column source_url text,
  add column license_url text,
  add column genres text[] not null default '{}'::text[],
  add column content_sha256 text,
  add column last_used_at timestamptz;

update private.tracks
set
  provider = 'project',
  provider_track_id = public_id,
  source_url = 'https://github.com/Avivmorad/Banger-or-Bot/blob/main/client/public/audio/' || audio_filename,
  license_url = null
where provider is null;

alter table private.tracks
  alter column provider set not null,
  alter column provider_track_id set not null,
  alter column audio_filename drop not null,
  drop constraint if exists tracks_public_id_check,
  drop constraint if exists tracks_duration_seconds_check,
  drop constraint if exists tracks_audio_filename_check,
  add constraint tracks_provider_check
    check (provider in ('project', 'jamendo', 'suno')),
  add constraint tracks_duration_seconds_check
    check (duration_seconds between 5 and 3600),
  add constraint tracks_storage_path_check
    check (
      (provider = 'project' and audio_filename is not null)
      or (provider in ('jamendo', 'suno') and storage_path is not null)
    ),
  add constraint tracks_storage_path_format_check
    check (storage_path is null or storage_path ~ '^[0-9a-f-]{36}\.mp3$'),
  add constraint tracks_source_url_check
    check (source_url is null or source_url ~ '^https://'),
  add constraint tracks_license_url_check
    check (license_url is null or license_url ~ '^https://'),
  add constraint tracks_content_sha256_check
    check (content_sha256 is null or content_sha256 ~ '^[0-9a-f]{64}$');

alter table public.rooms alter column song_pack set default 'dynamic';

create unique index tracks_provider_id_idx
  on private.tracks (provider, provider_track_id);
create unique index tracks_content_sha256_idx
  on private.tracks (content_sha256)
  where content_sha256 is not null;
create index tracks_dynamic_selection_idx
  on private.tracks (provider, pack, correct_answer, enabled, last_used_at);

create table private.round_plans (
  round_id uuid primary key references public.rounds(id) on delete cascade,
  planned_answer public.answer_choice not null,
  created_at timestamptz not null default now()
);

create table private.round_preparations (
  round_id uuid primary key references public.rounds(id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending', 'preparing', 'ready', 'failed')),
  attempts integer not null default 0 check (attempts >= 0),
  lease_until timestamptz,
  last_error_code text,
  track_id uuid references private.tracks(id) on delete restrict,
  ready_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((status = 'ready') = (track_id is not null and ready_at is not null))
);

create table private.round_audio_ready (
  round_id uuid not null references public.rounds(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  ready_at timestamptz not null default now(),
  primary key (round_id, player_id)
);

create index round_preparations_track_idx
  on private.round_preparations (track_id);
create index round_audio_ready_player_idx
  on private.round_audio_ready (player_id, round_id);

-- Preserve games created before per-round preparation existed. Their hidden
-- selections are already authoritative, so promote them to ready preparations.
insert into private.round_plans (round_id, planned_answer)
select rs.round_id, t.correct_answer
from private.round_secrets rs
join private.tracks t on t.id = rs.track_id
on conflict (round_id) do nothing;

insert into private.round_preparations (
  round_id, status, track_id, ready_at
)
select rs.round_id, 'ready', rs.track_id, coalesce(r.starts_at, r.created_at)
from private.round_secrets rs
join public.rounds r on r.id = rs.round_id
on conflict (round_id) do nothing;

insert into private.round_preparations (round_id)
select r.id
from public.rounds r
where not exists (
  select 1 from private.round_preparations rp where rp.round_id = r.id
);

alter table private.round_plans enable row level security;
alter table private.round_preparations enable row level security;
alter table private.round_audio_ready enable row level security;

revoke all on private.round_plans from public, anon, authenticated;
revoke all on private.round_preparations from public, anon, authenticated;
revoke all on private.round_audio_ready from public, anon, authenticated;

create trigger round_preparations_set_updated_at
before update on private.round_preparations
for each row execute function private.set_updated_at();

insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
) values (
  'track-audio',
  'track-audio',
  false,
  52428800,
  array['audio/mpeg']::text[]
)
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create or replace function private.apply_settings(
  p_room public.rooms,
  p_settings jsonb
)
returns public.rooms
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  v_result public.rooms := p_room;
begin
  if p_settings ? 'round_count' then
    v_result.round_count := (p_settings ->> 'round_count')::integer;
  end if;
  if p_settings ? 'round_duration_seconds' then
    v_result.round_duration_seconds := (p_settings ->> 'round_duration_seconds')::integer;
  end if;
  if p_settings ? 'reveal_duration_seconds' then
    v_result.reveal_duration_seconds := (p_settings ->> 'reveal_duration_seconds')::integer;
  end if;
  if p_settings ? 'negative_points' then
    v_result.negative_points := (p_settings ->> 'negative_points')::boolean;
  end if;
  if p_settings ? 'allow_answer_changes' then
    v_result.allow_answer_changes := (p_settings ->> 'allow_answer_changes')::boolean;
  end if;
  if p_settings ? 'music_volume' then
    v_result.music_volume := (p_settings ->> 'music_volume')::numeric;
  end if;
  if p_settings ? 'song_pack' then
    v_result.song_pack := lower(trim(p_settings ->> 'song_pack'));
  end if;

  if v_result.round_count not between 3 and 12
     or v_result.round_duration_seconds not between 10 and 45
     or v_result.reveal_duration_seconds not between 4 and 15
     or v_result.music_volume not between 0 and 1
     or (v_result.song_pack is not null and v_result.song_pack not in ('dynamic', 'demo')) then
    raise exception using errcode = 'P0001', message = 'INVALID_SETTINGS';
  end if;
  return v_result;
exception
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception using errcode = 'P0001', message = 'INVALID_SETTINGS';
end;
$$;

create function private.balanced_round_plan(p_round_count integer)
returns table(round_number integer, planned_answer public.answer_choice)
language sql
volatile
security invoker
set search_path = ''
as $$
  with base as (
    select
      p_round_count / 2 as base_count,
      case
        when p_round_count % 2 = 1 and random() < 0.5 then 1
        else 0
      end as extra_real
    where p_round_count between 1 and 100
  ), counts as (
    select
      base_count + extra_real as real_count,
      p_round_count - base_count - extra_real as ai_count
    from base
  ), choices as (
    select 'real'::public.answer_choice as planned_answer
    from counts, generate_series(1, real_count)
    union all
    select 'ai'::public.answer_choice
    from counts, generate_series(1, ai_count)
  )
  select
    row_number() over (order by gen_random_uuid())::integer as round_number,
    planned_answer
  from choices;
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
    coalesce(v_room.music_volume, 0.80), coalesce(v_room.song_pack, 'dynamic')
  ) returning * into v_room;

  insert into public.players (room_id, user_id, nickname, is_ready)
  values (v_room.id, v_user_id, v_nickname, false)
  returning * into v_player;

  perform private.emit_event(v_room.id, 'room_created');
  return private.room_state(v_room.id, v_user_id);
end;
$$;

create or replace function private.get_room_state(p_code text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_user();
  v_room_id uuid;
begin
  select id into v_room_id
  from public.rooms
  where code = private.clean_room_code(p_code) and expires_at > clock_timestamp();
  if v_room_id is null then
    raise exception using errcode = 'P0001', message = 'ROOM_NOT_FOUND';
  end if;
  if not exists (
    select 1 from public.players
    where room_id = v_room_id and user_id = v_user_id and left_at is null
  ) then
    raise exception using errcode = 'P0001', message = 'NOT_IN_ROOM';
  end if;
  perform private.advance_room_locked(v_room_id);
  return private.room_state(v_room_id, v_user_id);
end;
$$;

create or replace function private.start_game(p_code text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_user();
  v_room public.rooms;
  v_game public.games;
  v_game_number integer;
begin
  select * into v_room
  from public.rooms
  where code = private.clean_room_code(p_code)
  for update;

  if not found then raise exception using errcode = 'P0001', message = 'ROOM_NOT_FOUND'; end if;
  if v_room.host_user_id <> v_user_id then raise exception using errcode = 'P0001', message = 'HOST_ONLY'; end if;
  if v_room.phase <> 'lobby' then raise exception using errcode = 'P0001', message = 'GAME_ALREADY_STARTED'; end if;
  update public.players set last_seen_at = clock_timestamp()
  where room_id = v_room.id and user_id = v_user_id and left_at is null;
  if not found then raise exception using errcode = 'P0001', message = 'NOT_IN_ROOM'; end if;
  if not exists (
    select 1 from public.players
    where room_id = v_room.id and left_at is null
  ) then
    raise exception using errcode = 'P0001', message = 'PLAYERS_NOT_READY';
  end if;
  if exists (
    select 1 from public.players
    where room_id = v_room.id and left_at is null
      and (not is_ready or last_seen_at <= clock_timestamp() - interval '30 seconds')
  ) then
    raise exception using errcode = 'P0001', message = 'PLAYERS_NOT_READY';
  end if;
  if v_room.song_pack = 'dynamic' and not exists (
    select 1 from private.tracks
    where provider = 'suno' and pack = 'dynamic' and enabled
  ) then
    raise exception using errcode = 'P0001', message = 'NOT_ENOUGH_AI_TRACKS';
  end if;
  if v_room.song_pack = 'demo' and (
    select count(distinct correct_answer) from private.tracks
    where provider = 'project' and pack = 'demo' and enabled
  ) < 2 then
    raise exception using errcode = 'P0001', message = 'NOT_ENOUGH_TRACKS';
  end if;

  select coalesce(max(game_number), 0) + 1 into v_game_number
  from public.games where room_id = v_room.id;
  insert into public.games (room_id, game_number)
  values (v_room.id, v_game_number)
  returning * into v_game;

  insert into public.scores (game_id, player_id)
  select v_game.id, id
  from public.players
  where room_id = v_room.id and left_at is null;

  insert into public.rounds (game_id, room_id, round_number)
  select v_game.id, v_room.id, number
  from generate_series(1, v_room.round_count) as number;

  insert into private.round_plans (round_id, planned_answer)
  select r.id, s.planned_answer
  from public.rounds r
  join private.balanced_round_plan(v_room.round_count) s
    on s.round_number = r.round_number
  where r.game_id = v_game.id;

  insert into private.round_preparations (round_id)
  select id from public.rounds where game_id = v_game.id;

  update public.rooms set
    current_game_id = v_game.id,
    current_round = 1,
    phase = 'preparing',
    phase_ends_at = null,
    started_at = clock_timestamp(),
    expires_at = clock_timestamp() + interval '6 hours'
  where id = v_room.id;
  update public.players set score = 0
  where room_id = v_room.id and left_at is null;

  perform private.emit_event(v_room.id, 'round_preparation_requested');
  return private.room_state(v_room.id, v_user_id);
end;
$$;

create or replace function private.advance_room_locked(p_room_id uuid)
returns void
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_room public.rooms;
  v_round public.rounds;
  v_preparation private.round_preparations;
  v_anchor timestamptz;
  v_start timestamptz;
  v_next_round integer;
  v_active_count integer;
  v_ready_count integer;
  v_iterations integer := 0;
begin
  select * into v_room from public.rooms where id = p_room_id for update;
  if not found then return; end if;

  perform private.transfer_host_if_needed(p_room_id, false);
  select * into v_room from public.rooms where id = p_room_id for update;

  loop
    exit when v_room.phase in ('lobby', 'finished') or v_iterations >= 20;
    v_iterations := v_iterations + 1;

    select * into v_round
    from public.rounds
    where game_id = v_room.current_game_id and round_number = v_room.current_round
    for update;

    if v_room.phase = 'preparing' then
      select * into v_preparation
      from private.round_preparations
      where round_id = v_round.id
      for update;

      select count(*) into v_active_count
      from public.players
      where room_id = p_room_id and left_at is null
        and last_seen_at > clock_timestamp() - interval '30 seconds';
      select count(*) into v_ready_count
      from private.round_audio_ready ar
      join public.players p on p.id = ar.player_id
      where ar.round_id = v_round.id
        and p.room_id = p_room_id and p.left_at is null
        and p.last_seen_at > clock_timestamp() - interval '30 seconds';

      if v_preparation.status <> 'ready'
         or v_active_count = 0
         or v_ready_count < v_active_count then
        exit;
      end if;

      v_start := clock_timestamp() + interval '4 seconds';
      update public.rounds set
        starts_at = v_start,
        deadline_at = v_start + make_interval(secs => v_room.round_duration_seconds),
        reveal_ends_at = v_start + make_interval(
          secs => v_room.round_duration_seconds + v_room.reveal_duration_seconds
        )
      where id = v_round.id;
      update public.rooms set
        phase = 'countdown',
        phase_ends_at = v_start
      where id = p_room_id;
      perform private.emit_event(p_room_id, 'countdown_started');

    elsif v_room.phase_ends_at is null or v_room.phase_ends_at > clock_timestamp() then
      exit;

    elsif v_room.phase = 'countdown' then
      update public.rounds set status = 'active' where id = v_round.id;
      update public.rooms set
        phase = 'playing',
        phase_ends_at = v_round.deadline_at
      where id = p_room_id;
      perform private.emit_event(p_room_id, 'round_started');

    elsif v_room.phase = 'playing' then
      perform private.score_round(v_round.id);
      update public.rooms set
        phase = 'reveal',
        phase_ends_at = v_round.reveal_ends_at
      where id = p_room_id;
      perform private.emit_event(p_room_id, 'round_revealed');

    elsif v_room.phase = 'reveal' then
      v_anchor := v_room.phase_ends_at;
      if v_room.current_round >= v_room.round_count then
        update public.rooms set
          phase = 'finished',
          phase_ends_at = null,
          expires_at = clock_timestamp() + interval '2 hours'
        where id = p_room_id;
        update public.games set
          status = 'finished',
          finished_at = clock_timestamp()
        where id = v_room.current_game_id;
        perform private.emit_event(p_room_id, 'game_finished');
      else
        update public.rooms set
          phase = 'intermission',
          phase_ends_at = v_anchor + interval '4 seconds'
        where id = p_room_id;
        perform private.emit_event(p_room_id, 'leaderboard');
      end if;

    elsif v_room.phase = 'intermission' then
      v_next_round := v_room.current_round + 1;
      update public.rooms set
        current_round = v_next_round,
        phase = 'preparing',
        phase_ends_at = null
      where id = p_room_id;
      perform private.emit_event(p_room_id, 'round_preparation_requested');
    end if;

    select * into v_room from public.rooms where id = p_room_id for update;
  end loop;
end;
$$;

create or replace function private.room_state(p_room_id uuid, p_user_id uuid)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_room public.rooms;
  v_me public.players;
  v_game public.games;
  v_round public.rounds;
  v_track private.tracks;
  v_preparation private.round_preparations;
  v_answer public.answers;
  v_players jsonb := '[]'::jsonb;
  v_leaderboard jsonb := '[]'::jsonb;
  v_round_history jsonb := '[]'::jsonb;
  v_submitted_count integer := 0;
  v_ready_count integer := 0;
  v_required_ready_count integer := 0;
  v_round_payload jsonb := null;
  v_revealed boolean := false;
begin
  select * into v_room from public.rooms where id = p_room_id;
  select * into v_me
  from public.players
  where room_id = p_room_id and user_id = p_user_id and left_at is null;
  if not found then
    raise exception using errcode = 'P0001', message = 'NOT_IN_ROOM';
  end if;

  if v_room.current_game_id is not null then
    select * into v_game from public.games where id = v_room.current_game_id;
    select * into v_round
    from public.rounds
    where game_id = v_room.current_game_id and round_number = v_room.current_round;

    if v_round.id is not null then
      select * into v_preparation
      from private.round_preparations where round_id = v_round.id;
      if v_preparation.track_id is not null then
        select * into v_track from private.tracks where id = v_preparation.track_id;
      end if;
      select * into v_answer
      from public.answers
      where round_id = v_round.id and player_id = v_me.id;
      select count(*) into v_submitted_count
      from public.answers where round_id = v_round.id;
      select count(*) into v_ready_count
      from private.round_audio_ready ar
      join public.players p on p.id = ar.player_id
      where ar.round_id = v_round.id and p.left_at is null
        and p.last_seen_at > clock_timestamp() - interval '30 seconds';
      select count(*) into v_required_ready_count
      from public.players p
      where p.room_id = p_room_id and p.left_at is null
        and p.last_seen_at > clock_timestamp() - interval '30 seconds';

      v_revealed := v_room.phase in ('reveal', 'intermission', 'finished');
      v_round_payload := jsonb_build_object(
        'id', v_round.id,
        'number', v_round.round_number,
        'total', v_room.round_count,
        'starts_at', v_round.starts_at,
        'deadline_at', v_round.deadline_at,
        'audio_url', case
          when v_track.storage_path is null and v_track.audio_filename is not null
            then '/audio/' || v_track.audio_filename
          else null
        end,
        'audio_available', v_preparation.status = 'ready',
        'audio_duration_seconds', v_track.duration_seconds,
        'preparation_status', coalesce(v_preparation.status, 'pending'),
        'preparation_error', v_preparation.last_error_code,
        'audio_ready_count', v_ready_count,
        'audio_required_count', v_required_ready_count,
        'submitted_count', v_submitted_count,
        'own_answer', case when v_answer.id is null then null else v_answer.choice end,
        'own_points', case when v_revealed then coalesce(v_answer.total_points, 0) else null end,
        'correct_answer', case when v_revealed then v_track.correct_answer else null end,
        'title', case when v_revealed then v_track.title else null end,
        'artist', case when v_revealed then v_track.artist else null end,
        'source_type', case when v_revealed then v_track.source_type else null end,
        'provider', case when v_revealed then v_track.provider else null end,
        'source_url', case when v_revealed then v_track.source_url else null end,
        'license_url', case when v_revealed then v_track.license_url else null end,
        'genres', case when v_revealed then to_jsonb(v_track.genres) else null end,
        'reveal_description', case when v_revealed then v_track.reveal_description else null end,
        'license_note', case when v_revealed then v_track.license_note else null end
      );
    end if;

    select coalesce(jsonb_agg(history_item order by round_number), '[]'::jsonb)
    into v_round_history
    from (
      select
        r.round_number,
        jsonb_build_object(
          'round_number', r.round_number,
          'title', t.title,
          'artist', t.artist,
          'answer_type', t.correct_answer,
          'provider', t.provider,
          'source_url', t.source_url,
          'license_url', t.license_url
        ) as history_item
      from public.rounds r
      join private.round_preparations rp on rp.round_id = r.id and rp.status = 'ready'
      join private.tracks t on t.id = rp.track_id
      where r.game_id = v_room.current_game_id and r.status = 'scored'
    ) history;
  end if;

  select coalesce(jsonb_agg(player_json order by joined_at, id), '[]'::jsonb)
  into v_players
  from (
    select
      p.joined_at,
      p.id,
      jsonb_build_object(
        'id', p.id,
        'nickname', p.nickname,
        'is_ready', p.is_ready,
        'is_host', p.user_id = v_room.host_user_id,
        'is_connected', p.last_seen_at > clock_timestamp() - interval '30 seconds',
        'score', p.score,
        'has_submitted', case when v_round.id is null then false else exists (
          select 1 from public.answers a where a.round_id = v_round.id and a.player_id = p.id
        ) end
      ) as player_json
    from public.players p
    where p.room_id = p_room_id and p.left_at is null
  ) listed_players;

  select coalesce(jsonb_agg(rank_json order by score desc, joined_at, id), '[]'::jsonb)
  into v_leaderboard
  from (
    select
      p.score,
      p.joined_at,
      p.id,
      jsonb_build_object(
        'id', p.id,
        'nickname', p.nickname,
        'score', p.score,
        'is_host', p.user_id = v_room.host_user_id,
        'is_me', p.id = v_me.id
      ) as rank_json
    from public.players p
    where p.room_id = p_room_id and p.left_at is null
  ) ranked_players;

  return jsonb_build_object(
    'server_now', clock_timestamp(),
    'room', jsonb_build_object(
      'id', v_room.id,
      'code', v_room.code,
      'phase', v_room.phase,
      'phase_ends_at', v_room.phase_ends_at,
      'current_round', v_room.current_round,
      'created_at', v_room.created_at,
      'settings', jsonb_build_object(
        'round_count', v_room.round_count,
        'round_duration_seconds', v_room.round_duration_seconds,
        'reveal_duration_seconds', v_room.reveal_duration_seconds,
        'negative_points', v_room.negative_points,
        'allow_answer_changes', v_room.allow_answer_changes,
        'music_volume', v_room.music_volume,
        'song_pack', v_room.song_pack
      )
    ),
    'me', jsonb_build_object(
      'id', v_me.id,
      'nickname', v_me.nickname,
      'is_host', v_me.user_id = v_room.host_user_id,
      'is_ready', v_me.is_ready
    ),
    'players', v_players,
    'round', v_round_payload,
    'round_history', v_round_history,
    'leaderboard', v_leaderboard
  );
end;
$$;

create or replace function private.submit_answer(
  p_code text,
  p_choice public.answer_choice
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_user();
  v_room public.rooms;
  v_round public.rounds;
  v_player public.players;
  v_existing public.answers;
  v_now timestamptz := clock_timestamp();
  v_active_count integer;
  v_submitted_count integer;
  v_new_deadline timestamptz;
begin
  select * into v_room
  from public.rooms
  where code = private.clean_room_code(p_code)
  for update;
  if not found then raise exception using errcode = 'P0001', message = 'ROOM_NOT_FOUND'; end if;
  select * into v_player
  from public.players
  where room_id = v_room.id and user_id = v_user_id and left_at is null;
  if not found then raise exception using errcode = 'P0001', message = 'NOT_IN_ROOM'; end if;
  perform private.advance_room_locked(v_room.id);
  select * into v_room from public.rooms where id = v_room.id for update;
  if v_room.phase <> 'playing' then raise exception using errcode = 'P0001', message = 'ANSWER_WINDOW_CLOSED'; end if;

  select * into v_round
  from public.rounds
  where game_id = v_room.current_game_id and round_number = v_room.current_round
  for update;
  if v_now < v_round.starts_at or v_now >= v_round.deadline_at then
    raise exception using errcode = 'P0001', message = 'ANSWER_WINDOW_CLOSED';
  end if;
  select * into v_existing
  from public.answers
  where round_id = v_round.id and player_id = v_player.id
  for update;
  if found and not v_room.allow_answer_changes then
    raise exception using errcode = 'P0001', message = 'ANSWER_LOCKED';
  elsif found then
    update public.answers set
      choice = p_choice,
      submitted_at = v_now,
      is_correct = null,
      base_points = null,
      speed_points = null,
      penalty_points = null,
      total_points = null,
      scored_at = null
    where id = v_existing.id;
  else
    insert into public.answers (round_id, player_id, choice, submitted_at)
    values (v_round.id, v_player.id, p_choice, v_now);
  end if;

  update public.players set last_seen_at = v_now where id = v_player.id;

  if not v_room.allow_answer_changes then
    select count(*) into v_active_count
    from public.players
    where room_id = v_room.id and left_at is null
      and last_seen_at > v_now - interval '30 seconds';
    select count(*) into v_submitted_count
    from public.answers a
    join public.players p on p.id = a.player_id
    where a.round_id = v_round.id and p.left_at is null
      and p.last_seen_at > v_now - interval '30 seconds';

    if v_active_count > 0 and v_submitted_count >= v_active_count then
      v_new_deadline := least(v_round.deadline_at, v_now + interval '3 seconds');
      update public.rounds set
        deadline_at = v_new_deadline,
        reveal_ends_at = v_new_deadline + make_interval(secs => v_room.reveal_duration_seconds)
      where id = v_round.id;
      update public.rooms set phase_ends_at = v_new_deadline where id = v_room.id;
      perform private.emit_event(v_room.id, 'all_answers_submitted');
    end if;
  end if;

  perform private.emit_event(v_room.id, 'answer_submitted');
  return private.room_state(v_room.id, v_user_id);
end;
$$;

create function private.mark_round_audio_ready(p_code text, p_round_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_user();
  v_room public.rooms;
  v_round public.rounds;
  v_player public.players;
  v_preparation private.round_preparations;
begin
  select * into v_room
  from public.rooms
  where code = private.clean_room_code(p_code)
  for update;
  if not found then raise exception using errcode = 'P0001', message = 'ROOM_NOT_FOUND'; end if;
  select * into v_player
  from public.players
  where room_id = v_room.id and user_id = v_user_id and left_at is null;
  if not found then raise exception using errcode = 'P0001', message = 'NOT_IN_ROOM'; end if;
  perform private.advance_room_locked(v_room.id);
  select * into v_room from public.rooms where id = v_room.id for update;
  if v_room.phase <> 'preparing' then
    return private.room_state(v_room.id, v_user_id);
  end if;

  select * into v_round
  from public.rounds
  where id = p_round_id and game_id = v_room.current_game_id
    and round_number = v_room.current_round;
  if not found then raise exception using errcode = 'P0001', message = 'ROUND_NOT_ACTIVE'; end if;
  select * into v_preparation
  from private.round_preparations where round_id = v_round.id;
  if v_preparation.status <> 'ready' then
    raise exception using errcode = 'P0001', message = 'AUDIO_NOT_READY';
  end if;
  update public.players set last_seen_at = clock_timestamp() where id = v_player.id;
  insert into private.round_audio_ready (round_id, player_id)
  values (v_round.id, v_player.id)
  on conflict (round_id, player_id) do update set ready_at = excluded.ready_at;
  perform private.emit_event(v_room.id, 'player_audio_ready');
  perform private.advance_room_locked(v_room.id);
  return private.room_state(v_room.id, v_user_id);
end;
$$;

create function private.service_claim_round_preparation(
  p_code text,
  p_user_id uuid,
  p_force_retry boolean default false
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_room public.rooms;
  v_round public.rounds;
  v_plan private.round_plans;
  v_preparation private.round_preparations;
  v_track private.tracks;
  v_used_ids jsonb := '[]'::jsonb;
begin
  select * into v_room
  from public.rooms
  where code = private.clean_room_code(p_code)
  for update;
  if not found then raise exception using errcode = 'P0001', message = 'ROOM_NOT_FOUND'; end if;
  if not exists (
    select 1 from public.players
    where room_id = v_room.id and user_id = p_user_id and left_at is null
  ) then
    raise exception using errcode = 'P0001', message = 'NOT_IN_ROOM';
  end if;
  if p_force_retry and v_room.host_user_id <> p_user_id then
    raise exception using errcode = 'P0001', message = 'HOST_ONLY';
  end if;

  perform private.advance_room_locked(v_room.id);
  select * into v_room from public.rooms where id = v_room.id for update;
  if v_room.phase <> 'preparing' then
    return jsonb_build_object('status', v_room.phase);
  end if;
  select * into v_round
  from public.rounds
  where game_id = v_room.current_game_id and round_number = v_room.current_round;
  select * into v_plan from private.round_plans where round_id = v_round.id;
  select * into v_preparation
  from private.round_preparations where round_id = v_round.id for update;

  if v_preparation.status = 'ready' then
    return jsonb_build_object('status', 'ready', 'round_id', v_round.id);
  end if;
  if v_preparation.status = 'preparing'
     and v_preparation.lease_until > clock_timestamp() then
    return jsonb_build_object('status', 'preparing', 'round_id', v_round.id);
  end if;
  if v_preparation.status = 'failed' and not p_force_retry then
    return jsonb_build_object(
      'status', 'failed',
      'round_id', v_round.id,
      'error_code', v_preparation.last_error_code
    );
  end if;

  if v_room.song_pack = 'demo' then
    select t.* into v_track
    from private.tracks t
    where t.provider = 'project' and t.pack = 'demo' and t.enabled
      and t.correct_answer = v_plan.planned_answer
      and not exists (
        select 1
        from public.rounds used_round
        join private.round_preparations used_prep on used_prep.round_id = used_round.id
        where used_round.game_id = v_room.current_game_id
          and used_prep.track_id = t.id
      )
    order by gen_random_uuid()
    limit 1;
    if not found then
      select t.* into v_track
      from private.tracks t
      where t.provider = 'project' and t.pack = 'demo' and t.enabled
        and t.correct_answer = v_plan.planned_answer
      order by gen_random_uuid()
      limit 1;
    end if;
  elsif v_plan.planned_answer = 'ai' then
    select t.* into v_track
    from private.tracks t
    where t.provider = 'suno' and t.pack = 'dynamic' and t.enabled
      and not exists (
        select 1
        from public.rounds used_round
        join private.round_preparations used_prep on used_prep.round_id = used_round.id
        where used_round.game_id = v_room.current_game_id
          and used_prep.track_id = t.id
      )
    order by gen_random_uuid()
    limit 1;
    if not found then
      select t.* into v_track
      from private.tracks t
      where t.provider = 'suno' and t.pack = 'dynamic' and t.enabled
      order by t.last_used_at nulls first, gen_random_uuid()
      limit 1;
    end if;
  end if;

  if v_track.id is not null then
    update private.round_preparations set
      status = 'ready',
      attempts = attempts + 1,
      lease_until = null,
      last_error_code = null,
      track_id = v_track.id,
      ready_at = clock_timestamp()
    where round_id = v_round.id;
    insert into private.round_secrets (round_id, track_id)
    values (v_round.id, v_track.id)
    on conflict (round_id) do update set track_id = excluded.track_id;
    update private.tracks set last_used_at = clock_timestamp() where id = v_track.id;
    perform private.emit_event(v_room.id, 'round_audio_prepared');
    return jsonb_build_object('status', 'ready', 'round_id', v_round.id);
  end if;

  if v_plan.planned_answer <> 'real' then
    update private.round_preparations set
      status = 'failed',
      lease_until = null,
      last_error_code = 'NOT_ENOUGH_AI_TRACKS'
    where round_id = v_round.id;
    perform private.emit_event(v_room.id, 'round_preparation_failed');
    return jsonb_build_object(
      'status', 'failed', 'round_id', v_round.id,
      'error_code', 'NOT_ENOUGH_AI_TRACKS'
    );
  end if;

  update private.round_preparations set
    status = 'preparing',
    attempts = attempts + 1,
    lease_until = clock_timestamp() + interval '45 seconds',
    last_error_code = null,
    track_id = null,
    ready_at = null
  where round_id = v_round.id;

  select coalesce(jsonb_agg(t.provider_track_id), '[]'::jsonb)
  into v_used_ids
  from public.rounds used_round
  join private.round_preparations used_prep on used_prep.round_id = used_round.id
  join private.tracks t on t.id = used_prep.track_id
  where used_round.game_id = v_room.current_game_id and t.provider = 'jamendo';

  return jsonb_build_object(
    'status', 'claimed',
    'round_id', v_round.id,
    'answer_type', v_plan.planned_answer,
    'used_provider_track_ids', v_used_ids
  );
end;
$$;

create function private.service_get_cached_track(
  p_provider text,
  p_provider_track_id text,
  p_round_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_track private.tracks;
  v_game_id uuid;
begin
  select game_id into v_game_id from public.rounds where id = p_round_id;
  select * into v_track
  from private.tracks
  where provider = p_provider and provider_track_id = p_provider_track_id
    and enabled and storage_path is not null;
  if not found or exists (
    select 1
    from public.rounds r
    join private.round_preparations rp on rp.round_id = r.id
    where r.game_id = v_game_id and rp.track_id = v_track.id
  ) then
    return null;
  end if;
  return jsonb_build_object(
    'track_id', v_track.id,
    'storage_path', v_track.storage_path,
    'content_sha256', v_track.content_sha256
  );
end;
$$;

create function private.service_complete_jamendo_round(
  p_round_id uuid,
  p_provider_track_id text,
  p_title text,
  p_artist text,
  p_duration_seconds integer,
  p_storage_path text,
  p_source_url text,
  p_license_url text,
  p_genres text[],
  p_content_sha256 text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_round public.rounds;
  v_preparation private.round_preparations;
  v_track private.tracks;
begin
  select * into v_round from public.rounds where id = p_round_id for update;
  if not found then raise exception using errcode = 'P0001', message = 'ROUND_NOT_ACTIVE'; end if;
  select * into v_preparation
  from private.round_preparations where round_id = p_round_id for update;
  if v_preparation.status = 'ready' then
    select * into v_track from private.tracks where id = v_preparation.track_id;
    return jsonb_build_object(
      'status', 'ready',
      'round_id', p_round_id,
      'storage_path', v_track.storage_path
    );
  end if;
  if v_preparation.status <> 'preparing' then
    raise exception using errcode = 'P0001', message = 'PREPARATION_NOT_CLAIMED';
  end if;

  insert into private.tracks (
    public_id, title, artist, source_type, correct_answer, duration_seconds,
    audio_filename, reveal_description, license_note, pack, enabled,
    provider, provider_track_id, storage_path, source_url, license_url,
    genres, content_sha256, last_used_at
  ) values (
    gen_random_uuid()::text,
    left(trim(p_title), 100),
    nullif(left(trim(p_artist), 100), ''),
    'human-composed',
    'real',
    p_duration_seconds,
    null,
    'A downloadable Creative Commons track provided by Jamendo.',
    'License and source attribution are linked below.',
    'dynamic',
    true,
    'jamendo',
    p_provider_track_id,
    p_storage_path,
    p_source_url,
    p_license_url,
    coalesce(p_genres, '{}'::text[]),
    p_content_sha256,
    clock_timestamp()
  )
  on conflict (provider, provider_track_id) do update set
    title = excluded.title,
    artist = excluded.artist,
    duration_seconds = excluded.duration_seconds,
    storage_path = coalesce(private.tracks.storage_path, excluded.storage_path),
    source_url = excluded.source_url,
    license_url = excluded.license_url,
    genres = excluded.genres,
    content_sha256 = coalesce(private.tracks.content_sha256, excluded.content_sha256),
    enabled = true,
    last_used_at = clock_timestamp()
  returning * into v_track;

  update private.round_preparations set
    status = 'ready',
    lease_until = null,
    last_error_code = null,
    track_id = v_track.id,
    ready_at = clock_timestamp()
  where round_id = p_round_id;
  insert into private.round_secrets (round_id, track_id)
  values (p_round_id, v_track.id)
  on conflict (round_id) do update set track_id = excluded.track_id;
  perform private.emit_event(v_round.room_id, 'round_audio_prepared');
  return jsonb_build_object(
    'status', 'ready',
    'round_id', p_round_id,
    'storage_path', v_track.storage_path
  );
end;
$$;

create function private.service_fail_round_preparation(
  p_round_id uuid,
  p_error_code text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_room_id uuid;
  v_status text;
begin
  select r.room_id, rp.status
  into v_room_id, v_status
  from public.rounds r
  join private.round_preparations rp on rp.round_id = r.id
  where r.id = p_round_id;
  if v_room_id is null then raise exception using errcode = 'P0001', message = 'ROUND_NOT_ACTIVE'; end if;
  if v_status = 'ready' then
    return jsonb_build_object('status', 'ready', 'round_id', p_round_id);
  end if;
  update private.round_preparations set
    status = 'failed',
    lease_until = null,
    last_error_code = left(coalesce(nullif(trim(p_error_code), ''), 'PREPARATION_FAILED'), 80),
    track_id = null,
    ready_at = null
  where round_id = p_round_id;
  perform private.emit_event(v_room_id, 'round_preparation_failed');
  return jsonb_build_object('status', 'failed', 'round_id', p_round_id);
end;
$$;

create function private.service_round_audio_access(
  p_code text,
  p_user_id uuid,
  p_round_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_room public.rooms;
  v_track private.tracks;
begin
  select * into v_room from public.rooms where code = private.clean_room_code(p_code);
  if not found then raise exception using errcode = 'P0001', message = 'ROOM_NOT_FOUND'; end if;
  if not exists (
    select 1 from public.players
    where room_id = v_room.id and user_id = p_user_id and left_at is null
  ) then
    raise exception using errcode = 'P0001', message = 'NOT_IN_ROOM';
  end if;
  select t.* into v_track
  from public.rounds r
  join private.round_preparations rp on rp.round_id = r.id and rp.status = 'ready'
  join private.tracks t on t.id = rp.track_id
  where r.id = p_round_id and r.game_id = v_room.current_game_id;
  if not found then raise exception using errcode = 'P0001', message = 'AUDIO_NOT_READY'; end if;
  return jsonb_build_object(
    'storage_path', v_track.storage_path,
    'fallback_url', case
      when v_track.storage_path is null and v_track.audio_filename is not null
        then '/audio/' || v_track.audio_filename
      else null
    end
  );
end;
$$;

create function private.service_register_suno_track(
  p_title text,
  p_artist text,
  p_duration_seconds integer,
  p_storage_path text,
  p_source_url text,
  p_content_sha256 text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_track private.tracks;
begin
  if p_title is null or char_length(trim(p_title)) not between 1 and 100
     or p_artist is null or char_length(trim(p_artist)) not between 1 and 100
     or p_duration_seconds not between 5 and 3600
     or p_storage_path is null or p_storage_path !~ '^[0-9a-f-]{36}\.mp3$'
     or p_source_url is null
     or p_source_url !~ '^https://(www\.)?suno\.com/(song|playlist)/[^/?#]+'
     or p_content_sha256 is null or p_content_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = 'P0001', message = 'INVALID_TRACK';
  end if;

  insert into private.tracks (
    public_id, title, artist, source_type, correct_answer, duration_seconds,
    audio_filename, reveal_description, license_note, pack, enabled,
    provider, provider_track_id, storage_path, source_url, genres,
    content_sha256, last_used_at
  ) values (
    gen_random_uuid()::text,
    trim(p_title),
    trim(p_artist),
    'procedural-generator',
    'ai',
    p_duration_seconds,
    null,
    'An owned Suno export supplied by the game administrator.',
    'Owned Suno export; source creation page linked below.',
    'dynamic',
    true,
    'suno',
    p_content_sha256,
    p_storage_path,
    p_source_url,
    '{}'::text[],
    p_content_sha256,
    null
  )
  on conflict (content_sha256) where content_sha256 is not null do update set
    title = excluded.title,
    artist = excluded.artist,
    duration_seconds = excluded.duration_seconds,
    storage_path = private.tracks.storage_path,
    source_url = excluded.source_url,
    enabled = true
  returning * into v_track;

  return jsonb_build_object(
    'track_id', v_track.id,
    'title', v_track.title,
    'artist', v_track.artist,
    'storage_path', v_track.storage_path,
    'enabled', v_track.enabled
  );
end;
$$;

create or replace function private.admin_upsert_track(
  p_public_id text,
  p_title text,
  p_artist text,
  p_source_type text,
  p_correct_answer public.answer_choice,
  p_duration_seconds integer,
  p_audio_filename text,
  p_reveal_description text,
  p_license_note text,
  p_pack text,
  p_enabled boolean
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_user();
  v_track private.tracks;
begin
  if not exists (select 1 from private.admins where user_id = v_user_id)
     and coalesce((select auth.jwt() -> 'app_metadata' ->> 'role'), '') <> 'admin' then
    raise exception using errcode = 'P0001', message = 'ADMIN_ONLY';
  end if;
  insert into private.tracks (
    public_id, title, artist, source_type, correct_answer, duration_seconds,
    audio_filename, reveal_description, license_note, pack, enabled,
    provider, provider_track_id
  ) values (
    p_public_id, p_title, nullif(trim(p_artist), ''), p_source_type, p_correct_answer,
    p_duration_seconds, p_audio_filename, p_reveal_description, p_license_note,
    lower(trim(p_pack)), p_enabled, 'project', p_public_id
  )
  on conflict (public_id) do update set
    title = excluded.title,
    artist = excluded.artist,
    source_type = excluded.source_type,
    correct_answer = excluded.correct_answer,
    duration_seconds = excluded.duration_seconds,
    audio_filename = excluded.audio_filename,
    reveal_description = excluded.reveal_description,
    license_note = excluded.license_note,
    pack = excluded.pack,
    enabled = excluded.enabled
  returning * into v_track;
  return jsonb_build_object(
    'public_id', v_track.public_id,
    'title', v_track.title,
    'audio_url', '/audio/' || v_track.audio_filename,
    'enabled', v_track.enabled,
    'pack', v_track.pack,
    'license_note', v_track.license_note
  );
end;
$$;

create function public.mark_round_audio_ready(p_code text, p_round_id uuid)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$ select private.mark_round_audio_ready(p_code, p_round_id); $$;

create function public.service_claim_round_preparation(
  p_code text,
  p_user_id uuid,
  p_force_retry boolean default false
)
returns jsonb language sql volatile security invoker set search_path = ''
as $$ select private.service_claim_round_preparation(p_code, p_user_id, p_force_retry); $$;

create function public.service_get_cached_track(
  p_provider text,
  p_provider_track_id text,
  p_round_id uuid
)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select private.service_get_cached_track(p_provider, p_provider_track_id, p_round_id); $$;

create function public.service_complete_jamendo_round(
  p_round_id uuid,
  p_provider_track_id text,
  p_title text,
  p_artist text,
  p_duration_seconds integer,
  p_storage_path text,
  p_source_url text,
  p_license_url text,
  p_genres text[],
  p_content_sha256 text
)
returns jsonb language sql volatile security invoker set search_path = ''
as $$
  select private.service_complete_jamendo_round(
    p_round_id, p_provider_track_id, p_title, p_artist, p_duration_seconds,
    p_storage_path, p_source_url, p_license_url, p_genres, p_content_sha256
  );
$$;

create function public.service_fail_round_preparation(p_round_id uuid, p_error_code text)
returns jsonb language sql volatile security invoker set search_path = ''
as $$ select private.service_fail_round_preparation(p_round_id, p_error_code); $$;

create function public.service_round_audio_access(p_code text, p_user_id uuid, p_round_id uuid)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select private.service_round_audio_access(p_code, p_user_id, p_round_id); $$;

create function public.service_register_suno_track(
  p_title text,
  p_artist text,
  p_duration_seconds integer,
  p_storage_path text,
  p_source_url text,
  p_content_sha256 text
)
returns jsonb language sql volatile security invoker set search_path = ''
as $$
  select private.service_register_suno_track(
    p_title, p_artist, p_duration_seconds, p_storage_path, p_source_url, p_content_sha256
  );
$$;

revoke all on function public.mark_round_audio_ready(text, uuid) from public, anon, authenticated;
revoke all on function private.mark_round_audio_ready(text, uuid) from public, anon, authenticated;
revoke all on function private.balanced_round_plan(integer) from public, anon, authenticated;
grant execute on function private.mark_round_audio_ready(text, uuid) to authenticated;
grant execute on function public.mark_round_audio_ready(text, uuid) to authenticated;

revoke all on function private.service_claim_round_preparation(text, uuid, boolean) from public, anon, authenticated;
revoke all on function private.service_get_cached_track(text, text, uuid) from public, anon, authenticated;
revoke all on function private.service_complete_jamendo_round(uuid, text, text, text, integer, text, text, text, text[], text) from public, anon, authenticated;
revoke all on function private.service_fail_round_preparation(uuid, text) from public, anon, authenticated;
revoke all on function private.service_round_audio_access(text, uuid, uuid) from public, anon, authenticated;
revoke all on function private.service_register_suno_track(text, text, integer, text, text, text) from public, anon, authenticated;

revoke all on function public.service_claim_round_preparation(text, uuid, boolean) from public, anon, authenticated;
revoke all on function public.service_get_cached_track(text, text, uuid) from public, anon, authenticated;
revoke all on function public.service_complete_jamendo_round(uuid, text, text, text, integer, text, text, text, text[], text) from public, anon, authenticated;
revoke all on function public.service_fail_round_preparation(uuid, text) from public, anon, authenticated;
revoke all on function public.service_round_audio_access(text, uuid, uuid) from public, anon, authenticated;
revoke all on function public.service_register_suno_track(text, text, integer, text, text, text) from public, anon, authenticated;

grant usage on schema public, private to service_role;
grant execute on function private.service_claim_round_preparation(text, uuid, boolean) to service_role;
grant execute on function private.service_get_cached_track(text, text, uuid) to service_role;
grant execute on function private.service_complete_jamendo_round(uuid, text, text, text, integer, text, text, text, text[], text) to service_role;
grant execute on function private.service_fail_round_preparation(uuid, text) to service_role;
grant execute on function private.service_round_audio_access(text, uuid, uuid) to service_role;
grant execute on function private.service_register_suno_track(text, text, integer, text, text, text) to service_role;
grant execute on function public.service_claim_round_preparation(text, uuid, boolean) to service_role;
grant execute on function public.service_get_cached_track(text, text, uuid) to service_role;
grant execute on function public.service_complete_jamendo_round(uuid, text, text, text, integer, text, text, text, text[], text) to service_role;
grant execute on function public.service_fail_round_preparation(uuid, text) to service_role;
grant execute on function public.service_round_audio_access(text, uuid, uuid) to service_role;
grant execute on function public.service_register_suno_track(text, text, integer, text, text, text) to service_role;
