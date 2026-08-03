-- Song Guess: AI Or Real
-- Server-authoritative rooms, rounds, scoring, reconnection, and private track metadata.

create extension if not exists pgcrypto with schema extensions;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create type public.answer_choice as enum ('ai', 'real');
create type public.room_phase as enum (
  'lobby',
  'countdown',
  'playing',
  'reveal',
  'intermission',
  'finished'
);

create table private.tracks (
  id uuid primary key default gen_random_uuid(),
  public_id text not null unique check (public_id ~ '^track-[0-9]{3}$'),
  title text not null check (char_length(title) between 1 and 100),
  artist text check (artist is null or char_length(artist) <= 100),
  source_type text not null check (source_type in ('human-composed', 'procedural-generator')),
  correct_answer public.answer_choice not null,
  duration_seconds integer not null check (duration_seconds between 5 and 60),
  audio_filename text not null unique check (audio_filename ~ '^track-[0-9]{3}\.wav$'),
  reveal_description text not null check (char_length(reveal_description) between 1 and 500),
  license_note text not null check (char_length(license_note) between 1 and 300),
  pack text not null default 'demo' check (pack ~ '^[a-z0-9-]{1,40}$'),
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[A-HJ-NP-Z2-9]{6}$'),
  phase public.room_phase not null default 'lobby',
  host_user_id uuid not null references auth.users(id) on delete restrict,
  max_players integer not null default 8 check (max_players between 2 and 8),
  round_count integer not null default 6 check (round_count between 3 and 12),
  round_duration_seconds integer not null default 20 check (round_duration_seconds between 10 and 45),
  reveal_duration_seconds integer not null default 7 check (reveal_duration_seconds between 4 and 15),
  negative_points boolean not null default true,
  allow_answer_changes boolean not null default false,
  music_volume numeric(3,2) not null default 0.80 check (music_volume between 0 and 1),
  song_pack text not null default 'demo' check (song_pack ~ '^[a-z0-9-]{1,40}$'),
  current_game_id uuid,
  current_round integer not null default 0 check (current_round >= 0),
  phase_ends_at timestamptz,
  started_at timestamptz,
  expires_at timestamptz not null default (now() + interval '6 hours'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.players (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  nickname text not null check (char_length(nickname) between 2 and 20),
  is_ready boolean not null default false,
  score integer not null default 0,
  last_seen_at timestamptz not null default now(),
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index players_active_user_in_room_idx
  on public.players (room_id, user_id)
  where left_at is null;
create unique index players_active_nickname_in_room_idx
  on public.players (room_id, lower(nickname))
  where left_at is null;
create index players_room_active_idx on public.players (room_id, left_at, joined_at);
create index players_user_active_idx on public.players (user_id, left_at);
create index players_heartbeat_idx on public.players (room_id, last_seen_at) where left_at is null;

create table public.games (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  game_number integer not null check (game_number > 0),
  status text not null default 'active' check (status in ('active', 'finished')),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  created_at timestamptz not null default now(),
  unique (room_id, game_number)
);

alter table public.rooms
  add constraint rooms_current_game_fk
  foreign key (current_game_id) references public.games(id) on delete set null;

create index games_room_idx on public.games (room_id, game_number desc);

create table public.rounds (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games(id) on delete cascade,
  room_id uuid not null references public.rooms(id) on delete cascade,
  round_number integer not null check (round_number > 0),
  status text not null default 'pending' check (status in ('pending', 'active', 'scored')),
  starts_at timestamptz,
  deadline_at timestamptz,
  reveal_ends_at timestamptz,
  created_at timestamptz not null default now(),
  unique (game_id, round_number)
);

create index rounds_room_game_idx on public.rounds (room_id, game_id, round_number);

create table private.round_secrets (
  round_id uuid primary key references public.rounds(id) on delete cascade,
  track_id uuid not null references private.tracks(id) on delete restrict
);

create table public.answers (
  id uuid primary key default gen_random_uuid(),
  round_id uuid not null references public.rounds(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  choice public.answer_choice not null,
  submitted_at timestamptz not null default now(),
  is_correct boolean,
  base_points integer,
  speed_points integer,
  penalty_points integer,
  total_points integer,
  scored_at timestamptz,
  unique (round_id, player_id)
);

create index answers_round_idx on public.answers (round_id, submitted_at);
create index answers_player_idx on public.answers (player_id, round_id);

create table public.scores (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  total_points integer not null default 0,
  updated_at timestamptz not null default now(),
  unique (game_id, player_id)
);

create index scores_game_rank_idx on public.scores (game_id, total_points desc, player_id);

create table public.room_events (
  id bigint generated always as identity primary key,
  room_id uuid not null references public.rooms(id) on delete cascade,
  event_type text not null check (event_type ~ '^[a-z0-9_]{1,40}$'),
  created_at timestamptz not null default now()
);

create index room_events_room_idx on public.room_events (room_id, id desc);
alter table public.room_events replica identity full;

create table private.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table private.tracks enable row level security;
alter table private.round_secrets enable row level security;
alter table private.admins enable row level security;
alter table public.rooms enable row level security;
alter table public.players enable row level security;
alter table public.games enable row level security;
alter table public.rounds enable row level security;
alter table public.answers enable row level security;
alter table public.scores enable row level security;
alter table public.room_events enable row level security;

create function private.set_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at = clock_timestamp();
  return new;
end;
$$;

create trigger tracks_set_updated_at before update on private.tracks
for each row execute function private.set_updated_at();
create trigger rooms_set_updated_at before update on public.rooms
for each row execute function private.set_updated_at();
create trigger players_set_updated_at before update on public.players
for each row execute function private.set_updated_at();
create trigger scores_set_updated_at before update on public.scores
for each row execute function private.set_updated_at();

create function private.require_user()
returns uuid
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  return v_user_id;
end;
$$;

create function private.clean_nickname(p_nickname text)
returns text
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  v_nickname text := trim(regexp_replace(coalesce(p_nickname, ''), '\s+', ' ', 'g'));
begin
  if char_length(v_nickname) not between 2 and 20
     or v_nickname ~ '[[:cntrl:]<>]' then
    raise exception using errcode = 'P0001', message = 'INVALID_NICKNAME';
  end if;
  return v_nickname;
end;
$$;

create function private.clean_room_code(p_code text)
returns text
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  v_code text := upper(trim(coalesce(p_code, '')));
begin
  if v_code !~ '^[A-HJ-NP-Z2-9]{6}$' then
    raise exception using errcode = 'P0001', message = 'INVALID_ROOM_CODE';
  end if;
  return v_code;
end;
$$;

create function private.generate_room_code()
returns text
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_code text;
  v_attempt integer;
  v_index integer;
begin
  for v_attempt in 1..100 loop
    v_code := '';
    for v_index in 1..6 loop
      v_code := v_code || substr(v_alphabet, 1 + floor(random() * char_length(v_alphabet))::integer, 1);
    end loop;
    if not exists (select 1 from public.rooms where code = v_code) then
      return v_code;
    end if;
  end loop;
  raise exception using errcode = 'P0001', message = 'ROOM_CODE_UNAVAILABLE';
end;
$$;

create function private.emit_event(p_room_id uuid, p_event_type text)
returns void
language sql
volatile
security invoker
set search_path = ''
as $$
  insert into public.room_events (room_id, event_type)
  values (p_room_id, p_event_type);
$$;

create function private.is_room_member(p_room_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.players
    where room_id = p_room_id
      and user_id = (select auth.uid())
      and left_at is null
  );
$$;

create policy room_events_for_members
on public.room_events
for select
to authenticated
using ((select private.is_room_member(room_id)));

create function private.apply_settings(
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
     or v_result.song_pack !~ '^[a-z0-9-]{1,40}$' then
    raise exception using errcode = 'P0001', message = 'INVALID_SETTINGS';
  end if;
  return v_result;
exception
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception using errcode = 'P0001', message = 'INVALID_SETTINGS';
end;
$$;

create function private.transfer_host_if_needed(p_room_id uuid, p_force boolean default false)
returns void
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_room public.rooms;
  v_new_host uuid;
begin
  select * into v_room from public.rooms where id = p_room_id for update;
  if not found then return; end if;

  if not p_force and exists (
    select 1 from public.players
    where room_id = p_room_id
      and user_id = v_room.host_user_id
      and left_at is null
      and last_seen_at > clock_timestamp() - interval '45 seconds'
  ) then
    return;
  end if;

  select user_id into v_new_host
  from public.players
  where room_id = p_room_id and left_at is null
  order by
    (last_seen_at > clock_timestamp() - interval '45 seconds') desc,
    joined_at,
    id
  limit 1;

  if v_new_host is not null and v_new_host <> v_room.host_user_id then
    update public.rooms set host_user_id = v_new_host where id = p_room_id;
    perform private.emit_event(p_room_id, 'host_transferred');
  end if;
end;
$$;

create function private.score_round(p_round_id uuid)
returns void
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_round public.rounds;
  v_room public.rooms;
  v_correct public.answer_choice;
begin
  select * into v_round from public.rounds where id = p_round_id for update;
  if not found or v_round.status = 'scored' then return; end if;

  select * into v_room from public.rooms where id = v_round.room_id;
  select t.correct_answer into v_correct
  from private.round_secrets rs
  join private.tracks t on t.id = rs.track_id
  where rs.round_id = p_round_id;

  update public.answers a
  set
    is_correct = (a.choice = v_correct),
    base_points = case when a.choice = v_correct then 1000 else 0 end,
    speed_points = case
      when a.choice = v_correct then greatest(
        0,
        round(
          2000 * (
            1 - least(
              1,
              greatest(
                0,
                extract(epoch from (a.submitted_at - v_round.starts_at))
                / v_room.round_duration_seconds
              )
            )
          )
        )::integer
      )
      else 0
    end,
    penalty_points = case
      when a.choice <> v_correct and v_room.negative_points then -500
      else 0
    end,
    total_points = case
      when a.choice = v_correct then
        1000 + greatest(
          0,
          round(
            2000 * (
              1 - least(
                1,
                greatest(
                  0,
                  extract(epoch from (a.submitted_at - v_round.starts_at))
                  / v_room.round_duration_seconds
                )
              )
            )
          )::integer
        )
      when v_room.negative_points then -500
      else 0
    end,
    scored_at = clock_timestamp()
  where a.round_id = p_round_id and a.scored_at is null;

  update public.scores s
  set total_points = coalesce((
    select sum(a.total_points)
    from public.answers a
    join public.rounds r on r.id = a.round_id
    where r.game_id = s.game_id
      and a.player_id = s.player_id
      and a.scored_at is not null
  ), 0)
  where s.game_id = v_round.game_id;

  update public.players p
  set score = s.total_points
  from public.scores s
  where s.game_id = v_round.game_id and s.player_id = p.id;

  update public.rounds set status = 'scored' where id = p_round_id;
end;
$$;

create function private.advance_room_locked(p_room_id uuid)
returns void
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_room public.rooms;
  v_round public.rounds;
  v_anchor timestamptz;
  v_next_round integer;
  v_iterations integer := 0;
begin
  select * into v_room from public.rooms where id = p_room_id for update;
  if not found then return; end if;

  perform private.transfer_host_if_needed(p_room_id, false);
  select * into v_room from public.rooms where id = p_room_id for update;

  while v_room.phase not in ('lobby', 'finished')
    and v_room.phase_ends_at is not null
    and v_room.phase_ends_at <= clock_timestamp()
    and v_iterations < 20
  loop
    v_iterations := v_iterations + 1;
    v_anchor := v_room.phase_ends_at;

    select * into v_round
    from public.rounds
    where game_id = v_room.current_game_id and round_number = v_room.current_round
    for update;

    if v_room.phase = 'countdown' then
      update public.rounds set status = 'active' where id = v_round.id;
      update public.rooms
      set phase = 'playing', phase_ends_at = v_round.deadline_at
      where id = p_room_id;
      perform private.emit_event(p_room_id, 'round_started');

    elsif v_room.phase = 'playing' then
      perform private.score_round(v_round.id);
      update public.rooms
      set phase = 'reveal', phase_ends_at = v_round.reveal_ends_at
      where id = p_room_id;
      perform private.emit_event(p_room_id, 'round_revealed');

    elsif v_room.phase = 'reveal' then
      if v_room.current_round >= v_room.round_count then
        update public.rooms
        set phase = 'finished', phase_ends_at = null, expires_at = clock_timestamp() + interval '2 hours'
        where id = p_room_id;
        update public.games
        set status = 'finished', finished_at = clock_timestamp()
        where id = v_room.current_game_id;
        perform private.emit_event(p_room_id, 'game_finished');
      else
        update public.rooms
        set phase = 'intermission', phase_ends_at = v_anchor + interval '4 seconds'
        where id = p_room_id;
        perform private.emit_event(p_room_id, 'leaderboard');
      end if;

    elsif v_room.phase = 'intermission' then
      v_next_round := v_room.current_round + 1;
      update public.rounds
      set
        starts_at = v_anchor + interval '4 seconds',
        deadline_at = v_anchor + interval '4 seconds' + make_interval(secs => v_room.round_duration_seconds),
        reveal_ends_at = v_anchor + interval '4 seconds'
          + make_interval(secs => v_room.round_duration_seconds + v_room.reveal_duration_seconds)
      where game_id = v_room.current_game_id and round_number = v_next_round;
      update public.rooms
      set current_round = v_next_round,
          phase = 'countdown',
          phase_ends_at = v_anchor + interval '4 seconds'
      where id = p_room_id;
      perform private.emit_event(p_room_id, 'countdown_started');
    end if;

    select * into v_room from public.rooms where id = p_room_id for update;
  end loop;
end;
$$;

create function private.room_state(p_room_id uuid, p_user_id uuid)
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
  v_answer public.answers;
  v_players jsonb := '[]'::jsonb;
  v_leaderboard jsonb := '[]'::jsonb;
  v_submitted_count integer := 0;
  v_round_payload jsonb := null;
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
      select t.* into v_track
      from private.round_secrets rs
      join private.tracks t on t.id = rs.track_id
      where rs.round_id = v_round.id;
      select * into v_answer
      from public.answers
      where round_id = v_round.id and player_id = v_me.id;
      select count(*) into v_submitted_count
      from public.answers where round_id = v_round.id;

      v_round_payload := jsonb_build_object(
        'id', v_round.id,
        'number', v_round.round_number,
        'total', v_room.round_count,
        'starts_at', v_round.starts_at,
        'deadline_at', v_round.deadline_at,
        'audio_url', '/audio/' || v_track.audio_filename,
        'audio_duration_seconds', v_track.duration_seconds,
        'submitted_count', v_submitted_count,
        'own_answer', case when v_answer.id is null then null else v_answer.choice end,
        'own_points', case
          when v_room.phase in ('reveal', 'intermission', 'finished') then coalesce(v_answer.total_points, 0)
          else null
        end,
        'correct_answer', case
          when v_room.phase in ('reveal', 'intermission', 'finished') then v_track.correct_answer
          else null
        end,
        'title', case
          when v_room.phase in ('reveal', 'intermission', 'finished') then v_track.title
          else null
        end,
        'artist', case
          when v_room.phase in ('reveal', 'intermission', 'finished') then v_track.artist
          else null
        end,
        'source_type', case
          when v_room.phase in ('reveal', 'intermission', 'finished') then v_track.source_type
          else null
        end,
        'reveal_description', case
          when v_room.phase in ('reveal', 'intermission', 'finished') then v_track.reveal_description
          else null
        end,
        'license_note', case
          when v_room.phase in ('reveal', 'intermission', 'finished') then v_track.license_note
          else null
        end
      );
    end if;
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
    'leaderboard', v_leaderboard
  );
end;
$$;

create function private.create_room(p_nickname text, p_settings jsonb default '{}'::jsonb)
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
    coalesce(v_room.music_volume, 0.80), coalesce(v_room.song_pack, 'demo')
  ) returning * into v_room;

  insert into public.players (room_id, user_id, nickname, is_ready)
  values (v_room.id, v_user_id, v_nickname, false)
  returning * into v_player;

  perform private.emit_event(v_room.id, 'room_created');
  return private.room_state(v_room.id, v_user_id);
end;
$$;

create function private.join_room(p_code text, p_nickname text)
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
  if (select count(*) from public.players where room_id = v_room.id and left_at is null) >= v_room.max_players then
    raise exception using errcode = 'P0001', message = 'ROOM_FULL';
  end if;

  insert into public.players (room_id, user_id, nickname)
  values (v_room.id, v_user_id, v_nickname);
  perform private.emit_event(v_room.id, 'player_joined');
  return private.room_state(v_room.id, v_user_id);
end;
$$;

create function private.get_room_state(p_code text)
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
  perform private.advance_room_locked(v_room_id);
  return private.room_state(v_room_id, v_user_id);
end;
$$;

create function private.heartbeat(p_code text)
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
  select r.id into v_room_id
  from public.rooms r
  join public.players p on p.room_id = r.id
  where r.code = private.clean_room_code(p_code)
    and p.user_id = v_user_id and p.left_at is null
    and r.expires_at > clock_timestamp();
  if v_room_id is null then
    raise exception using errcode = 'P0001', message = 'ROOM_NOT_FOUND';
  end if;
  update public.players
  set last_seen_at = clock_timestamp()
  where room_id = v_room_id and user_id = v_user_id and left_at is null;
  perform private.advance_room_locked(v_room_id);
  return private.room_state(v_room_id, v_user_id);
end;
$$;

create function private.set_ready(p_code text, p_ready boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_user();
  v_room public.rooms;
begin
  select * into v_room from public.rooms where code = private.clean_room_code(p_code) for update;
  if not found then raise exception using errcode = 'P0001', message = 'ROOM_NOT_FOUND'; end if;
  if v_room.phase <> 'lobby' then raise exception using errcode = 'P0001', message = 'LOBBY_CLOSED'; end if;

  update public.players
  set is_ready = p_ready, last_seen_at = clock_timestamp()
  where room_id = v_room.id and user_id = v_user_id and left_at is null;
  if not found then raise exception using errcode = 'P0001', message = 'NOT_IN_ROOM'; end if;
  perform private.emit_event(v_room.id, 'ready_changed');
  return private.room_state(v_room.id, v_user_id);
end;
$$;

create function private.update_settings(p_code text, p_settings jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_user();
  v_room public.rooms;
  v_settings public.rooms;
begin
  select * into v_room from public.rooms where code = private.clean_room_code(p_code) for update;
  if not found then raise exception using errcode = 'P0001', message = 'ROOM_NOT_FOUND'; end if;
  if v_room.host_user_id <> v_user_id then raise exception using errcode = 'P0001', message = 'HOST_ONLY'; end if;
  if v_room.phase <> 'lobby' then raise exception using errcode = 'P0001', message = 'LOBBY_CLOSED'; end if;

  v_settings := private.apply_settings(v_room, coalesce(p_settings, '{}'::jsonb));
  update public.rooms set
    round_count = v_settings.round_count,
    round_duration_seconds = v_settings.round_duration_seconds,
    reveal_duration_seconds = v_settings.reveal_duration_seconds,
    negative_points = v_settings.negative_points,
    allow_answer_changes = v_settings.allow_answer_changes,
    music_volume = v_settings.music_volume,
    song_pack = v_settings.song_pack
  where id = v_room.id;
  perform private.emit_event(v_room.id, 'settings_changed');
  return private.room_state(v_room.id, v_user_id);
end;
$$;

create function private.start_game(p_code text)
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
  v_track record;
  v_round public.rounds;
  v_round_number integer := 0;
  v_start timestamptz := clock_timestamp() + interval '4 seconds';
begin
  select * into v_room from public.rooms where code = private.clean_room_code(p_code) for update;
  if not found then raise exception using errcode = 'P0001', message = 'ROOM_NOT_FOUND'; end if;
  if v_room.host_user_id <> v_user_id then raise exception using errcode = 'P0001', message = 'HOST_ONLY'; end if;
  if v_room.phase <> 'lobby' then raise exception using errcode = 'P0001', message = 'GAME_ALREADY_STARTED'; end if;
  if (select count(*) from public.players where room_id = v_room.id and left_at is null) < 2 then
    raise exception using errcode = 'P0001', message = 'NEED_TWO_PLAYERS';
  end if;
  if exists (
    select 1 from public.players
    where room_id = v_room.id and left_at is null
      and (not is_ready or last_seen_at <= clock_timestamp() - interval '30 seconds')
  ) then
    raise exception using errcode = 'P0001', message = 'PLAYERS_NOT_READY';
  end if;
  if (select count(*) from private.tracks where enabled and pack = v_room.song_pack) < v_room.round_count then
    raise exception using errcode = 'P0001', message = 'NOT_ENOUGH_TRACKS';
  end if;

  select coalesce(max(game_number), 0) + 1 into v_game_number
  from public.games where room_id = v_room.id;
  insert into public.games (room_id, game_number)
  values (v_room.id, v_game_number)
  returning * into v_game;

  insert into public.scores (game_id, player_id)
  select v_game.id, id from public.players where room_id = v_room.id and left_at is null;

  for v_track in
    select id from private.tracks
    where enabled and pack = v_room.song_pack
    order by gen_random_uuid()
    limit v_room.round_count
  loop
    v_round_number := v_round_number + 1;
    insert into public.rounds (game_id, room_id, round_number)
    values (v_game.id, v_room.id, v_round_number)
    returning * into v_round;
    insert into private.round_secrets (round_id, track_id) values (v_round.id, v_track.id);
  end loop;

  update public.rounds set
    starts_at = v_start,
    deadline_at = v_start + make_interval(secs => v_room.round_duration_seconds),
    reveal_ends_at = v_start + make_interval(secs => v_room.round_duration_seconds + v_room.reveal_duration_seconds)
  where game_id = v_game.id and round_number = 1;

  update public.rooms set
    current_game_id = v_game.id,
    current_round = 1,
    phase = 'countdown',
    phase_ends_at = v_start,
    started_at = clock_timestamp(),
    expires_at = clock_timestamp() + interval '6 hours'
  where id = v_room.id;
  update public.players set score = 0 where room_id = v_room.id and left_at is null;

  perform private.emit_event(v_room.id, 'game_started');
  return private.room_state(v_room.id, v_user_id);
end;
$$;

create function private.submit_answer(p_code text, p_choice public.answer_choice)
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
begin
  select * into v_room from public.rooms where code = private.clean_room_code(p_code) for update;
  if not found then raise exception using errcode = 'P0001', message = 'ROOM_NOT_FOUND'; end if;
  perform private.advance_room_locked(v_room.id);
  select * into v_room from public.rooms where id = v_room.id for update;
  if v_room.phase <> 'playing' then raise exception using errcode = 'P0001', message = 'ANSWER_WINDOW_CLOSED'; end if;

  select * into v_round
  from public.rounds where game_id = v_room.current_game_id and round_number = v_room.current_round;
  if v_now < v_round.starts_at or v_now >= v_round.deadline_at then
    raise exception using errcode = 'P0001', message = 'ANSWER_WINDOW_CLOSED';
  end if;
  select * into v_player
  from public.players where room_id = v_room.id and user_id = v_user_id and left_at is null;
  if not found then raise exception using errcode = 'P0001', message = 'NOT_IN_ROOM'; end if;

  select * into v_existing
  from public.answers where round_id = v_round.id and player_id = v_player.id for update;
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
  perform private.emit_event(v_room.id, 'answer_submitted');
  return private.room_state(v_room.id, v_user_id);
end;
$$;

create function private.leave_room(p_code text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_user();
  v_room public.rooms;
begin
  select * into v_room from public.rooms where code = private.clean_room_code(p_code) for update;
  if not found then raise exception using errcode = 'P0001', message = 'ROOM_NOT_FOUND'; end if;
  update public.players
  set left_at = clock_timestamp(), is_ready = false
  where room_id = v_room.id and user_id = v_user_id and left_at is null;
  if not found then raise exception using errcode = 'P0001', message = 'NOT_IN_ROOM'; end if;
  if v_room.host_user_id = v_user_id then
    perform private.transfer_host_if_needed(v_room.id, true);
  end if;
  if not exists (select 1 from public.players where room_id = v_room.id and left_at is null) then
    update public.rooms set expires_at = clock_timestamp() where id = v_room.id;
  end if;
  perform private.emit_event(v_room.id, 'player_left');
  return jsonb_build_object('left', true);
end;
$$;

create function private.remove_player(p_code text, p_player_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_user();
  v_room public.rooms;
begin
  select * into v_room from public.rooms where code = private.clean_room_code(p_code) for update;
  if not found then raise exception using errcode = 'P0001', message = 'ROOM_NOT_FOUND'; end if;
  if v_room.host_user_id <> v_user_id then raise exception using errcode = 'P0001', message = 'HOST_ONLY'; end if;
  if v_room.phase <> 'lobby' then raise exception using errcode = 'P0001', message = 'LOBBY_CLOSED'; end if;
  if exists (select 1 from public.players where id = p_player_id and user_id = v_user_id) then
    raise exception using errcode = 'P0001', message = 'HOST_CANNOT_REMOVE_SELF';
  end if;
  update public.players
  set left_at = clock_timestamp(), is_ready = false
  where id = p_player_id and room_id = v_room.id and left_at is null;
  if not found then raise exception using errcode = 'P0001', message = 'PLAYER_NOT_FOUND'; end if;
  perform private.emit_event(v_room.id, 'player_removed');
  return private.room_state(v_room.id, v_user_id);
end;
$$;

create function private.play_again(p_code text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_user();
  v_room public.rooms;
begin
  select * into v_room from public.rooms where code = private.clean_room_code(p_code) for update;
  if not found then raise exception using errcode = 'P0001', message = 'ROOM_NOT_FOUND'; end if;
  if v_room.host_user_id <> v_user_id then raise exception using errcode = 'P0001', message = 'HOST_ONLY'; end if;
  if v_room.phase <> 'finished' then raise exception using errcode = 'P0001', message = 'GAME_NOT_FINISHED'; end if;

  update public.rooms set
    phase = 'lobby', current_game_id = null, current_round = 0,
    phase_ends_at = null, started_at = null,
    expires_at = clock_timestamp() + interval '6 hours'
  where id = v_room.id;
  update public.players
  set is_ready = false, score = 0, last_seen_at = clock_timestamp()
  where room_id = v_room.id and left_at is null;
  perform private.emit_event(v_room.id, 'room_reset');
  return private.room_state(v_room.id, v_user_id);
end;
$$;

create function private.admin_upsert_track(
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
    audio_filename, reveal_description, license_note, pack, enabled
  ) values (
    p_public_id, p_title, nullif(trim(p_artist), ''), p_source_type, p_correct_answer,
    p_duration_seconds, p_audio_filename, p_reveal_description, p_license_note,
    lower(trim(p_pack)), p_enabled
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

create function private.admin_list_tracks()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := private.require_user();
  v_result jsonb;
begin
  if not exists (select 1 from private.admins where user_id = v_user_id)
     and coalesce((select auth.jwt() -> 'app_metadata' ->> 'role'), '') <> 'admin' then
    raise exception using errcode = 'P0001', message = 'ADMIN_ONLY';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'public_id', public_id,
    'title', title,
    'artist', artist,
    'source_type', source_type,
    'correct_answer', correct_answer,
    'duration_seconds', duration_seconds,
    'audio_url', '/audio/' || audio_filename,
    'reveal_description', reveal_description,
    'license_note', license_note,
    'pack', pack,
    'enabled', enabled
  ) order by public_id), '[]'::jsonb)
  into v_result from private.tracks;
  return v_result;
end;
$$;

create function private.cleanup_expired_rooms()
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  delete from public.rooms where expires_at < clock_timestamp();
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Thin invoker wrappers are the only RPCs exposed by the Data API. Privileged
-- implementation functions stay in the non-exposed private schema.
create function public.create_room(p_nickname text, p_settings jsonb default '{}'::jsonb)
returns jsonb language sql volatile security invoker set search_path = ''
as $$ select private.create_room(p_nickname, p_settings); $$;
create function public.join_room(p_code text, p_nickname text)
returns jsonb language sql volatile security invoker set search_path = ''
as $$ select private.join_room(p_code, p_nickname); $$;
create function public.get_room_state(p_code text)
returns jsonb language sql volatile security invoker set search_path = ''
as $$ select private.get_room_state(p_code); $$;
create function public.heartbeat(p_code text)
returns jsonb language sql volatile security invoker set search_path = ''
as $$ select private.heartbeat(p_code); $$;
create function public.set_ready(p_code text, p_ready boolean)
returns jsonb language sql volatile security invoker set search_path = ''
as $$ select private.set_ready(p_code, p_ready); $$;
create function public.update_settings(p_code text, p_settings jsonb)
returns jsonb language sql volatile security invoker set search_path = ''
as $$ select private.update_settings(p_code, p_settings); $$;
create function public.start_game(p_code text)
returns jsonb language sql volatile security invoker set search_path = ''
as $$ select private.start_game(p_code); $$;
create function public.submit_answer(p_code text, p_choice public.answer_choice)
returns jsonb language sql volatile security invoker set search_path = ''
as $$ select private.submit_answer(p_code, p_choice); $$;
create function public.leave_room(p_code text)
returns jsonb language sql volatile security invoker set search_path = ''
as $$ select private.leave_room(p_code); $$;
create function public.remove_player(p_code text, p_player_id uuid)
returns jsonb language sql volatile security invoker set search_path = ''
as $$ select private.remove_player(p_code, p_player_id); $$;
create function public.play_again(p_code text)
returns jsonb language sql volatile security invoker set search_path = ''
as $$ select private.play_again(p_code); $$;
create function public.admin_upsert_track(
  p_public_id text, p_title text, p_artist text, p_source_type text,
  p_correct_answer public.answer_choice, p_duration_seconds integer,
  p_audio_filename text, p_reveal_description text, p_license_note text,
  p_pack text, p_enabled boolean
)
returns jsonb language sql volatile security invoker set search_path = ''
as $$
  select private.admin_upsert_track(
    p_public_id, p_title, p_artist, p_source_type, p_correct_answer,
    p_duration_seconds, p_audio_filename, p_reveal_description,
    p_license_note, p_pack, p_enabled
  );
$$;
create function public.admin_list_tracks()
returns jsonb language sql stable security invoker set search_path = ''
as $$ select private.admin_list_tracks(); $$;

revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;
revoke all on all functions in schema private from public, anon, authenticated;

grant usage on schema public to authenticated;
grant usage on schema private to authenticated;
grant select on public.room_events to authenticated;
grant execute on function private.is_room_member(uuid) to authenticated;
grant execute on function private.create_room(text, jsonb) to authenticated;
grant execute on function private.join_room(text, text) to authenticated;
grant execute on function private.get_room_state(text) to authenticated;
grant execute on function private.heartbeat(text) to authenticated;
grant execute on function private.set_ready(text, boolean) to authenticated;
grant execute on function private.update_settings(text, jsonb) to authenticated;
grant execute on function private.start_game(text) to authenticated;
grant execute on function private.submit_answer(text, public.answer_choice) to authenticated;
grant execute on function private.leave_room(text) to authenticated;
grant execute on function private.remove_player(text, uuid) to authenticated;
grant execute on function private.play_again(text) to authenticated;
grant execute on function private.admin_upsert_track(
  text, text, text, text, public.answer_choice, integer, text, text, text, text, boolean
) to authenticated;
grant execute on function private.admin_list_tracks() to authenticated;

grant execute on function public.create_room(text, jsonb) to authenticated;
grant execute on function public.join_room(text, text) to authenticated;
grant execute on function public.get_room_state(text) to authenticated;
grant execute on function public.heartbeat(text) to authenticated;
grant execute on function public.set_ready(text, boolean) to authenticated;
grant execute on function public.update_settings(text, jsonb) to authenticated;
grant execute on function public.start_game(text) to authenticated;
grant execute on function public.submit_answer(text, public.answer_choice) to authenticated;
grant execute on function public.leave_room(text) to authenticated;
grant execute on function public.remove_player(text, uuid) to authenticated;
grant execute on function public.play_again(text) to authenticated;
grant execute on function public.admin_upsert_track(
  text, text, text, text, public.answer_choice, integer, text, text, text, text, boolean
) to authenticated;
grant execute on function public.admin_list_tracks() to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'room_events'
  ) then
    alter publication supabase_realtime add table public.room_events;
  end if;
end;
$$;

insert into private.tracks (
  public_id, title, artist, source_type, correct_answer, duration_seconds,
  audio_filename, reveal_description, license_note, pack
) values
  (
    'track-001', 'Neon Footsteps', 'Studio Session A', 'human-composed', 'real', 18,
    'track-001.wav',
    'A hand-composed syncopated bass line leaves tiny timing choices a human arranger wrote note by note.',
    'Original composition and synthesized recording created for this project. Copyright 2026 Aviv Morad; all rights reserved.',
    'demo'
  ),
  (
    'track-002', 'Glass Horizon', 'Studio Session B', 'human-composed', 'real', 18,
    'track-002.wav',
    'The melody was deliberately shaped across two phrases, including a held note that resolves late.',
    'Original composition and synthesized recording created for this project. Copyright 2026 Aviv Morad; all rights reserved.',
    'demo'
  ),
  (
    'track-003', 'After Midnight', 'Studio Session C', 'human-composed', 'real', 18,
    'track-003.wav',
    'A human-authored call-and-response motif is repeated with a small variation in the final bar.',
    'Original composition and synthesized recording created for this project. Copyright 2026 Aviv Morad; all rights reserved.',
    'demo'
  ),
  (
    'track-004', 'Probability Bloom', 'Pattern Engine 01', 'procedural-generator', 'ai', 18,
    'track-004.wav',
    'A seeded probabilistic generator chose notes from a weighted scale and quantized them into repeating cells.',
    'Original deterministic generator output created for this project. Copyright 2026 Aviv Morad; all rights reserved.',
    'demo'
  ),
  (
    'track-005', 'Synthetic Weather', 'Pattern Engine 02', 'procedural-generator', 'ai', 18,
    'track-005.wav',
    'The composition was produced by a deterministic rule system that mutates rhythm and pitch independently.',
    'Original deterministic generator output created for this project. Copyright 2026 Aviv Morad; all rights reserved.',
    'demo'
  ),
  (
    'track-006', 'Model Memory', 'Pattern Engine 03', 'procedural-generator', 'ai', 18,
    'track-006.wav',
    'A seeded Markov-style transition table generated the melody without a note-by-note human arrangement.',
    'Original deterministic generator output created for this project. Copyright 2026 Aviv Morad; all rights reserved.',
    'demo'
  );
