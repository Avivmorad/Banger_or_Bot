# Banger or Bot

[![CI](https://github.com/Avivmorad/Banger-or-Bot/actions/workflows/ci.yml/badge.svg)](https://github.com/Avivmorad/Banger-or-Bot/actions/workflows/ci.yml)

Real-time multiplayer music game where up to eight players guess whether each
track was made by a human or by AI. A host creates a room, players join with a
six-character code, and the server controls timing, answers, scoring, and
leaderboard state.

**[Play the live game](https://song-guess-ai-or-real.vercel.app)**

## Highlights

- Anonymous create/join flow for one to eight players
- Live lobby, ready states, host settings, player removal, and host transfer
- Server-authoritative deadlines, scoring, reveals, ranks, and replay flow
- Reconnect and missing-answer handling
- Private audio preparation with synchronized player readiness
- Supabase PostgreSQL, Realtime, Anonymous Auth, private Storage, RLS, and
  restricted RPCs
- Responsive, keyboard-accessible UI with reduced-motion support
- Vitest, Playwright, integration tests, and pgTAP database coverage

## Architecture

```text
Next.js client and server routes
  |-- Supabase Anonymous Auth
  |-- Realtime room events
  |-- restricted PostgreSQL RPCs
  `-- private audio preparation
        |-- owned AI tracks
        `-- licensed Jamendo tracks
```

- `client/` contains the Next.js application, trusted route handlers, generated
  database types, and browser/unit/integration tests.
- `server/` contains Supabase migrations, database tests, local configuration,
  and the administrator track-import workflow.

The browser cannot directly read authoritative tables or track answers. Row
Level Security and security-definer RPCs protect game state, while reveal data
is returned only after the server closes the answer window.

## Local setup

Requirements: Node.js 22+, npm 10+, and a Supabase project. A Docker-compatible
runtime is needed only for the optional local Supabase stack.

```sh
git clone https://github.com/Avivmorad/Banger-or-Bot.git
cd Banger-or-Bot/client
npm ci
```

Copy the root `.env.example` to `client/.env.local`, configure the documented
Supabase and Jamendo values, enable Anonymous Sign-Ins, and apply the migrations
under `server/supabase/migrations/`. Then run:

```sh
npm run dev
```

The local site runs at `http://localhost:3000`.

## Verification

Run from `client/`:

```sh
npm run format:check
npm run lint
npm run check
npm run test
npm run test:integration
npm run build
npm run test:e2e
```

Integration tests require the dedicated `E2E_SUPABASE_*` values documented in
`.env.example`. Database coverage lives in
`server/supabase/tests/schema.test.sql`.

## Music sources and licensing

- Human rounds use downloadable tracks returned by Jamendo with per-track
  Creative Commons attribution and license metadata.
- AI rounds use tracks created by the repository owner with a paid Suno Pro
  subscription and imported into private Storage.
- The six WAV files in `client/public/audio/` are original local/test fixtures
  and are not used by the production dynamic pack.

The source code is licensed under the [MIT License](LICENSE). Original project
audio is **not** covered by MIT and remains all rights reserved. See
[ASSET_LICENSE.md](ASSET_LICENSE.md) for the exact media terms.

## Operations

- Track import and preparation: [`server/TRACKS.md`](server/TRACKS.md)
- Database setup and commands: [`server/README.md`](server/README.md)
- Production deploys `main` from the `client/` directory to Vercel.

The existing Vercel and Supabase project identifiers retain their legacy names
to avoid breaking production configuration.

## Known limitations

- Jamendo audio cache eviction is manual.
- Public-scale use should add CAPTCHA alongside existing rate limits.
- Expired-room cleanup requires a trusted external schedule.
