import type { RealtimeChannel } from "@supabase/supabase-js";
import {
  DEFAULT_SETTINGS,
  isRoomState,
  type AnswerChoice,
  type GameSettings,
  type RoomState,
} from "@/lib/game/types";
import { ensureAnonymousSession, getSupabaseBrowserClient } from "./client";
type RoomRpcName =
  | "create_room"
  | "join_room"
  | "get_room_state"
  | "heartbeat"
  | "set_ready"
  | "update_settings"
  | "start_game"
  | "submit_answer"
  | "remove_player"
  | "play_again"
  | "mark_game_audio_ready"
  | "mark_round_audio_ready";

const safeMessages: Record<string, string> = {
  AUTH_REQUIRED: "Your game session expired. Refresh and try again.",
  BACKEND_NOT_CONFIGURED: "The multiplayer service is not configured yet.",
  INVALID_NICKNAME: "Use a nickname between 2 and 20 characters.",
  INVALID_ROOM_CODE: "Enter the six-character room code.",
  ROOM_CODE_UNAVAILABLE: "A room code could not be created. Please try again.",
  RATE_LIMITED: "Too many attempts. Wait a few minutes and try again.",
  ROOM_NOT_FOUND: "That room does not exist or has expired.",
  NOT_IN_ROOM: "This browser is not a member of that room.",
  NICKNAME_TAKEN: "That nickname is already used in this room.",
  ROOM_FULL: "That room is full.",
  GAME_ALREADY_STARTED: "That game has already started.",
  LOBBY_CLOSED: "Lobby changes are closed after the game starts.",
  HOST_ONLY: "Only the room host can do that.",
  NEED_TWO_PLAYERS: "At least two players are required.",
  PLAYERS_NOT_READY: "Every connected player must be ready.",
  NOT_ENOUGH_AI_TRACKS: "Import at least one owned Suno track before starting.",
  NOT_ENOUGH_TRACKS: "That music library does not have enough enabled tracks.",
  ANSWER_WINDOW_CLOSED: "The answer window is closed.",
  ANSWER_LOCKED: "Your answer is locked for this round.",
  PLAYER_NOT_FOUND: "That player is no longer in the room.",
  HOST_CANNOT_REMOVE_SELF: "Use Leave room if you want to exit.",
  GAME_NOT_FINISHED: "Finish the current game before playing again.",
  INVALID_SETTINGS: "One or more game settings are invalid.",
  INVALID_RESPONSE: "The game service returned an invalid response.",
  ROUND_NOT_ACTIVE: "That round is no longer active.",
  AUDIO_NOT_READY: "The round audio is still preparing.",
  AUDIO_DOWNLOAD_FAILED:
    "Some playlist audio could not be downloaded. Completed tracks were kept; retry to fetch only the missing tracks.",
  PREPARATION_FAILED:
    "The next track could not be prepared. The host can retry.",
  PREPARATION_NOT_CONFIGURED:
    "Track preparation is not configured on the server.",
  JAMENDO_NOT_CONFIGURED: "Jamendo is not configured on the server.",
  PREPARATION_TIMEOUT: "Track preparation timed out. The host can retry.",
  SKIP_NOT_AVAILABLE: "There is no stalled track to skip right now.",
  NO_ELIGIBLE_JAMENDO_TRACK:
    "No downloadable Jamendo track was available. The host can retry.",
};

export class GameApiError extends Error {
  constructor(
    public readonly code: string,
    message = safeMessages[code] ||
      "The game service could not complete that action.",
  ) {
    super(message);
    this.name = "GameApiError";
  }
}

function toGameError(error: unknown): GameApiError {
  if (error instanceof GameApiError) return error;
  const raw =
    error instanceof Error
      ? error.message
      : typeof error === "object" &&
          error !== null &&
          "message" in error &&
          typeof error.message === "string"
        ? error.message
        : String(error);
  const code = Object.keys(safeMessages).find((candidate) =>
    raw.includes(candidate),
  );
  return new GameApiError(code || "UNKNOWN");
}

async function rpcRoomState(
  functionName: RoomRpcName,
  parameters: Record<string, unknown>,
): Promise<RoomState> {
  try {
    await ensureAnonymousSession();
    const client = getSupabaseBrowserClient();
    const { data, error } = await client.rpc(functionName, parameters as never);
    if (error) throw error;
    if (!isRoomState(data)) throw new GameApiError("INVALID_RESPONSE");
    return data;
  } catch (error) {
    throw toGameError(error);
  }
}

export async function createRoom(
  nickname: string,
  settings: GameSettings = DEFAULT_SETTINGS,
): Promise<RoomState> {
  return rpcRoomState("create_room", {
    p_nickname: nickname,
    p_settings: settings,
  });
}

export async function joinRoom(
  code: string,
  nickname: string,
): Promise<RoomState> {
  return rpcRoomState("join_room", { p_code: code, p_nickname: nickname });
}

export async function getRoomState(code: string): Promise<RoomState> {
  return rpcRoomState("get_room_state", { p_code: code });
}

export async function heartbeat(code: string): Promise<RoomState> {
  return rpcRoomState("heartbeat", { p_code: code });
}

