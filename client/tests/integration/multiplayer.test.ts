import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { RoomState } from "@/lib/game/types";

const supabaseUrl =
  process.env.E2E_SUPABASE_URL || process.env.NEXT_PUBLIC_SUPABASE_URL;
const supabaseKey =
  process.env.E2E_SUPABASE_PUBLISHABLE_KEY ||
  process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
const serviceRoleKey = process.env.E2E_SUPABASE_SERVICE_ROLE_KEY;

function isolatedClient(): SupabaseClient {
  if (!supabaseUrl || !supabaseKey) {
    throw new Error(
      "Set E2E_SUPABASE_URL and E2E_SUPABASE_PUBLISHABLE_KEY, or the matching NEXT_PUBLIC values.",
    );
  }
  return createClient(supabaseUrl, supabaseKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

async function signIn(client: SupabaseClient) {
  const { error } = await client.auth.signInAnonymously();
  if (error) throw error;
}

async function stateFor(
  client: SupabaseClient,
  code: string,
): Promise<RoomState> {
  const { data, error } = await client.rpc("get_room_state", { p_code: code });
  if (error) throw error;
  return data as RoomState;
}

async function waitForPhase(
  client: SupabaseClient,
  code: string,
  phase: RoomState["room"]["phase"],
  timeoutMs = 20_000,
): Promise<RoomState> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const state = await stateFor(client, code);
    if (state.room.phase === phase) return state;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`Timed out waiting for phase ${phase}`);
}

async function prepareDemoGame(
  admin: SupabaseClient,
  host: SupabaseClient,
  players: SupabaseClient[],
  code: string,
): Promise<RoomState> {
  const preparing = await waitForPhase(host, code, "preparing");
  const user = (await host.auth.getUser()).data.user;
  expect(user).not.toBeNull();
  let status = "";
  for (let attempt = 0; attempt < preparing.round!.total; attempt += 1) {
    const prepared = await admin.rpc("service_claim_round_preparation", {
      p_code: code,
      p_user_id: user!.id,
      p_force_retry: false,
    });
    expect(prepared.error).toBeNull();
    status = (prepared.data as { status: string }).status;
  }
  expect(status).toBe("ready");
  for (const player of players) {
    const ready = await player.rpc("mark_game_audio_ready", {
      p_code: code,
    });
    expect(ready.error).toBeNull();
  }
  return waitForPhase(host, code, "playing");
}

async function expectRpcError(
  client: SupabaseClient,
  name: string,
  args: Record<string, unknown>,
  code: string,
) {
  const { error } = await client.rpc(name, args);
  expect(error?.message).toContain(code);
}

