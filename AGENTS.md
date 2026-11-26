# Codex Project Instructions

## Main Behavior

- Work quickly and use tokens efficiently.
- Keep progress updates and final responses concise.
- Focus on completing the requested task, not narrating every step.
- Avoid unnecessary questions; make reasonable assumptions when safe.
- Read only the files needed for the current task.

## Project Boundaries

- Keep the Next.js application, browser code, and route handlers in `client/`.
- Keep database migrations, seeds, SQL tests, and backend operations in `server/`.
- Reuse the existing architecture, components, utilities, and conventions.
- Protect the complete multiplayer loop: create or join a room, ready up, configure, play synchronized rounds, submit one authoritative answer, reveal, rank, finish, and play again.

## Before Making Changes

- Understand the requested outcome and inspect relevant existing code first.
- Prefer the smallest reliable change that fully solves the task.
- Avoid unnecessary rewrites, abstractions, dependencies, or new files.
- Check the working tree before editing and preserve unrelated user changes.

## Implementation

- Complete the requested work directly.
- Fix related issues only when they block the task or create an obvious bug.
- Preserve existing behavior unless a change is explicitly requested.
- Keep code clean, maintainable, and production-ready.
- Do not leave placeholders, mock implementations, TODO comments, or unfinished logic unless explicitly requested.
- Do not silently ignore failed commands, tests, or tool calls.
- Do not install system software, global tools, or new dependencies without explaining why and asking first when approval is required.

## Security and Data Boundaries

- Never expose, print, commit, or hardcode secrets.
- Never expose service-role keys, database passwords, or admin credentials to browser code.
- Treat browser timestamps, scores, room roles, and answers as untrusted.
- Validate authorization and authoritative game state on the server.

## Verification

After making changes:

1. Run the most relevant targeted checks first.
2. Prefer formatting, linting, type checking, tests, and builds over broad scans.
3. Run broader checks only when necessary.
4. Fix failures caused by the changes.
5. Clearly distinguish pre-existing failures from new failures.

Run these client checks only when the scripts exist:

```text
cd client
npm run format:check
npm run lint
npm run check
npm run test
npm run build
npm run test:e2e
```

For SQL changes, validate against a dedicated Supabase project and run both security and performance advisors.

## User Actions Required

When an action must be performed by the user, clearly state:

**ACTION REQUIRED FROM YOU:**

- The exact action, location, command, file, setting, or value.
- Why it cannot be completed automatically.

Use this for API keys, secrets, permissions, authentication, external dashboards, account or billing choices, CAPTCHA, and destructive or irreversible confirmations.

## Safety Rules

- Do not delete data, overwrite important files, reset repositories, force-push, commit, or change external systems without explicit permission.
- Use reversible operations whenever practical.
- Do not claim something works unless it was verified; label unverified results clearly.

## Final Response Format

**Completed**

- Brief list of important changes.

**Verification**

- Checks run and their results.

**Action required from you**

- Include only when necessary; write `None` when no action is required.

**Remaining issue**

- Include only for unresolved problems or pre-existing failures.

Keep the final response concise and avoid file-by-file narration unless requested.

## Cursor Cloud specific instructions

- Node.js 22 is already on the image. From the repository root, install with `npm ci --prefix client`. The command is safe to run again.
- Start the app from `client/` with `npm run dev`. Open `http://localhost:3000`. Do not use `http://127.0.0.1:3000`: Next.js treats that host as a different dev origin and blocks the dev resources, so the page does not hydrate.
- `GET /api/health` returns `status: ok`. `multiplayer` is `configured` only when `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` are present. Put them in gitignored `client/.env.local`.
- Those two values are enough to create and join a room. Preparing round audio also needs `SUPABASE_SERVICE_ROLE_KEY`. `JAMENDO_CLIENT_ID` is only for the dynamic human-track pack; local demo fixtures do not need it.
- Client checks, from `client/`: `npm run format:check`, `npm run lint`, `npm run check`, `npm run test`, and `npm run build`.
- The optional local Supabase stack under `server/` needs Docker and about 7 GB of free RAM. This Cloud Agent setup does not start it.