export async function setReady(
  code: string,
  ready: boolean,
): Promise<RoomState> {
  return rpcRoomState("set_ready", { p_code: code, p_ready: ready });
}

export async function updateSettings(
  code: string,
  settings: GameSettings,
): Promise<RoomState> {
  return rpcRoomState("update_settings", {
    p_code: code,
    p_settings: settings,
  });
}

export async function startGame(code: string): Promise<RoomState> {
  return rpcRoomState("start_game", { p_code: code });
}

export async function submitAnswer(
  code: string,
  choice: AnswerChoice,
): Promise<RoomState> {
  return rpcRoomState("submit_answer", { p_code: code, p_choice: choice });
}

export async function markRoundAudioReady(
  code: string,
  roundId: string,
): Promise<RoomState> {
  return rpcRoomState("mark_round_audio_ready", {
    p_code: code,
    p_round_id: roundId,
  });
}

async function authenticatedFetch(
  input: RequestInfo | URL,
  init: RequestInit = {},
): Promise<Response> {
  await ensureAnonymousSession();
  const client = getSupabaseBrowserClient();
  const { data, error } = await client.auth.getSession();
  if (error || !data.session) throw new GameApiError("AUTH_REQUIRED");
  return fetch(input, {
    ...init,
    headers: {
      ...init.headers,
      Authorization: `Bearer ${data.session.access_token}`,
    },
  });
}

export interface PreparationResponse {
  status: "claimed" | "preparing" | "ready" | "failed" | string;
  round_id?: string;
  error_code?: string;
  total_count?: number;
  ready_count?: number;
  failed_count?: number;
  playlist_revision?: number;
  player_ready_count?: number;
  player_required_count?: number;
  audio_preload_deadline?: string | null;
  timed_out?: boolean;
  stalled_players?: Array<{ id: string; nickname: string }>;
}

export async function prepareRound(
  code: string,
  forceRetry = false,
): Promise<PreparationResponse> {
  const response = await authenticatedFetch(
    `/api/rooms/${encodeURIComponent(code)}/prepare${forceRetry ? "?retry=1" : ""}`,
    { method: "POST" },
  );
  const payload = (await response.json()) as PreparationResponse;
  if (!response.ok && response.status !== 503) {
    throw new GameApiError(payload.error_code || "PREPARATION_FAILED");
  }
  return payload;
}

export async function skipPreparingTrack(
  code: string,
): Promise<PreparationResponse> {
  const response = await authenticatedFetch(
    `/api/rooms/${encodeURIComponent(code)}/prepare?skip=1`,
    { method: "POST" },
  );
  const payload = (await response.json()) as PreparationResponse;
  if (!response.ok && response.status !== 503) {
    throw new GameApiError(payload.error_code || "PREPARATION_FAILED");
  }
  return payload;
}

export async function getRoundAudioUrl(
  code: string,
  roundId: string,
): Promise<string> {
  const response = await authenticatedFetch(
    `/api/rooms/${encodeURIComponent(code)}/rounds/${encodeURIComponent(roundId)}/audio`,
  );
  const payload = (await response.json()) as {
    audio_url?: string;
    error_code?: string;
  };
  if (!response.ok || !payload.audio_url) {
    throw new GameApiError(payload.error_code || "AUDIO_NOT_READY");
  }
  return payload.audio_url;
}

export interface GameAudioTrack {
  round_id: string;
  audio_url: string;
}

export async function getGameAudioPlaylist(
  code: string,
): Promise<GameAudioTrack[]> {
  const response = await authenticatedFetch(
    `/api/rooms/${encodeURIComponent(code)}/playlist`,
  );
  const payload = (await response.json()) as {
    tracks?: GameAudioTrack[];
    error_code?: string;
  };
  if (!response.ok || !payload.tracks) {
    throw new GameApiError(payload.error_code || "AUDIO_NOT_READY");
  }
  return payload.tracks;
}

export async function markGameAudioReady(code: string): Promise<RoomState> {
  return rpcRoomState("mark_game_audio_ready", { p_code: code });
}

export async function removePlayer(
  code: string,
  playerId: string,
): Promise<RoomState> {
  return rpcRoomState("remove_player", { p_code: code, p_player_id: playerId });
}

export async function playAgain(code: string): Promise<RoomState> {
  return rpcRoomState("play_again", { p_code: code });
}

export async function leaveRoom(code: string): Promise<void> {
  try {
    await ensureAnonymousSession();
    const { error } = await getSupabaseBrowserClient().rpc("leave_room", {
      p_code: code,
    });
    if (error) throw error;
  } catch (error) {
    throw toGameError(error);
  }
}

export function subscribeToRoom(
  roomId: string,
  onChange: () => void,
): RealtimeChannel {
  return getSupabaseBrowserClient()
    .channel(`room:${roomId}`)
    .on(
      "postgres_changes",
      {
        event: "INSERT",
        schema: "public",
        table: "room_events",
        filter: `room_id=eq.${roomId}`,
      },
      onChange,
    )
    .subscribe();
}

export async function unsubscribeFromRoom(
  channel: RealtimeChannel,
): Promise<void> {
  await getSupabaseBrowserClient().removeChannel(channel);
}
