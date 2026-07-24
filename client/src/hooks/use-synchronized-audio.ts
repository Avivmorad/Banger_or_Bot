"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import {
  getGameAudioElement,
  getPrefetchedAudioUrl,
} from "@/lib/audio/game-audio-cache";
import type { ActiveRound, RoomPhase } from "@/lib/game/types";
import { getRoundAudioUrl } from "@/lib/supabase/game-api";

export type AudioState =
  "idle" | "loading" | "ready" | "playing" | "blocked" | "error" | "ended";

export function useSynchronizedAudio({
  code,
  round,
  phase,
  serverOffsetMs,
  volume,
  onAudioReady,
}: {
  code: string;
  round: ActiveRound | null;
  phase: RoomPhase;
  serverOffsetMs: number;
  volume: number;
  onAudioReady: (roundId: string) => Promise<boolean>;
}) {
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const objectUrlRef = useRef<string | null>(null);
  const acknowledgedRoundRef = useRef<string | null>(null);
  const onAudioReadyRef = useRef(onAudioReady);
  const [audioState, setAudioState] = useState<AudioState>("idle");
  const [muted, setMuted] = useState(false);
  const [progress, setProgress] = useState(0);
  const [loadAttempt, setLoadAttempt] = useState(0);
  const roundId = round?.id ?? null;
  const fallbackAudioUrl = round?.audio_url ?? null;
  const audioAvailable = round?.audio_available ?? false;
  const startsAt = round?.starts_at ?? null;
  const audioDurationSeconds = round?.audio_duration_seconds ?? 0;

  useEffect(() => {
    onAudioReadyRef.current = onAudioReady;
  }, [onAudioReady]);

  const synchronize = useCallback(
    async (userInitiated = false) => {
      const audio = audioRef.current;
      if (!audio || !roundId || !startsAt) return;
      audio.muted = muted;
      audio.volume = Math.max(0, Math.min(1, volume));

      if (phase !== "playing") {
        audio.pause();
        if (phase === "countdown") audio.currentTime = 0;
        return;
      }

      const elapsedSeconds = Math.max(
        0,
        (Date.now() + serverOffsetMs - new Date(startsAt).getTime()) / 1000,
      );
      const maximum = Number.isFinite(audio.duration)
        ? Math.max(0, audio.duration - 0.05)
        : audioDurationSeconds;
      const target = Math.min(elapsedSeconds, maximum);
      if (Math.abs(audio.currentTime - target) > 0.65)
        audio.currentTime = target;

      try {
        await audio.play();
        setAudioState("playing");
      } catch {
        setAudioState(userInitiated ? "error" : "blocked");
      }
    },
    [
      audioDurationSeconds,
      muted,
      phase,
      roundId,
      serverOffsetMs,
      startsAt,
      volume,
    ],
  );

  useEffect(() => {
    if (!roundId || !audioAvailable) {
      audioRef.current?.pause();
      audioRef.current = null;
      return;
    }

    let cancelled = false;
    const cleanupAudio = () => {
      audioRef.current?.pause();
      audioRef.current = null;
      if (objectUrlRef.current) URL.revokeObjectURL(objectUrlRef.current);
      objectUrlRef.current = null;
    };
    cleanupAudio();
    const loadingUpdate = window.setTimeout(() => {
      setAudioState("loading");
      setProgress(0);
    }, 0);

    void (async () => {
      try {
        const prefetchedUrl = getPrefetchedAudioUrl(code, roundId);
        let playableUrl = prefetchedUrl;
        if (!playableUrl) {
          const sourceUrl =
            fallbackAudioUrl || (await getRoundAudioUrl(code, roundId));
          const response = await fetch(sourceUrl, { cache: "no-store" });
          if (!response.ok) throw new Error("AUDIO_DOWNLOAD_FAILED");
          const blob = await response.blob();
          if (cancelled || blob.size === 0)
            throw new Error("AUDIO_DOWNLOAD_FAILED");
          playableUrl = URL.createObjectURL(blob);
          objectUrlRef.current = playableUrl;
        }
        const audio = getGameAudioElement();
        audio.src = playableUrl;
        audio.preload = "auto";
        audioRef.current = audio;
        await new Promise<void>((resolve, reject) => {
          const handleReady = () => resolve();
          const handleError = () => reject(new Error("AUDIO_DECODE_FAILED"));
          audio.addEventListener("canplaythrough", handleReady, { once: true });
          audio.addEventListener("error", handleError, { once: true });
          audio.load();
        });
        if (cancelled) return;
        audio.addEventListener("ended", () => setAudioState("ended"), {
          once: true,
        });
        setAudioState("ready");
        if (acknowledgedRoundRef.current !== roundId) {
          acknowledgedRoundRef.current = roundId;
          const acknowledged = await onAudioReadyRef.current(roundId);
          if (!acknowledged) acknowledgedRoundRef.current = null;
        }
      } catch {
        if (!cancelled) setAudioState("error");
      }
    })();

    return () => {
      cancelled = true;
      window.clearTimeout(loadingUpdate);
      cleanupAudio();
    };
  }, [audioAvailable, code, fallbackAudioUrl, loadAttempt, roundId]);

  useEffect(() => {
    const syncTimer = window.setTimeout(() => void synchronize(false), 0);
    return () => window.clearTimeout(syncTimer);
  }, [synchronize]);

  useEffect(() => {
    const interval = window.setInterval(() => {
      const audio = audioRef.current;
      if (!audio || !Number.isFinite(audio.duration) || audio.duration <= 0)
        return;
      setProgress(Math.max(0, Math.min(1, audio.currentTime / audio.duration)));
      if (phase === "playing") void synchronize(false);
    }, 500);
    return () => window.clearInterval(interval);
  }, [phase, synchronize]);

  return {
    audioState: roundId ? audioState : "idle",
    progress: roundId ? progress : 0,
    muted,
    activate: () => synchronize(true),
    retry: () => setLoadAttempt((current) => current + 1),
    toggleMuted: () => setMuted((current) => !current),
  };
}