describe.skipIf(!supabaseUrl || !supabaseKey || !serviceRoleKey)(
  "hosted multiplayer contract",
  () => {
    const host = isolatedClient();
    const guest = isolatedClient();
    const duplicate = isolatedClient();
    const admin =
      supabaseUrl && serviceRoleKey
        ? createClient(supabaseUrl, serviceRoleKey, {
            auth: { persistSession: false, autoRefreshToken: false },
          })
        : null;
    let roomCode = "";

    beforeAll(async () => {
      await Promise.all([signIn(host), signIn(guest), signIn(duplicate)]);
    });

    afterAll(async () => {
      if (!roomCode) return;
      await Promise.allSettled([
        host.rpc("leave_room", { p_code: roomCode }),
        guest.rpc("leave_room", { p_code: roomCode }),
      ]);
    });

    it("enforces room authorization, answer locking, deadlines, and scoring", async () => {
      const suffix = Date.now().toString(36).slice(-5);
      const hostName = `Host ${suffix}`;
      const guestName = `Guest ${suffix}`;

      const created = await host.rpc("create_room", {
        p_nickname: hostName,
        p_settings: {
          round_count: 3,
          round_duration_seconds: 10,
          reveal_duration_seconds: 4,
          negative_points: true,
          allow_answer_changes: false,
          music_volume: 0.8,
          song_pack: "demo",
        },
      });
      expect(created.error).toBeNull();
      const createdState = created.data as RoomState;
      roomCode = createdState.room.code;
      expect(roomCode).toMatch(/^[A-HJ-NP-Z2-9]{6}$/);

      await expectRpcError(
        duplicate,
        "join_room",
        { p_code: roomCode, p_nickname: hostName },
        "NICKNAME_TAKEN",
      );
      await expectRpcError(
        duplicate,
        "join_room",
        { p_code: "AAAAAA", p_nickname: "Nobody" },
        "ROOM_NOT_FOUND",
      );

      const joined = await guest.rpc("join_room", {
        p_code: roomCode,
        p_nickname: guestName,
      });
      expect(joined.error).toBeNull();
      expect((joined.data as RoomState).players).toHaveLength(2);

      await expectRpcError(
        guest,
        "update_settings",
        { p_code: roomCode, p_settings: { round_count: 3 } },
        "HOST_ONLY",
      );
      await expectRpcError(
        guest,
        "start_game",
        { p_code: roomCode },
        "HOST_ONLY",
      );

      for (const client of [host, guest]) {
        const ready = await client.rpc("set_ready", {
          p_code: roomCode,
          p_ready: true,
        });
        expect(ready.error).toBeNull();
      }

      const started = await host.rpc("start_preloaded_game", {
        p_code: roomCode,
      });
      expect(started.error).toBeNull();
      expect((started.data as RoomState).room.phase).toBe("preparing");

      const directRead = await guest.from("answers").select("*");
      expect(directRead.error).not.toBeNull();

      const hostPlaying = await prepareDemoGame(
        admin!,
        host,
        [host, guest],
        roomCode,
      );
      const guestPlaying = await waitForPhase(guest, roomCode, "playing");
      expect(hostPlaying.round?.id).toBe(guestPlaying.round?.id);
      expect(hostPlaying.round?.audio_url).toMatch(
        /^\/audio\/track-\d{3}\.wav$/,
      );
      expect(hostPlaying.round?.correct_answer).toBeNull();
      expect(hostPlaying.round?.title).toBeNull();
      expect(hostPlaying.round?.artist).toBeNull();
      expect(hostPlaying.round?.provider).toBeNull();
      expect(hostPlaying.round?.source_url).toBeNull();
      expect(hostPlaying.round?.license_url).toBeNull();
      expect(hostPlaying.round?.genres).toBeNull();

      const hostAnswer = await host.rpc("submit_answer", {
        p_code: roomCode,
        p_choice: "ai",
      });
      expect(hostAnswer.error).toBeNull();
      await expectRpcError(
        host,
        "submit_answer",
        { p_code: roomCode, p_choice: "real" },
        "ANSWER_LOCKED",
      );
      const allSubmittedAt = Date.now();
      const guestAnswer = await guest.rpc("submit_answer", {
        p_code: roomCode,
        p_choice: "real",
      });
      expect(guestAnswer.error).toBeNull();

      const session = (await guest.auth.getSession()).data.session;
      expect(session).not.toBeNull();
      const reconnected = isolatedClient();
      const restored = await reconnected.auth.setSession({
        access_token: session!.access_token,
        refresh_token: session!.refresh_token,
      });
      expect(restored.error).toBeNull();
      const restoredState = await stateFor(reconnected, roomCode);
      expect(restoredState.me.id).toBe(guestPlaying.me.id);
      expect(restoredState.round?.own_answer).toBe("real");

      const hostReveal = await waitForPhase(host, roomCode, "reveal");
      const earlyRevealDelay = Date.now() - allSubmittedAt;
      expect(earlyRevealDelay).toBeGreaterThanOrEqual(2_500);
      expect(earlyRevealDelay).toBeLessThan(7_000);
      const guestReveal = await stateFor(guest, roomCode);
      expect(hostReveal.round?.correct_answer).toMatch(/^(ai|real)$/);
      expect(hostReveal.round?.title).toBeTruthy();
      expect(hostReveal.round?.artist).toBeTruthy();
      expect(hostReveal.round?.provider).toBe("project");
      expect(hostReveal.round?.source_url).toMatch(/^https:\/\//);
      expect(hostReveal.round?.license_url).toBeNull();
      expect(hostReveal.round?.genres).toEqual([]);
      expect(hostReveal.round?.reveal_description).toBeTruthy();
      expect(hostReveal.round_history).toHaveLength(1);
      const points = [
        hostReveal.round?.own_points,
        guestReveal.round?.own_points,
      ].map(Number);
      expect(Math.min(...points)).toBe(-500);
      expect(points.some((score) => score >= 1000)).toBe(true);
      expect(hostReveal.leaderboard[0].score).toBeGreaterThanOrEqual(
        hostReveal.leaderboard[1].score,
      );

      await expectRpcError(
        guest,
        "submit_answer",
        { p_code: roomCode, p_choice: "ai" },
        "ANSWER_WINDOW_CLOSED",
      );
    });

    it("completes a solo game after preparing the full playlist once", async () => {
      const solo = isolatedClient();
      await signIn(solo);
      const created = await solo.rpc("create_room", {
        p_nickname: `Solo ${Date.now().toString(36).slice(-5)}`,
        p_settings: {
          round_count: 3,
          round_duration_seconds: 10,
          reveal_duration_seconds: 4,
          negative_points: true,
          allow_answer_changes: false,
          music_volume: 0.8,
          song_pack: "demo",
        },
      });
      expect(created.error).toBeNull();
      const code = (created.data as RoomState).room.code;
      expect(
        (await solo.rpc("set_ready", { p_code: code, p_ready: true })).error,
      ).toBeNull();
      const started = await solo.rpc("start_preloaded_game", { p_code: code });
      expect(started.error).toBeNull();

      let playing = await prepareDemoGame(admin!, solo, [solo], code);
      for (let roundNumber = 1; roundNumber <= 3; roundNumber += 1) {
        if (roundNumber > 1) {
          playing = await waitForPhase(solo, code, "playing");
        }
        expect(playing.round?.number).toBe(roundNumber);
        const answer = await solo.rpc("submit_answer", {
          p_code: code,
          p_choice: "ai",
        });
        expect(answer.error).toBeNull();
        const reveal = await waitForPhase(solo, code, "reveal", 8_000);
        expect(reveal.round?.title).toBeTruthy();
      }

      const finished = await waitForPhase(solo, code, "finished", 12_000);
      expect(finished.round_history).toHaveLength(3);
      expect(
        new Set(finished.round_history.map((round) => round.title)).size,
      ).toBe(3);
      const realRounds = finished.round_history.filter(
        (round) => round.answer_type === "real",
      ).length;
      const aiRounds = finished.round_history.length - realRounds;
      expect(Math.abs(realRounds - aiRounds)).toBeLessThanOrEqual(1);
      expect(finished.leaderboard).toHaveLength(1);
      await solo.rpc("leave_room", { p_code: code });
    }, 60_000);
  },
);
