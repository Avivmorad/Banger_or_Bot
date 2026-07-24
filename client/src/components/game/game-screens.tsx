"use client";

import { useState } from "react";
import {
  BoltIcon,
  CheckIcon,
  PersonIcon,
  RobotIcon,
  VolumeIcon,
  XIcon,
} from "@/components/icons";
import { Button, Panel, Spinner, StatusMessage } from "@/components/ui";
import { useClock } from "@/hooks/use-clock";
import { useSynchronizedAudio } from "@/hooks/use-synchronized-audio";
import type { PreparationProgress } from "@/hooks/use-room-controller";
import { formatScore } from "@/lib/game/scoring";
import type { AnswerChoice, RoomState } from "@/lib/game/types";
import { Leaderboard } from "./leaderboard";

interface GameScreensProps {
  state: RoomState;
  serverOffsetMs: number;
  busyAction: string | null;
  actionError: string;
  preparationProgress: PreparationProgress | null;
  onAnswer: (choice: AnswerChoice) => Promise<boolean>;
  onAgain: () => Promise<boolean>;
  onAudioReady: (roundId: string) => Promise<boolean>;
  onRetryPreparation: () => Promise<boolean>;
  onSkipPreparation: () => Promise<boolean>;
  onRemove: (playerId: string) => Promise<boolean>;
  onLeave: () => Promise<void>;
}

function secondsBetween(endsAt: string | null, now: number, offset: number) {
  if (!endsAt) return 0;
  return Math.max(0, (new Date(endsAt).getTime() - (now + offset)) / 1000);
}

function answerLabel(choice: AnswerChoice | null) {
  if (choice === "ai") return "MADE BY AI";
  if (choice === "real") return "MADE BY HUMAN";
  return "NO ANSWER";
}

function displayName(name: string) {
  return name.length > 0 ? name[0].toUpperCase() + name.slice(1) : name;
}

function AudioStatus({
  audioState,
  muted,
  onActivate,
  onMute,
  onRetry,
}: {
  audioState: string;
  muted: boolean;
  onActivate: () => Promise<void>;
  onMute: () => void;
  onRetry: () => void;
}) {
  return (
    <div className="audio-status" role="status" aria-live="polite">
      <span className={`audio-dot audio-${audioState}`} />
      <span className="audio-state-label">
        {audioState === "loading" && "Loading Audio"}
        {audioState === "ready" && "Audio Ready ✓"}
        {audioState === "playing" && "Synced ✓"}
        {audioState === "blocked" && "Tap to Start Audio"}
        {audioState === "error" && "Audio Could Not Load"}
        {audioState === "ended" && "Clip Complete"}
        {audioState === "idle" && "Waiting for Track"}
      </span>
      {audioState === "blocked" && (
        <Button variant="secondary" onClick={() => void onActivate()}>
          Play Audio
        </Button>
      )}
      {audioState === "error" && (
        <Button variant="secondary" onClick={onRetry}>
          Retry Audio
        </Button>
      )}
      <Button
        className="mute-button"
        variant="ghost"
        onClick={onMute}
        aria-label={muted ? "Unmute music" : "Mute music"}
      >
        <VolumeIcon aria-hidden="true" /> {muted ? "Muted" : "Sound On"}
      </Button>
    </div>
  );
}

