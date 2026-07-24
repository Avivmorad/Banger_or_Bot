"use client";

import { useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import { ArrowIcon, InfoIcon } from "@/components/icons";
import { Button, Field, Panel, Spinner, StatusMessage } from "@/components/ui";
import {
  DEFAULT_SETTINGS,
  normalizeNickname,
  normalizeRoomCode,
  type GameSettings,
} from "@/lib/game/types";
import { createRoom, GameApiError, joinRoom } from "@/lib/supabase/game-api";
import { isBackendConfigured } from "@/lib/supabase/config";

function useInitialNickname(initialNickname: string) {
  const [nickname, setNickname] = useState(initialNickname);
  return [nickname, setNickname] as const;
}

export function CreateRoomForm({
  initialNickname,
}: {
  initialNickname: string;
}) {
  const router = useRouter();
  const [nickname, setNickname] = useInitialNickname(initialNickname);
  const [settings, setSettings] = useState<GameSettings>(DEFAULT_SETTINGS);
  const [error, setError] = useState("");
  const [nicknameTouched, setNicknameTouched] = useState(false);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const nicknameIsValid = normalizeNickname(nickname).length >= 2;
  const nicknameError =
    (nicknameTouched || error) && !nicknameIsValid
      ? "Use a nickname between 2 and 20 characters."
      : "";
  const settingsSummary = `${settings.round_count} rounds · ${settings.round_duration_seconds} seconds · Penalty ${settings.negative_points ? "on" : "off"}`;

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    const cleanNickname = normalizeNickname(nickname);
    if (cleanNickname.length < 2) {
      setError("Use a nickname between 2 and 20 characters.");
      return;
    }
    if (!isBackendConfigured()) {
      setError("The multiplayer service is not configured yet.");
      return;
    }
    setIsSubmitting(true);
    setError("");
    try {
      const state = await createRoom(cleanNickname, settings);
      window.localStorage.setItem("song-guess-nickname", cleanNickname);
      router.replace(`/room/${state.room.code}`);
    } catch (caught) {
      setError(
        caught instanceof GameApiError
          ? caught.message
          : "The room could not be created.",
      );
      setIsSubmitting(false);
    }
  }

  return (
    <form onSubmit={handleSubmit} className="entry-grid">
      <Panel className="entry-panel">
        <div className="panel-heading">
          <span className="step-number">01</span>
          <div>
            <p className="eyebrow">Player Profile</p>
            <h2>Choose your nickname</h2>
          </div>
        </div>
        <Field
          id="create-nickname"
          label="Nickname"
          value={nickname}
          onChange={(event) => {
            setNickname(event.target.value);
            setError("");
          }}
          onBlur={() => setNicknameTouched(true)}
          placeholder="Enter your nickname"
          autoComplete="nickname"
          maxLength={20}
          error={nicknameError}
        />
      </Panel>

      <Panel className="entry-panel settings-entry">
        <div className="panel-heading">
          <span className="step-number">02</span>
          <div>
            <p className="eyebrow">Game Settings</p>
            <h2>Customize your game</h2>
          </div>
        </div>
        <div className="settings-grid compact-settings">
          <label className="field">
            <span className="field-label">Number of rounds</span>
            <select
              className="input"
              value={settings.round_count}
              onChange={(event) =>
                setSettings({
                  ...settings,
                  round_count: Number(event.target.value),
                })
              }
            >
              {[3, 4, 5, 6].map((value) => (
                <option key={value} value={value}>
                  {value} rounds
                </option>
              ))}
            </select>
          </label>
          <label className="field">
            <span className="field-label">Time per round</span>
            <select
              className="input"
              value={settings.round_duration_seconds}
              onChange={(event) =>
                setSettings({
                  ...settings,
                  round_duration_seconds: Number(event.target.value),
                })
              }
            >
              {[10, 15, 20, 30, 45].map((value) => (
                <option key={value} value={value}>
                  {value} seconds
                </option>
              ))}
            </select>
          </label>
          <label className="switch-row">
            <span>
              <strong className="label-with-info">
                Wrong answer penalty
                <InfoIcon aria-label="Wrong answers deduct 500 points" />
              </strong>
              <small>Deduct 500 points for a wrong answer</small>
            </span>
            <input
              type="checkbox"
              checked={settings.negative_points}
              onChange={(event) =>
                setSettings({
                  ...settings,
                  negative_points: event.target.checked,
                })
              }
            />
          </label>
          <label className="switch-row">
            <span>
              <strong>Allow answer changes</strong>
              <small>Players can change their answer until time runs out</small>
            </span>
            <input
              type="checkbox"
              checked={settings.allow_answer_changes}
              onChange={(event) =>
                setSettings({
                  ...settings,
                  allow_answer_changes: event.target.checked,
                })
              }
            />
          </label>
        </div>
      </Panel>

      <div className="entry-submit">
        {error && !nicknameError && <StatusMessage>{error}</StatusMessage>}
        <div className="settings-summary" aria-label="Settings summary">
          {settingsSummary}
        </div>
        <Button type="submit" disabled={isSubmitting || !nicknameIsValid}>
          {isSubmitting ? (
            <Spinner label="Creating room" />
          ) : (
            <>
              Create Room &amp; Open Lobby <ArrowIcon aria-hidden="true" />
            </>
          )}
        </Button>
        <p>You can change these settings later in the lobby.</p>
      </div>
    </form>
  );
}

