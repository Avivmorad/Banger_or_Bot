-- Real rounds already have cached Jamendo audio in private storage. Prefer
-- that library during preparation. Live Jamendo downloads remain the fallback
-- when no unused cached track is available, because those downloads were
-- exceeding the preparation deadline and failing the round.

create or replace function private.service_claim_round_preparation(
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
  v_claim_round_id uuid;
  v_active_round_id uuid;
  v_used_ids jsonb := '[]'::jsonb;
  v_full_game_audio_preload boolean := false;
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
    return private.game_preparation_status(v_room.current_game_id)
      || jsonb_build_object('status', v_room.phase);
  end if;

  select g.full_game_audio_preload
  into v_full_game_audio_preload
  from public.games g
  where g.id = v_room.current_game_id;

  if not v_full_game_audio_preload then
    return private.service_claim_legacy_round_preparation(
      p_code,
      p_user_id,
      p_force_retry
    );
  end if;

  if p_force_retry then
    update private.round_preparations rp
    set
      status = 'pending',
      lease_until = null,
      last_error_code = null,
      ready_at = null
    from public.rounds r
    where rp.round_id = r.id
      and r.game_id = v_room.current_game_id
      and rp.status = 'failed';
  end if;

  select r.id into v_active_round_id
  from public.rounds r
  join private.round_preparations rp on rp.round_id = r.id
  where r.game_id = v_room.current_game_id
    and rp.status = 'preparing'
    and rp.lease_until > clock_timestamp()
  order by r.round_number
  limit 1;
  if v_active_round_id is not null then
    return private.game_preparation_status(v_room.current_game_id)
      || jsonb_build_object(
        'status', 'preparing',
        'round_id', v_active_round_id
      );
  end if;

  if exists (
    select 1
    from public.rounds r
    join private.round_preparations rp on rp.round_id = r.id
    where r.game_id = v_room.current_game_id and rp.status = 'failed'
  ) then
    return private.game_preparation_status(v_room.current_game_id);
  end if;

  select r.id into v_claim_round_id
  from public.rounds r
  join private.round_preparations rp on rp.round_id = r.id
  where r.game_id = v_room.current_game_id
    and (
      rp.status = 'pending'
      or (rp.status = 'preparing' and rp.lease_until <= clock_timestamp())
    )
  order by r.round_number
  limit 1
  for update of rp skip locked;

  if v_claim_round_id is null then
    return private.game_preparation_status(v_room.current_game_id);
  end if;

  select * into v_round from public.rounds where id = v_claim_round_id;
  select * into v_plan from private.round_plans where round_id = v_round.id;
  select * into v_preparation
  from private.round_preparations where round_id = v_round.id for update;

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
  elsif v_plan.planned_answer = 'real' then
    select t.* into v_track
    from private.tracks t
    where t.provider = 'jamendo'
      and t.pack = 'dynamic'
      and t.enabled
      and t.storage_path is not null
      and not exists (
        select 1
        from public.rounds used_round
        join private.round_preparations used_prep on used_prep.round_id = used_round.id
        where used_round.game_id = v_room.current_game_id
          and used_prep.track_id = t.id
      )
    order by t.last_used_at nulls first, gen_random_uuid()
    limit 1;
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
    return private.game_preparation_status(v_room.current_game_id);
  end if;

  if v_plan.planned_answer <> 'real' then
    update private.round_preparations set
      status = 'failed',
      lease_until = null,
      last_error_code = 'NOT_ENOUGH_AI_TRACKS'
    where round_id = v_round.id;
    perform private.emit_event(v_room.id, 'round_preparation_failed');
    return private.game_preparation_status(v_room.current_game_id);
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

  return private.game_preparation_status(v_room.current_game_id)
    || jsonb_build_object(
      'status', 'claimed',
      'round_id', v_round.id,
      'answer_type', v_plan.planned_answer,
      'used_provider_track_ids', v_used_ids
    );
end;
$$;
