begin;

select plan(69);

select has_schema('private', 'private schema exists');
select has_table('public', 'rooms', 'rooms table exists');
select has_column(
  'public',
  'games',
  'full_game_audio_preload',
  'games can opt into whole-game audio preloading'
);
select col_default_is(
  'public',
  'games',
  'full_game_audio_preload',
  'false',
  'legacy games retain per-round preparation by default'
);
select has_column(
  'public',
  'games',
  'audio_playlist_revision',
  'games track playlist replacement revisions'
);
select col_default_is(
  'public',
  'games',
  'audio_playlist_revision',
  '1',
  'new games begin with the first audio playlist revision'
);
select has_table('public', 'players', 'players table exists');
select has_table('public', 'games', 'games table exists');
select has_table('public', 'rounds', 'rounds table exists');
select has_table('public', 'answers', 'answers table exists');
select has_table('public', 'scores', 'scores table exists');
select has_table('public', 'room_events', 'room events table exists');
select has_table('private', 'tracks', 'private tracks table exists');
select has_column('private', 'tracks', 'provider', 'track provider metadata exists');
select has_column('private', 'tracks', 'storage_path', 'private audio path exists');
select has_column('private', 'tracks', 'source_url', 'track source URL exists');
select has_column('private', 'tracks', 'license_url', 'track license URL exists');
select has_column('private', 'tracks', 'genres', 'future genre tags exist');
select has_table(
  'private',
  'round_secrets',
  'hidden round classification table exists'
);
select has_table('private', 'round_plans', 'hidden balanced round plans table exists');
select has_table(
  'private',
  'round_preparations',
  'private round preparation table exists'
);
select has_table(
  'private',
  'round_audio_ready',
  'private per-player audio readiness table exists'
);
select has_table(
  'private',
  'rpc_rate_limits',
  'private RPC rate-limit counters exist'
);
select has_function(
  'private',
  'enforce_rpc_rate_limit',
  array['uuid', 'text', 'integer', 'interval'],
  'RPC rate-limit enforcement function exists'
);
select has_function(
  'private',
  'cleanup_expired_game_data',
  array[]::text[],
  'scheduled game-data cleanup function exists'
);
select ok(
  exists (
    select 1
    from cron.job
    where jobname = 'cleanup-expired-game-data'
      and schedule = '17 * * * *'
  ),
  'expired game data cleanup runs hourly'
);
select is(
  has_function_privilege(
    'authenticated',
    'private.cleanup_expired_game_data()',
    'execute'
  ),
  false,
  'players cannot invoke privileged cleanup'
);
select is(
  (select relrowsecurity from pg_class where oid = 'public.rooms'::regclass),
  true,
  'rooms has row level security enabled'
);
select is(
  (select relrowsecurity from pg_class where oid = 'public.answers'::regclass),
  true,
  'answers has row level security enabled'
);
select is(
  (select relrowsecurity from pg_class where oid = 'private.round_preparations'::regclass),
  true,
  'round preparations have row level security enabled'
);
select is(
  (select public from storage.buckets where id = 'track-audio'),
  false,
  'track audio bucket is private'
);
select has_function(
  'public',
  'create_room',
  array['text', 'jsonb'],
  'create_room RPC exists'
);
select has_function(
  'public',
  'mark_round_audio_ready',
  array['text', 'uuid'],
  'audio readiness RPC exists'
);
select has_function(
  'public',
  'mark_game_audio_ready',
  array['text'],
  'whole-game audio readiness RPC exists'
);
select has_function(
  'public',
  'service_claim_round_preparation',
  array['text', 'uuid', 'boolean'],
  'service preparation claim RPC exists'
);
select has_function(
  'public',
  'service_round_audio_access',
  array['text', 'uuid', 'uuid'],
  'service audio access RPC exists'
);
select has_function(
  'public',
  'service_game_audio_access',
  array['text', 'uuid'],
  'service whole-game audio access RPC exists'
);
select has_function(
  'public',
  'service_skip_game_track',
  array['text', 'uuid'],
  'service track replacement RPC exists'
);
select has_function(
  'private',
  'balanced_round_plan',
  array['integer'],
  'balanced round planner exists'
);
select ok(
  (
    select count(*) = 6
      and count(*) filter (where planned_answer = 'real') = 3
      and count(*) filter (where planned_answer = 'ai') = 3
    from private.balanced_round_plan(6)
  ),
  'even round plans contain equal real and AI rounds'
);
select ok(
  (
    select count(*) = 5
      and abs(
        count(*) filter (where planned_answer = 'real')
        - count(*) filter (where planned_answer = 'ai')
      ) = 1
    from private.balanced_round_plan(5)
  ),
  'odd round plans differ by exactly one round'
);
select is(
  (select typtype::text from pg_type where oid = 'public.room_phase'::regtype),
  'e',
  'room phase enum exists'
);
select ok(
  exists (
    select 1
    from unnest(enum_range(null::public.room_phase)) as phase
    where phase::text = 'preparing'
  ),
  'room phase includes preparing'
);
select is(
  has_function_privilege(
    'authenticated',
    'public.service_claim_round_preparation(text,uuid,boolean)',
    'execute'
  ),
  false,
  'authenticated users cannot claim preparation through service RPC'
);
select is(
  has_function_privilege(
    'authenticated',
    'public.mark_game_audio_ready(text)',
    'execute'
  ),
  true,
  'authenticated players can acknowledge the downloaded game playlist'
);
select ok(
  has_function_privilege(
    'service_role',
    'public.service_claim_round_preparation(text,uuid,boolean)',
    'execute'
  )
  and has_function_privilege(
    'service_role',
    'public.service_round_audio_access(text,uuid,uuid)',
    'execute'
  )
  and not has_function_privilege(
    'authenticated',
    'public.service_round_audio_access(text,uuid,uuid)',
    'execute'
  ),
  'only the service role can use trusted preparation and audio access RPCs'
);
select is(
  has_function_privilege(
    'authenticated',
    'public.mark_round_audio_ready(text,uuid)',
    'execute'
  ),
  true,
  'authenticated players can acknowledge prepared audio'
);
select is(
  has_function_privilege(
    'authenticated',
    'public.service_skip_game_track(text,uuid)',
    'execute'
  ),
  false,
  'authenticated users cannot invoke the trusted track replacement RPC'
);
select is(
  has_function_privilege(
    'service_role',
    'public.service_skip_game_track(text,uuid)',
    'execute'
  ),
  true,
  'the service role can invoke the trusted track replacement RPC'
);
select has_function(
  'public',
  'submit_answer',
  array['text', 'answer_choice'],
  'submit_answer RPC exists'
);