export function JoinRoomForm({
  initialNickname,
  initialCode,
}: {
  initialNickname: string;
  initialCode: string;
}) {
  const router = useRouter();
  const [nickname, setNickname] = useInitialNickname(initialNickname);
  const [code, setCode] = useState(normalizeRoomCode(initialCode));
  const [error, setError] = useState("");
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [codeTouched, setCodeTouched] = useState(false);
  const [nicknameTouched, setNicknameTouched] = useState(false);
  const codeIsValid = normalizeRoomCode(code).length === 6;
  const nicknameIsValid = normalizeNickname(nickname).length >= 2;
  const codeError =
    codeTouched && !codeIsValid
      ? "Enter the complete six-character room code."
      : "";
  const nicknameError =
    nicknameTouched && !nicknameIsValid
      ? "Use a nickname between 2 and 20 characters."
      : "";

  function showValidationErrors() {
    setCodeTouched(true);
    setNicknameTouched(true);
    const firstInvalidId = !codeIsValid ? "join-code" : "join-nickname";
    document.getElementById(firstInvalidId)?.focus();
  }

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    const cleanNickname = normalizeNickname(nickname);
    const cleanCode = normalizeRoomCode(code);
    if (!codeIsValid || !nicknameIsValid) {
      showValidationErrors();
      return;
    }
    if (!isBackendConfigured()) {
      setError("The multiplayer service is not configured yet.");
      return;
    }
    setIsSubmitting(true);
    setError("");
    try {
      const state = await joinRoom(cleanCode, cleanNickname);
      window.localStorage.setItem("song-guess-nickname", cleanNickname);
      router.replace(`/room/${state.room.code}`);
    } catch (caught) {
      setError(
        caught instanceof GameApiError
          ? caught.message
          : "The room could not be joined.",
      );
      setIsSubmitting(false);
    }
  }

  return (
    <form
      onSubmit={handleSubmit}
      onKeyDown={(event) => {
        if (
          event.key === "Enter" &&
          !isSubmitting &&
          (!codeIsValid || !nicknameIsValid)
        ) {
          event.preventDefault();
          showValidationErrors();
        }
      }}
      className="join-card"
    >
      <div className="join-card-heading">
        <p className="eyebrow">Join a Game</p>
        <h1>Join a Banger or Bot room.</h1>
        <p>Ask the host for the six-character code shown in their lobby.</p>
      </div>
      <Field
        id="join-code"
        label="Room code"
        value={code}
        onChange={(event) => {
          setCode(normalizeRoomCode(event.target.value));
          setError("");
        }}
        onBlur={() => setCodeTouched(true)}
        placeholder="ABC234"
        autoComplete="off"
        maxLength={6}
        inputMode="text"
        className="code-input"
        error={codeError}
      />
      <Field
        id="join-nickname"
        label="Nickname"
        value={nickname}
        onChange={(event) => {
          setNickname(event.target.value);
          setError("");
        }}
        onBlur={() => setNicknameTouched(true)}
        placeholder="Enter your nickname"
        autoComplete="nickname"
        maxLength={20}
        error={nicknameError}
      />
      {error && <StatusMessage>{error}</StatusMessage>}
      <Button
        type="submit"
        disabled={isSubmitting || !codeIsValid || !nicknameIsValid}
      >
        {isSubmitting ? (
          <Spinner label="Joining room" />
        ) : (
          <>
            Join Game <ArrowIcon aria-hidden="true" />
          </>
        )}
      </Button>
      <p className="join-footnote">
        Your browser keeps a private session so refreshes can reconnect you.
      </p>
    </form>
  );
}