function PreparingScreen({
  state,
  now,
  busyAction,
  actionError,
  preparationProgress,
  onRetryPreparation,
  onSkipPreparation,
  onRemove,
}: {
  state: RoomState;
  now: number;
  busyAction: string | null;
  actionError: string;
  preparationProgress: PreparationProgress | null;
  onRetryPreparation: () => Promise<boolean>;
  onSkipPreparation: () => Promise<boolean>;
  onRemove: (playerId: string) => Promise<boolean>;
}) {
  const [preparingStartedAt] = useState(() => Date.now());
  const round = state.round;

  if (!round) return null;

  const failed =
    preparationProgress?.stage === "failed" ||
    round.preparation_status === "failed";
  const total = preparationProgress?.total || round.total;
  const serverReady = preparationProgress?.serverReady || 0;
  const downloaded = preparationProgress?.downloaded || 0;
  const downloading = preparationProgress?.stage === "download";
  const playerReady = preparationProgress?.playerReady ?? 0;
  const playerRequired = preparationProgress?.playerRequired ?? 0;
  const timedOut = preparationProgress?.timedOut ?? false;
  const takingLong = now - preparingStartedAt >= 17_000;
  const locallyReady = downloading && total > 0 && downloaded >= total;
  const everyoneReady =
    locallyReady && playerRequired > 0 && playerReady >= playerRequired;
  const stage = failed
    ? "Preparation needs attention"
    : serverReady < total
      ? "Finding the next track"
      : !locallyReady
        ? "Loading the audio"
        : playerReady < playerRequired
          ? "Syncing all players"
          : "Ready to play";

  return (
    <section
      className="phase-screen preparing-screen"
      aria-labelledby="preparing-title"
    >
      <div className="round-kicker">Preparing Round {round.number}</div>
      <div
        className={`preparation-spinner ${everyoneReady ? "preparation-ready" : ""}`}
        aria-hidden="true"
      >
        {everyoneReady ? <CheckIcon /> : failed ? "!" : null}
      </div>
      <p className="loading-stage" aria-live="polite">
        {stage}
      </p>
      <h1 id="preparing-title">
        {failed
          ? "This track needs another try."
          : everyoneReady
            ? "Track ready ✓"
            : "Loading the next banger"}
        {!failed && !everyoneReady && (
          <span className="loading-dots" aria-hidden="true">
            <i />
            <i />
            <i />
          </span>
        )}
      </h1>
      <p>
        {failed
          ? "The game is paused so no one starts with broken audio."
          : "The round will start automatically when the audio is ready for everyone."}
      </p>
      {!failed && downloading && (
        <p className="loading-detail">
          {downloaded}/{total} tracks downloaded to this device · {playerReady}/
          {playerRequired} players synced
        </p>
      )}

      {(takingLong || failed) && !timedOut && (
        <Panel className="slow-loading" aria-live="polite">
          <h2>This track is taking longer than expected.</h2>
          {state.me.is_host ? (
            <div className="recovery-actions">
              <Button
                disabled={busyAction === "retry"}
                onClick={() => void onRetryPreparation()}
              >
                {busyAction === "retry" ? (
                  <Spinner label="Trying again" />
                ) : (
                  "Try Again"
                )}
              </Button>
              <Button
                variant="secondary"
                disabled={busyAction === "skip"}
                onClick={() => void onSkipPreparation()}
              >
                {busyAction === "skip" ? (
                  <Spinner label="Skipping track" />
                ) : (
                  "Skip Track"
                )}
              </Button>
            </div>
          ) : (
            <p>Waiting for the host to recover the track.</p>
          )}
        </Panel>
      )}

      {timedOut && state.me.is_host && (
        <Panel className="preparation-timeout">
          <h2>Some players are still loading.</h2>
          <p>The game is paused. Try again or remove a stalled player.</p>
          <Button
            disabled={busyAction === "retry"}
            onClick={() => void onRetryPreparation()}
          >
            {busyAction === "retry" ? (
              <Spinner label="Retrying preparation" />
            ) : (
              "Try Again"
            )}
          </Button>
          {(preparationProgress?.stalledPlayers ?? []).map((player) => (
            <div className="stalled-player" key={player.id}>
              <span>{player.nickname}</span>
              <Button
                variant="secondary"
                disabled={busyAction === "remove"}
                onClick={() => void onRemove(player.id)}
              >
                Remove Player
              </Button>
            </div>
          ))}
        </Panel>
      )}
      {timedOut && !state.me.is_host && (
        <p className="waiting-host">
          Loading timed out. The host is choosing how to continue.
        </p>
      )}
      {actionError && <StatusMessage>{actionError}</StatusMessage>}
    </section>
  );
}

