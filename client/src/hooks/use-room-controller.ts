"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { clearGameAudioCache } from "@/lib/audio/game-audio-cache";
import type { AnswerChoice, GameSettings, RoomState } from "@/lib/game/types";
import {
  GameApiError,
  getRoomState,
  heartbeat,
  leaveRoom,
  markRoundAudioReady,
  playAgain,
  prepareRound,
  removePlayer,
  setReady,
  skipPreparingTrack,
  startGame,
  submitAnswer,
  subscribeToRoom,
  unsubscribeFromRoom,
  updateSettings,
} from "@/lib/supabase/game-api";

type ActionName =
  | "ready"
  | "settings"
  | "start"
  | "answer"
  | "audio"
  | "remove"
  | "leave"
  | "again"
  | "retry"
  | "skip"
  | null;

export interface PreparationProgress {
  stage: "server" | "download" | "failed";
  serverReady: number;
  downloaded: number;
  total: number;
  playerReady: number;
  playerRequired: number;
  timedOut: boolean;
  stalledPlayers: Array<{ id: string; nickname: string }>;
}

export function useRoomController(code: string) {
  const [state, setState] = useState<RoomState | null>(null);
  const [fatalError, setFatalError] = useState<GameApiError | null>(null);
  const [actionError, setActionError] = useState("");
  const [connectionLost, setConnectionLost] = useState(false);
  const [busyAction, setBusyAction] = useState<ActionName>(null);
  const [serverOffsetMs, setServerOffsetMs] = useState(0);
  const [preparationProgress, setPreparationProgress] =
    useState<PreparationProgress | null>(null);
  const [preparationAttempt, setPreparationAttempt] = useState(0);
  const refreshInFlight = useRef(false);
  const preparationInFlight = useRef(false);
  const mounted = useRef(true);
  const isPreparing = state?.room.phase === "preparing";

  const acceptState = useCallback(
    (nextState: RoomState, startedAt = Date.now()) => {
      if (!mounted.current) return;
      const midpoint = (startedAt + Date.now()) / 2;
      setServerOffsetMs(new Date(nextState.server_now).getTime() - midpoint);
      setState(nextState);
      if (nextState.room.phase !== "preparing") {
        setPreparationProgress(null);
      }
      setFatalError(null);
      setConnectionLost(false);
    },
    [],
  );

  const refresh = useCallback(
    async (sendHeartbeat = false) => {
      if (refreshInFlight.current) return;
      refreshInFlight.current = true;
      const startedAt = Date.now();
      try {
        const next = sendHeartbeat
          ? await heartbeat(code)
          : await getRoomState(code);
        acceptState(next, startedAt);
      } catch (error) {
        const gameError =
          error instanceof GameApiError ? error : new GameApiError("UNKNOWN");
        if (!mounted.current) return;
        if (
          ["ROOM_NOT_FOUND", "NOT_IN_ROOM", "BACKEND_NOT_CONFIGURED"].includes(
            gameError.code,
          )
        ) {
          setFatalError(gameError);
        } else {
          setConnectionLost(true);
        }
      } finally {
        refreshInFlight.current = false;
      }
    },
    [acceptState, code],
  );

  useEffect(() => {
    mounted.current = true;
    const initialRefresh = window.setTimeout(() => void refresh(true), 0);
    return () => {
      window.clearTimeout(initialRefresh);
      mounted.current = false;
    };
  }, [refresh]);

  useEffect(() => {
    if (!state?.room.id) return;
    const channel = subscribeToRoom(state.room.id, () => void refresh(false));
    return () => {
      void unsubscribeFromRoom(channel);
    };
  }, [refresh, state?.room.id]);

  useEffect(() => {
    const phase = state?.room.phase;
    const delay = phase === "lobby" || phase === "finished" ? 3000 : 750;
    const interval = window.setInterval(() => void refresh(false), delay);
    return () => window.clearInterval(interval);
  }, [refresh, state?.room.phase]);

  useEffect(() => {
    if (!isPreparing) return;

    let cancelled = false;
    let retryTimer: number | null = null;
    const schedule = (delay: number) => {
      if (cancelled) return;
      retryTimer = window.setTimeout(() => void requestPreparation(), delay);
    };
    const requestPreparation = async (): Promise<void> => {
      if (preparationInFlight.current) {
        schedule(100);
        return;
      }
      preparationInFlight.current = true;
      try {
        const result = await prepareRound(code);
        const total = Math.max(
          0,
          result.total_count ?? state?.round?.total ?? 0,
        );
        const serverReady = Math.max(0, result.ready_count ?? 0);
        setPreparationProgress((current) => ({
          stage: "server",
          serverReady,
          downloaded: current?.downloaded ?? 0,
          total,
          playerReady: result.player_ready_count ?? current?.playerReady ?? 0,
          playerRequired:
            result.player_required_count ?? current?.playerRequired ?? 0,
          timedOut: result.timed_out ?? false,
          stalledPlayers: result.stalled_players ?? [],
        }));
        if (result.status === "failed") {
          setPreparationProgress({
            stage: "failed",
            serverReady,
            downloaded: 0,
            total,
            playerReady: result.player_ready_count ?? 0,
            playerRequired: result.player_required_count ?? 0,
            timedOut: result.timed_out ?? false,
            stalledPlayers: result.stalled_players ?? [],
          });
          setActionError(
            new GameApiError(result.error_code || "PREPARATION_FAILED").message,
          );
          return;
        }
        if (result.status === "ready") {
          setActionError("");
          setPreparationProgress({
            stage: "download",
            serverReady: total,
            downloaded: 0,
            total: 1,
            playerReady: result.player_ready_count ?? 0,
            playerRequired: result.player_required_count ?? 0,
            timedOut: result.timed_out ?? false,
            stalledPlayers: result.stalled_players ?? [],
          });
          await refresh(false);
          if (!cancelled) schedule(500);
        } else {
          schedule(result.status === "preparing" ? 1_000 : 50);
        }
      } catch (error) {
        if (cancelled) return;
        const gameError =
          error instanceof GameApiError
            ? error
            : new GameApiError(
                error instanceof Error &&
                  error.message === "AUDIO_DOWNLOAD_FAILED"
                  ? "AUDIO_DOWNLOAD_FAILED"
                  : "PREPARATION_FAILED",
              );
        setPreparationProgress((current) =>
          current ? { ...current, stage: "failed" } : current,
        );
        setActionError(gameError.message);
        schedule(2_000);
      } finally {
        preparationInFlight.current = false;
      }
    };
    void requestPreparation();
    return () => {
      cancelled = true;
      if (retryTimer !== null) window.clearTimeout(retryTimer);
    };
  }, [
    acceptState,
    code,
    isPreparing,
    preparationAttempt,
    refresh,
    state?.round?.id,
    state?.round?.total,
  ]);

  useEffect(
    () => () => {
      clearGameAudioCache(code);
    },
    [code],
  );

  useEffect(() => {
    const interval = window.setInterval(() => void refresh(true), 10_000);
    return () => window.clearInterval(interval);
  }, [refresh]);

  useEffect(() => {
    const handleOffline = () => setConnectionLost(true);
    const handleOnline = () => void refresh(true);
    window.addEventListener("offline", handleOffline);
    window.addEventListener("online", handleOnline);
    return () => {
      window.removeEventListener("offline", handleOffline);
      window.removeEventListener("online", handleOnline);
    };
  }, [refresh]);

  const runAction = useCallback(
    async (
      name: Exclude<ActionName, null>,
      action: () => Promise<RoomState>,
    ) => {
      setBusyAction(name);
      setActionError("");
      const startedAt = Date.now();
      try {
        acceptState(await action(), startedAt);
        return true;
      } catch (error) {
        const gameError =
          error instanceof GameApiError ? error : new GameApiError("UNKNOWN");
        setActionError(gameError.message);
        if (
          gameError.code === "ROOM_NOT_FOUND" ||
          gameError.code === "NOT_IN_ROOM"
        ) {
          setFatalError(gameError);
        }
        return false;
      } finally {
        setBusyAction(null);
      }
    },
    [acceptState],
  );

  return {
    state,
    fatalError,
    actionError,
    clearActionError: () => setActionError(""),
    connectionLost,
    busyAction,
    preparationProgress,
    serverOffsetMs,
    refresh: () => refresh(true),
    toggleReady: (ready: boolean) =>
      runAction("ready", () => setReady(code, ready)),
    saveSettings: (settings: GameSettings) =>
      runAction("settings", () => updateSettings(code, settings)),
    beginGame: () => runAction("start", () => startGame(code)),
    answer: (choice: AnswerChoice) =>
      runAction("answer", () => submitAnswer(code, choice)),
    reportAudioReady: (roundId: string) =>
      runAction("audio", () => markRoundAudioReady(code, roundId)),
    retryPreparation: async () => {
      setBusyAction("retry");
      setActionError("");
      try {
        const result = await prepareRound(code, true);
        if (result.status === "failed") {
          setActionError(
            new GameApiError(result.error_code || "PREPARATION_FAILED").message,
          );
          return false;
        }
        await refresh(false);
        setPreparationAttempt((current) => current + 1);
        return true;
      } catch (error) {
        const gameError =
          error instanceof GameApiError
            ? error
            : new GameApiError("PREPARATION_FAILED");
        setActionError(gameError.message);
        return false;
      } finally {
        setBusyAction(null);
      }
    },
    skipPreparation: async () => {
      setBusyAction("skip");
      setActionError("");
      try {
        const result = await skipPreparingTrack(code);
        if (result.status === "failed") {
          setActionError(
            new GameApiError(result.error_code || "PREPARATION_FAILED").message,
          );
          return false;
        }
        clearGameAudioCache(code);
        await refresh(false);
        setPreparationAttempt((current) => current + 1);
        return true;
      } catch (error) {
        const gameError =
          error instanceof GameApiError
            ? error
            : new GameApiError("PREPARATION_FAILED");
        setActionError(gameError.message);
        return false;
      } finally {
        setBusyAction(null);
      }
    },
    remove: (playerId: string) =>
      runAction("remove", () => removePlayer(code, playerId)),
    again: () => {
      clearGameAudioCache(code);
      return runAction("again", () => playAgain(code));
    },
    leave: async () => {
      setBusyAction("leave");
      setActionError("");
      try {
        await leaveRoom(code);
        clearGameAudioCache(code);
        return true;
      } catch (error) {
        const gameError =
          error instanceof GameApiError ? error : new GameApiError("UNKNOWN");
        setActionError(gameError.message);
        return false;
      } finally {
        setBusyAction(null);
      }
    },
  };
}