insert into auth.users (id, is_anonymous)
values ('00000000-0000-0000-0000-000000000101', true);
select lives_ok(
  $$
    do $rate_limit$
    begin
      for attempt in 1..5 loop
        perform private.enforce_rpc_rate_limit(
          '00000000-0000-0000-0000-000000000101',
          'create_room',
          5,
          interval '10 minutes'
        );
      end loop;
    end
    $rate_limit$
  $$,
  'allowed RPC attempts remain below the configured limit'
);
select throws_ok(
  $$
    select private.enforce_rpc_rate_limit(
      '00000000-0000-0000-0000-000000000101',
      'create_room',
      5,
      interval '10 minutes'
    )
  $$,
  'P0001',
  'RATE_LIMITED',
  'excess RPC attempts are rejected'
);
insert into public.rooms (id, code, host_user_id, song_pack)
values (
  '00000000-0000-0000-0000-000000000102',
  'QATEST',
  '00000000-0000-0000-0000-000000000101',
  'dynamic'
);
insert into public.players (id, room_id, user_id, nickname, is_ready)
values (
  '00000000-0000-0000-0000-000000000103',
  '00000000-0000-0000-0000-000000000102',
  '00000000-0000-0000-0000-000000000101',
  'SQL Tester',
  true
);
insert into public.games (id, room_id, game_number)
values (
  '00000000-0000-0000-0000-000000000104',
  '00000000-0000-0000-0000-000000000102',
  1
);
update public.rooms set
  current_game_id = '00000000-0000-0000-0000-000000000104',
  current_round = 1,
  phase = 'preparing'