export function GameScreens({
  state,
  serverOffsetMs,
  busyAction,
  actionError,
  preparationProgress,
  onAnswer,
  onAgain,
  onAudioReady,
  onRetryPreparation,
  onSkipPreparation,
  onRemove,
  onLeave,
}: GameScreensProps) {
  const now = useClock();
  const remaining = secondsBetween(
    state.room.phase_ends_at,
    now,
    serverOffsetMs,
  );
  const round = state.round;
  const audio = useSynchronizedAudio({
    code: state.room.code,
    round,
    phase: state.room.phase,
    serverOffsetMs,
    volume: state.room.settings.music_volume,
    onAudioReady,
  });

  if (state.room.phase === "preparing" && round) {
    return (
      <PreparingScreen
        key={round.id}
        state={state}
        now={now}
        busyAction={busyAction}
        actionError={actionError}
        preparationProgress={preparationProgress}
        onRetryPreparation={onRetryPreparation}
        onSkipPreparation={onSkipPreparation}
        onRemove={onRemove}
      />
    );
  }

  if (state.room.phase === "countdown") {
    return (
      <section
        className="phase-screen countdown-screen"
        aria-labelledby="countdown-title"
      >
        <div className="round-kicker">
          Round {round?.number || state.room.current_round} of{" "}
          {state.room.settings.round_count}
        </div>
        <p className="eyebrow">Get Ready</p>
        <h1 id="countdown-title">Listen closely.</h1>
        <output className="countdown-value" aria-live="assertive">
          {Math.max(1, Math.ceil(remaining))}
        </output>
        <p>Everyone hears the track at the same time.</p>
        <AudioStatus
          audioState={audio.audioState}
          muted={audio.muted}
          onActivate={audio.activate}
          onMute={audio.toggleMuted}
          onRetry={audio.retry}
        />
      </section>
    );
  }

  if (state.room.phase === "playing" && round) {
    const selected = round.own_answer;
    const locked =
      Boolean(selected) && !state.room.settings.allow_answer_changes;
    const timeUp = remaining <= 0;
    const finalFive = remaining > 0 && remaining <= 5;
    return (
      <section
        className="phase-screen playing-screen"
        aria-labelledby="playing-title"
      >
        <div className="game-status-row">
          <span>
            Round {round.number} of {round.total}
          </span>
          <span>
            <BoltIcon aria-hidden="true" />{" "}
            {formatScore(
              state.leaderboard.find((player) => player.is_me)?.score || 0,
            )}{" "}
            Points
          </span>
        </div>
        <Panel className="now-playing-card">
          <div className="now-playing-heading">
            <div>
              <p className="eyebrow">Now Playing</p>
              <h1 id="playing-title">Who made this track?</h1>
            </div>
            <div
              className={`round-timer ${finalFive ? "timer-urgent" : ""} ${remaining < 1 ? "timer-final" : ""}`}
              aria-label={`${remaining.toFixed(1)} seconds remaining`}
            >
              <strong>{Math.ceil(remaining)}</strong>
              <span>Seconds</span>
            </div>
          </div>
          <div
            className={`audio-visualizer ${audio.audioState === "playing" ? "is-playing" : ""}`}
            aria-hidden="true"
          >
            {Array.from({ length: 24 }, (_, index) => (
              <i key={index} />
            ))}
          </div>
          <div
            className="audio-progress"
            role="progressbar"
            aria-label="Track playback"
            aria-valuemin={0}
            aria-valuemax={100}
            aria-valuenow={Math.round(audio.progress * 100)}
          >
            <i style={{ width: `${audio.progress * 100}%` }} />
          </div>
          <AudioStatus
            audioState={audio.audioState}
            muted={audio.muted}
            onActivate={audio.activate}
            onMute={audio.toggleMuted}
            onRetry={audio.retry}
          />
        </Panel>

        <div className="answer-grid" aria-label="Choose who made the track">
          <Button
            className={`answer-button answer-ai ${selected === "ai" ? "selected" : ""}`}
            disabled={locked || timeUp || busyAction === "answer"}
            onClick={() => void onAnswer("ai")}
            aria-pressed={selected === "ai"}
            aria-label="Made by AI"
          >
            <span className="answer-symbol">
              <RobotIcon aria-hidden="true" />
            </span>
            <strong>Made by AI</strong>
            {selected === "ai" && <CheckIcon aria-label="Selected" />}
          </Button>
          <Button
            className={`answer-button answer-real ${selected === "real" ? "selected" : ""}`}
            disabled={locked || timeUp || busyAction === "answer"}
            onClick={() => void onAnswer("real")}
            aria-pressed={selected === "real"}
            aria-label="Made by human"
          >
            <span className="answer-symbol">
              <PersonIcon aria-hidden="true" />
            </span>
            <strong>Made by Human</strong>
            {selected === "real" && <CheckIcon aria-label="Selected" />}
          </Button>
        </div>

        <div className="submission-status" aria-live="polite">
          {busyAction === "answer" ? (
            <Spinner label="Submitting answer" />
          ) : timeUp ? (
            <strong>Time’s up</strong>
          ) : selected ? (
            <>
              <CheckIcon aria-hidden="true" />{" "}
              {locked ? "Answer locked ✓" : "Answer selected ✓"}
              {!locked && (
                <small>Tap another option to change your answer.</small>
              )}
            </>
          ) : (
            "Choose before the timer reaches zero."
          )}
          <span>
            {round.submitted_count}/{state.players.length} answered
          </span>
        </div>
        {actionError && <StatusMessage>{actionError}</StatusMessage>}
      </section>
    );
  }

  if (state.room.phase === "reveal" && round) {
    const correct =
      round.own_answer !== null && round.own_answer === round.correct_answer;
    const points = round.own_points || 0;
    const revealRatio = Math.max(
      0,
      Math.min(1, remaining / state.room.settings.reveal_duration_seconds),
    );
    return (
      <section
        className={`phase-screen reveal-screen ${correct ? "result-correct" : "result-incorrect"}`}
        aria-labelledby="reveal-title"
      >
        <div className="round-kicker">Round {round.number} Result</div>
        {round.answered_in_seconds !== null && (
          <p className="answer-time">
            Answered in {round.answered_in_seconds.toFixed(1)} seconds
          </p>
        )}
        <div
          className={`reveal-orb reveal-${round.correct_answer} ${correct ? "reveal-result-correct" : "reveal-result-incorrect"}`}
          aria-label={correct ? "Correct answer" : "Incorrect answer"}
          role="img"
        >
          {correct ? <CheckIcon /> : <XIcon />}
        </div>
        <p className={`eyebrow reveal-answer-${round.correct_answer}`}>
          Correct Answer
        </p>
        <h1 id="reveal-title">{answerLabel(round.correct_answer)}</h1>
        <div
          className={`player-result ${correct ? "is-correct" : "is-incorrect"}`}
          role="status"
        >
          <strong>
            {round.own_answer === null ? (
              "NO ANSWER"
            ) : correct ? (
              <>
                <CheckIcon aria-hidden="true" /> Correct ✓
              </>
            ) : (
              <>
                <XIcon aria-hidden="true" /> Incorrect
              </>
            )}
          </strong>
          {round.own_answer !== null && !correct && (
            <span>You chose: {answerLabel(round.own_answer)}</span>
          )}
          <span>
            {points > 0 ? "+" : points < 0 ? "−" : ""}
            {formatScore(Math.abs(points))} points
          </span>
        </div>
        <div className="track-reveal">
          <strong>{round.title}</strong>
          <span>by {round.artist || "Unknown artist"}</span>
        </div>
        {round.source_url && (
          <a
            className="song-link-button"
            href={round.source_url}
            target="_blank"
            rel="noopener noreferrer"
          >
            Song Link – Listen Now
          </a>
        )}
        <div className="reveal-board">
          <div className="section-row">
            <div>
              <p className="eyebrow">Live Ranking</p>
              <h2>Leaderboard</h2>
            </div>
          </div>
          <Leaderboard players={state.leaderboard} compact />
        </div>
        <div className="next-round-status" role="status">
          <span>
            {round.number >= round.total
              ? `Final results in ${Math.max(1, Math.ceil(remaining))}...`
              : `Next round starts in ${Math.max(1, Math.ceil(remaining))}...`}
          </span>
          <div aria-hidden="true">
            <i style={{ width: `${revealRatio * 100}%` }} />
          </div>
        </div>
      </section>
    );
  }

  if (state.room.phase === "intermission") {
    const intermissionRatio = Math.max(0, Math.min(1, remaining / 4));
    return (
      <section
        className="phase-screen intermission-screen"
        aria-labelledby="intermission-title"
      >
        <p className="eyebrow">Leaderboard</p>
        <h1 id="intermission-title">
          Next round starts in {Math.max(1, Math.ceil(remaining))}...
        </h1>
        <div className="intermission-progress" aria-hidden="true">
          <i style={{ width: `${intermissionRatio * 100}%` }} />
        </div>
        <Leaderboard players={state.leaderboard} />
      </section>
    );
  }

  if (state.room.phase === "finished") {
    const winner = state.leaderboard[0];
    const me = state.leaderboard.find((player) => player.is_me);
    return (
      <section
        className="phase-screen final-screen"
        aria-labelledby="final-title"
      >
        <div className="final-burst" aria-hidden="true">
          <i />
          <i />
          <i />
          <i />
          <i />
        </div>
        <p className="eyebrow">Final Results</p>
        <h1 id="final-title">
          {winner
            ? `${displayName(winner.nickname)} wins the game!`
            : "Game complete!"}
        </h1>
        {winner && (
          <p className="winner-summary">
            {formatScore(winner.score)} points · 1st place
            <small>The sharpest ears tonight.</small>
          </p>
        )}
        <Leaderboard players={state.leaderboard} />
        {state.round_history.length > 0 && (
          <Panel className="final-song-list">
            <p className="eyebrow">Game History</p>
            <h2>Round Results</h2>
            <ol>
              {state.round_history.map((song) => (
                <li key={song.round_number}>
                  <span className="history-round">
                    Round {song.round_number}
                  </span>
                  <span className="history-track">
                    <strong>{song.title}</strong>
                    <small>by {song.artist || "Unknown artist"}</small>
                  </span>
                  <span className="history-result">
                    <strong>{answerLabel(song.answer_type)}</strong>
                    <small>
                      {song.was_correct ? "Correct ✓" : "Incorrect ✕"} ·{" "}
                      {song.own_points > 0
                        ? "+"
                        : song.own_points < 0
                          ? "−"
                          : ""}
                      {formatScore(Math.abs(song.own_points))} points
                    </small>
                  </span>
                  {song.source_url && (
                    <a
                      href={song.source_url}
                      target="_blank"
                      rel="noopener noreferrer"
                    >
                      Listen Now
                    </a>
                  )}
                </li>
              ))}
            </ol>
          </Panel>
        )}
        {actionError && <StatusMessage>{actionError}</StatusMessage>}
        <div className="final-actions">
          {state.me.is_host ? (
            <div className="play-again-action">
              <Button
                disabled={busyAction === "again"}
                onClick={() => void onAgain()}
              >
                {busyAction === "again" ? (
                  <Spinner label="Resetting room" />
                ) : (
                  "Play Again"
                )}
              </Button>
              <small>Keep the same room and players</small>
            </div>
          ) : (
            <p className="waiting-host">
              Waiting for the host to start another game.
            </p>
          )}
          <Button
            variant="secondary"
            disabled={busyAction === "leave"}
            onClick={() => void onLeave()}
          >
            Back to Home
          </Button>
        </div>
        {me && me.id !== winner?.id && (
          <p className="your-final-score">
            Your score: {formatScore(me.score)} points
          </p>
        )}
      </section>
    );
  }

  return (
    <section className="phase-screen">
      <Spinner label="Synchronizing the next phase" />
    </section>
  );
}
