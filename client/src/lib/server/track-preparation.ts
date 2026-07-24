import "server-only";

import { randomInt, randomUUID } from "node:crypto";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  downloadAudio,
  sha256Hex,
  validateRemoteAudioUrl,
} from "./audio-files";
import { getServerConfig, getSupabaseAdminClient } from "./supabase-admin";

interface PreparationClaim {
  status: "claimed" | "preparing" | "ready" | "failed" | string;
  round_id?: string;
  answer_type?: "real" | "ai";
  error_code?: string;
  used_provider_track_ids?: string[];
  storage_path?: string;
  total_count?: number;
  ready_count?: number;
  failed_count?: number;
}

interface JamendoTrack {
  id: string;
  name: string;
  duration: number;
  artist_name: string;
  audiodownload: string;
  audiodownload_allowed: boolean;
  shareurl?: string;
  shorturl?: string;
  license_ccurl?: string;
  musicinfo?: { tags?: { genres?: string[] } };
}

interface JamendoResponse {
  headers?: {
    status?: string;
    results_count?: number;
    results_fullcount?: number;
  };
  results?: JamendoTrack[];
}

const JAMENDO_CATALOG_FALLBACK_SIZE = 10_000;
let jamendoCatalogSize: number | null = null;

const PUBLIC_ERROR_CODES = new Set([
  "JAMENDO_NOT_CONFIGURED",
  "JAMENDO_UNAVAILABLE",
  "JAMENDO_EMPTY",
  "NO_ELIGIBLE_JAMENDO_TRACK",
  "PREPARATION_TIMEOUT",
]);

function publicPreparationError(error: unknown): string {
  if (error instanceof Error && error.name === "AbortError") {
    return "PREPARATION_TIMEOUT";
  }
  const code = error instanceof Error ? error.message : "";
  return PUBLIC_ERROR_CODES.has(code) ? code : "PREPARATION_FAILED";
}

function normalizedHttpsUrl(raw: string | undefined): string | null {
  if (!raw) return null;
  try {
    const url = new URL(raw);
    if (url.protocol === "http:") url.protocol = "https:";
    return url.protocol === "https:" ? url.toString() : null;
  } catch {
    return null;
  }
}

function isJamendoDownload(raw: string): boolean {
  try {
    const host = validateRemoteAudioUrl(raw).hostname.toLowerCase();
    return host === "jamendo.com" || host.endsWith(".jamendo.com");
  } catch {
    return false;
  }
}

async function rpc<T>(
  client: SupabaseClient,
  name: string,
  parameters: Record<string, unknown>,
): Promise<T> {
  const { data, error } = await client.rpc(name, parameters);
  if (error) throw error;
  return data as T;
}

function jamendoParams(clientId: string) {
  return new URLSearchParams({
    client_id: clientId,
    format: "json",
    type: "single albumtrack",
    durationbetween: "30_600",
    include: "licenses musicinfo",
    audiodlformat: "mp32",
    order: "id",
  });
}

async function fetchJamendoCatalogSize(
  clientId: string,
  signal: AbortSignal,
): Promise<number> {
  if (jamendoCatalogSize !== null) return jamendoCatalogSize;
  const params = jamendoParams(clientId);
  params.set("limit", "1");
  params.set("fullcount", "true");
  const response = await fetch(
    `https://api.jamendo.com/v3.0/tracks/?${params}`,
    { signal },
  );
  if (!response.ok) throw new Error("JAMENDO_UNAVAILABLE");
  const payload = (await response.json()) as JamendoResponse;
  if (payload.headers?.status !== "success") {
    throw new Error("JAMENDO_UNAVAILABLE");
  }
  const count = Number(payload.headers?.results_fullcount || 0);
  jamendoCatalogSize =
    Number.isFinite(count) && count > 0 ? count : JAMENDO_CATALOG_FALLBACK_SIZE;
  return jamendoCatalogSize;
}

async function fetchJamendoCandidates(
  clientId: string,
  catalogSize: number,
  signal: AbortSignal,
): Promise<JamendoTrack[]> {
  const limit = Math.min(50, catalogSize);
  const params = jamendoParams(clientId);
  params.set("limit", String(limit));
  params.set(
    "offset",
    String(randomInt(0, Math.max(1, catalogSize - limit + 1))),
  );
  const response = await fetch(
    `https://api.jamendo.com/v3.0/tracks/?${params}`,
    { signal },
  );
  if (!response.ok) throw new Error("JAMENDO_UNAVAILABLE");
  const payload = (await response.json()) as JamendoResponse;
  if (payload.headers?.status !== "success") {
    throw new Error("JAMENDO_UNAVAILABLE");
  }
  return (payload.results || []).filter(
    (track) =>
      track.audiodownload_allowed === true &&
      isJamendoDownload(track.audiodownload) &&
      Boolean(normalizedHttpsUrl(track.shareurl || track.shorturl)) &&
      Boolean(normalizedHttpsUrl(track.license_ccurl)),
  );
}