where id = '00000000-0000-0000-0000-000000000102';
insert into public.rounds (id, game_id, room_id, round_number)
values (
  '00000000-0000-0000-0000-000000000105',
  '00000000-0000-0000-0000-000000000104',
  '00000000-0000-0000-0000-000000000102',
  1
);
insert into private.round_plans (round_id, planned_answer)
values ('00000000-0000-0000-0000-000000000105', 'real');
insert into private.round_preparations (round_id, status, attempts, lease_until)
values (
  '00000000-0000-0000-0000-000000000105',
  'preparing',
  1,
  clock_timestamp() + interval '45 seconds'
);

select is(
  private.service_complete_jamendo_round(
    '00000000-0000-0000-0000-000000000105',
    'pgtap-jamendo-1',
    'SQL Test Track',
    'SQL Test Artist',
    180,
    '11111111-1111-1111-1111-111111111111.mp3',
    'https://www.jamendo.com/track/1',
    'https://creativecommons.org/licenses/by/4.0/',
    array['rock', 'electronic'],
    repeat('a', 64)
  ) ->> 'status',
  'ready',
  'Jamendo completion makes a claimed round ready'
);
select ok(
  exists (
    select 1 from private.tracks
    where provider = 'jamendo'
      and provider_track_id = 'pgtap-jamendo-1'
      and title = 'SQL Test Track'
      and artist = 'SQL Test Artist'
      and source_url = 'https://www.jamendo.com/track/1'
      and license_url = 'https://creativecommons.org/licenses/by/4.0/'
      and genres = array['rock', 'electronic']
      and storage_path = '11111111-1111-1111-1111-111111111111.mp3'
  ),
  'per-round preparation stores audio and reveal metadata'
);
select is(
  private.service_round_audio_access(
    'QATEST',
    '00000000-0000-0000-0000-000000000101',
    '00000000-0000-0000-0000-000000000105'
  ) ->> 'storage_path',
  '11111111-1111-1111-1111-111111111111.mp3',
  'room members receive the prepared private audio path'
);
select is(
  private.game_preparation_status(
    '00000000-0000-0000-0000-000000000104'
  ) ->> 'ready_count',
  '1',
  'whole-game preparation progress counts ready rounds'
);
select ok(
  (
    private.service_claim_round_preparation(
      'QATEST',
      '00000000-0000-0000-0000-000000000101',
      false
    ) ->> 'status'
  ) = 'ready'
  and not (
    private.service_claim_round_preparation(
      'QATEST',
      '00000000-0000-0000-0000-000000000101',
      false
    ) ? 'total_count'
  ),
  'legacy games keep the per-round preparation response contract'
);
select ok(
  jsonb_array_length(
    private.service_game_audio_access(
      'QATEST',
      '00000000-0000-0000-0000-000000000101'
    ) -> 'tracks'
  ) = 1,
  'room members can preload every prepared track without reveal metadata'
);

update public.rounds
set
  status = 'scored',
  starts_at = clock_timestamp() - interval '2 seconds'
where id = '00000000-0000-0000-0000-000000000105';
insert into public.answers (
  round_id,
  player_id,
  choice,
  submitted_at,
  is_correct,
  total_points
)
values (
  '00000000-0000-0000-0000-000000000105',
  '00000000-0000-0000-0000-000000000103',
  'real',
  clock_timestamp() - interval '1 second',
  true,
  750
);
select ok(
  (
    private.room_state(
      '00000000-0000-0000-0000-000000000102',
      '00000000-0000-0000-0000-000000000101'
    ) #> '{round_history,0}'
  ) @> jsonb_build_object(
    'own_answer', 'real',
    'own_points', 750,
    'was_correct', true
  ),
  'room history includes the player answer, result, and score change'
);
delete from public.answers
where round_id = '00000000-0000-0000-0000-000000000105';
update public.rounds
set status = 'pending', starts_at = null
where id = '00000000-0000-0000-0000-000000000105';

insert into public.rounds (id, game_id, room_id, round_number)
values (
  '00000000-0000-0000-0000-000000000106',
  '00000000-0000-0000-0000-000000000104',
  '00000000-0000-0000-0000-000000000102',
  2
);
insert into private.round_plans (round_id, planned_answer)
values ('00000000-0000-0000-0000-000000000106', 'ai');
insert into private.round_preparations (round_id)
values ('00000000-0000-0000-0000-000000000106');
insert into private.round_audio_ready (round_id, player_id)
values (
  '00000000-0000-0000-0000-000000000105',
  '00000000-0000-0000-0000-000000000103'
);
update public.games
set
  full_game_audio_preload = true,
  audio_preload_deadline = clock_timestamp() + interval '60 seconds'
