# PHASE 1 — Add a `/health` endpoint

A worked example of the plan format `/build` expects. The fields below are the only ones `manifest.sh init` parses: `## Goal`, `## Approach`, `## User-reachable surfaces`, `## Chunks`, `## Open questions`, `## Out of scope`.

## Goal

Expose a `GET /health` endpoint that returns `{ status: "ok", db: "ok" | "down" }` so external uptime monitors can probe the service.

## Approach

Add a single Express route. Database check is a `SELECT 1` against the existing pg pool (5s timeout). No auth required — this needs to be reachable from monitoring services. Cache the DB result for 1s to avoid hammering the pool when monitors poll every second.

Decision: ping the DB every request vs cache. **Cache for 1s** — Codex agreed; the single-second TTL is short enough that a real outage propagates within 1s but long enough to absorb a monitor that polls 10× per second.

## User-reachable surfaces

| Surface | Status |
|---|---|
| `GET /health` route | New — this PR |
| README "Operations" section | Update to document the endpoint |
| `/docs/api.md` if it exists | Update to list the new route |
| Production load balancer health check | Reconfigure to point at `/health` (out of scope — ops team) |
| Datadog/UptimeRobot probe target | Configure post-deploy (out of scope) |

## Chunks

1. **Add /health route** — files: src/server.ts, src/routes/health.ts
2. **Add unit + smoke tests** — files: tests/health.test.ts
3. **Document in README + api.md** — files: README.md, docs/api.md

## Open questions

- Should the response include a build SHA or version string? (Default: no — keeps the response cacheable and the surface small.)

## Out of scope

- LB reconfiguration — ops team owns the load balancer config
- Probe configuration in Datadog/UptimeRobot — done post-deploy by the team that owns the monitor
- Auth or rate-limiting — `/health` is intentionally public + unrate-limited per the convention