async function completeJamendoRound(
  client: SupabaseClient,
  roundId: string,
  track: JamendoTrack,
  storagePath: string,
  contentSha256: string,
) {
  const sourceUrl = normalizedHttpsUrl(track.shareurl || track.shorturl);
  const licenseUrl = normalizedHttpsUrl(track.license_ccurl);
  if (!sourceUrl || !licenseUrl) throw new Error("INVALID_PROVIDER_METADATA");
  return rpc<PreparationClaim>(client, "service_complete_jamendo_round", {
    p_round_id: roundId,
    p_provider_track_id: track.id,
    p_title: track.name,
    p_artist: track.artist_name,
    p_duration_seconds: Math.round(Number(track.duration)),
    p_storage_path: storagePath,
    p_source_url: sourceUrl,
    p_license_url: licenseUrl,
    p_genres: track.musicinfo?.tags?.genres || [],
    p_content_sha256: contentSha256,
  });
}

async function prepareJamendoRound(
  claim: PreparationClaim,
  signal: AbortSignal,
): Promise<PreparationClaim> {
  const config = getServerConfig();
  if (!config.jamendoClientId) throw new Error("JAMENDO_NOT_CONFIGURED");
  if (!claim.round_id) throw new Error("INVALID_PREPARATION_CLAIM");
  const client = getSupabaseAdminClient();
  const used = new Set((claim.used_provider_track_ids || []).map(String));
  const catalogSize = await fetchJamendoCatalogSize(
    config.jamendoClientId,
    signal,
  );

  for (let attempt = 0; attempt < 3; attempt += 1) {
    const candidates = (
      await fetchJamendoCandidates(config.jamendoClientId, catalogSize, signal)
    ).filter((track) => !used.has(String(track.id)));
    if (candidates.length === 0) continue;
    const track = candidates[randomInt(0, candidates.length)];
    used.add(String(track.id));

    const cached = await rpc<{
      storage_path: string;
      content_sha256: string;
    } | null>(client, "service_get_cached_track", {
      p_provider: "jamendo",
      p_provider_track_id: track.id,
      p_round_id: claim.round_id,
    });
    if (cached?.storage_path && cached.content_sha256) {
      return completeJamendoRound(
        client,
        claim.round_id,
        track,
        cached.storage_path,
        cached.content_sha256,
      );
    }

    const bytes = await downloadAudio(track.audiodownload, signal);
    const contentSha256 = sha256Hex(bytes);
    const storagePath = `${randomUUID()}.mp3`;
    const upload = await client.storage
      .from("track-audio")
      .upload(storagePath, bytes, {
        contentType: "audio/mpeg",
        cacheControl: "31536000",
        upsert: false,
      });
    if (upload.error) throw upload.error;
    try {
      const result = await completeJamendoRound(
        client,
        claim.round_id,
        track,
        storagePath,
        contentSha256,
      );
      if (result.storage_path && result.storage_path !== storagePath) {
        await client.storage.from("track-audio").remove([storagePath]);
      }
      return result;
    } catch (error) {
      await client.storage.from("track-audio").remove([storagePath]);
      throw error;
    }
  }
  throw new Error("NO_ELIGIBLE_JAMENDO_TRACK");
}

async function gamePreparationStatus(
  client: SupabaseClient,
  code: string,
  userId: string,
) {
  return rpc<PreparationClaim>(client, "service_game_preparation_status", {
    p_code: code,
    p_user_id: userId,
  });
}

export async function prepareGameTracks(
  code: string,
  userId: string,
  forceRetry: boolean,
): Promise<PreparationClaim> {
  const client = getSupabaseAdminClient();
  const claim = await rpc<PreparationClaim>(
    client,
    "service_claim_round_preparation",
    {
      p_code: code,
      p_user_id: userId,
      p_force_retry: forceRetry,
    },
  );
  if (claim.status !== "claimed") {
    return claim.total_count === undefined
      ? claim
      : gamePreparationStatus(client, code, userId);
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 30_000);
  try {
    const completed = await prepareJamendoRound(claim, controller.signal);
    return claim.total_count === undefined
      ? completed
      : gamePreparationStatus(client, code, userId);
  } catch (error) {
    const errorCode = publicPreparationError(error);
    const failed = await rpc<PreparationClaim>(
      client,
      "service_fail_round_preparation",
      {
        p_round_id: claim.round_id,
        p_error_code: errorCode,
      },
    );
    return claim.total_count === undefined
      ? failed
      : gamePreparationStatus(client, code, userId);
  } finally {
    clearTimeout(timeout);
  }
}

export async function skipGameTrack(code: string, userId: string) {
  const client = getSupabaseAdminClient();
  return rpc<PreparationClaim>(client, "service_skip_game_track", {
    p_code: code,
    p_user_id: userId,
  });
}