where id = '00000000-0000-0000-0000-000000000104';

select lives_ok(
  $$select private.advance_room_locked(
    '00000000-0000-0000-0000-000000000102'
  )$$,
  'game advancement safely checks whole-game preparation'
);
select is(
  (select phase::text from public.rooms where code = 'QATEST'),
  'preparing',
  'countdown waits while any game track is still pending'
);

update private.round_preparations
set
  status = 'ready',
  track_id = (
    select id from private.tracks
    where provider = 'jamendo' and provider_track_id = 'pgtap-jamendo-1'
  ),
  ready_at = clock_timestamp()
where round_id = '00000000-0000-0000-0000-000000000106';
insert into private.round_secrets (round_id, track_id)
select
  '00000000-0000-0000-0000-000000000106',
  id
from private.tracks
where provider = 'jamendo' and provider_track_id = 'pgtap-jamendo-1';

select is(
  private.service_skip_game_track(
    'QATEST',
    '00000000-0000-0000-0000-000000000101'
  ) ->> 'playlist_revision',
  '2',
  'skipping a prepared track advances the playlist revision'
);
select ok(
  (
    select status = 'pending'
      and not exists (
        select 1
        from private.round_secrets
        where round_id = '00000000-0000-0000-0000-000000000105'
      )
      and not exists (
        select 1
        from private.round_audio_ready ar
        join public.rounds r on r.id = ar.round_id
        where r.game_id = '00000000-0000-0000-0000-000000000104'
      )
    from private.round_preparations
    where round_id = '00000000-0000-0000-0000-000000000105'
  ),
  'skipping resets the chosen preparation and every player readiness record'
);
update private.round_preparations
set status = 'ready', ready_at = clock_timestamp()
where round_id = '00000000-0000-0000-0000-000000000105';
insert into private.round_secrets (round_id, track_id)
select
  '00000000-0000-0000-0000-000000000105',
  id
from private.tracks
where provider = 'jamendo' and provider_track_id = 'pgtap-jamendo-1';

insert into auth.users (id, is_anonymous)
values ('00000000-0000-0000-0000-000000000107', true);
insert into public.players (id, room_id, user_id, nickname, is_ready)
values (
  '00000000-0000-0000-0000-000000000108',
  '00000000-0000-0000-0000-000000000102',
  '00000000-0000-0000-0000-000000000107',
  'Stalled SQL Guest',
  true
);

select lives_ok(
  $$select private.advance_room_locked(
    '00000000-0000-0000-0000-000000000102'
  )$$,
  'game advancement checks full-game player readiness'
);
select is(
  (select phase::text from public.rooms where code = 'QATEST'),
  'preparing',
  'countdown waits until every active player cached every round'
);

update public.games
set audio_preload_deadline = clock_timestamp() - interval '1 second'
where id = '00000000-0000-0000-0000-000000000104';

select is(
  private.service_game_preparation_status(
    'QATEST',
    '00000000-0000-0000-0000-000000000101'
  ) ->> 'timed_out',
  'true',
  'the authoritative preload deadline reports a timeout'
);
select is(
  private.service_game_preparation_status(
    'QATEST',
    '00000000-0000-0000-0000-000000000101'
  ) #>> '{stalled_players,0,nickname}',
  'SQL Tester',
  'timeout status identifies the active stalled player'
);

insert into private.round_audio_ready (round_id, player_id)
values
  (
    '00000000-0000-0000-0000-000000000105',
    '00000000-0000-0000-0000-000000000103'
  ),
  (
    '00000000-0000-0000-0000-000000000106',
    '00000000-0000-0000-0000-000000000103'
  );

select set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000101',
  true
);
set local role authenticated;
select lives_ok(
  $$select public.remove_player(
    'QATEST',
    '00000000-0000-0000-0000-000000000108'
  )$$,
  'host can remove a stalled player after the preload deadline'
);
reset role;
select is(
  (select phase::text from public.rooms where code = 'QATEST'),
  'countdown',
  'stalled player removal starts countdown for the ready players'
);

select * from finish();
rollback;
