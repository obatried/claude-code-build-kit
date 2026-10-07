# PHASE 1 — Add a `/health` endpoint

A worked example of the plan format `/build` expects, at **standard tier**. `manifest.sh init` parses only the `## Chunks` section (a flat numbered list, `N. <name> — files: a, b`); every other section is for you, Codex, and the plan-review hook. A fast-tier plan (all five risk dimensions Low) would need only `## Risk Scorecard`, `## Goal`, `## Approach`, `## Chunks`, and `## Out of scope`.

## Risk Scorecard

| Dimension | Score | Why |
|---|---|---|
| Novelty | Low | Extends the existing Express route pattern |
| Blast radius | Medium | Unauthenticated and publicly reachable; uptime monitors will page off it. Borderline, so scored up |
| Irreversibility | Low | New route; a revert removes it |
| Verification difficulty | Low | Unit-testable with a mocked pool, plus `curl` |
| Rollback cost | Low | Revert + redeploy |

**Tier: standard** (one Medium, no High). Adversarial layer on. Touches public API surface (a new route), so § 1.6 freeze point applies.

## Goal

Expose a `GET /health` endpoint that returns `{ status: "ok", db: "ok" | "down" }` so external uptime monitors can probe the service.

## Approach

Add a single Express route. Database check is a `SELECT 1` against the existing pg pool (5s timeout). No auth required — this needs to be reachable from monitoring services. Cache the DB result for 1s to avoid hammering the pool when monitors poll every second.

## Decision Table

| Decision | Choice | Why |
|---|---|---|
| Ping the DB every request vs cache | Cache for 1s | Codex agreed: a real outage still shows within 1s, and a monitor polling 10× per second costs one query per second, not ten |
| Auth on `/health` | None | Monitors can't hold credentials; the response carries no sensitive data |
| DB probe timeout | 5s | A hung pool must report `down`, not hang the monitor |

## User-reachable surfaces

| Surface | Status |
|---|---|
| `GET /health` route | New — this build |
| README "Operations" section | Update to document the endpoint |
| `/docs/api.md` if it exists | Update to list the new route |
| Production load balancer health check | Reconfigure to point at `/health` (out of scope — ops team) |
| Datadog/UptimeRobot probe target | Configure post-deploy (out of scope) |

## Depth Calibration

| Surface | Depth | Notes |
|---|---|---|
| backend | implementation-ready | route, probe, cache, timeout |
| testing | implementation-ready | mocked pool + fake timers |
| docs | interface | README + api.md entries |
| infra | none | LB and monitor config are out of scope |

## Chunks

1. **Add /health route with cached DB probe** — files: src/server.ts, src/routes/health.ts, tests/health.test.ts
2. **Document in README + api.md** — files: README.md, docs/api.md

## Acceptance checklist

Locked before any code. Also saved as `plan/contracts/chunk-1.json` and `plan/contracts/chunk-2.json`.

```json
{
  "chunkId": "1",
  "criteria": [
    { "name": "health_ok", "description": "GET /health with the DB up returns 200 and exactly {status:\"ok\", db:\"ok\"}", "threshold": 8, "verify": "start the server, curl -s -w '%{http_code}' localhost:3000/health" },
    { "name": "db_down_reported", "description": "With the pool rejecting, the response reports db:\"down\" instead of erroring", "threshold": 8, "verify": "npm test -- health -t 'db down'" },
    { "name": "probe_timeout", "description": "With the pool never resolving, the response arrives in ≤5.5s with db:\"down\"", "threshold": 8, "verify": "npm test -- health -t 'timeout'" },
    { "name": "cache_ttl", "description": "Two calls within 1s run one DB query; a call after 1s runs a second", "threshold": 8, "verify": "npm test -- health -t 'cache' (fake timers, count pool.query calls)" },
    { "name": "no_auth_required", "description": "A request with no credentials or cookies gets 200", "threshold": 7, "verify": "curl -s -o /dev/null -w '%{http_code}' localhost:3000/health" },
    { "name": "cold_cache_stampede", "description": "Added by Codex: 50 concurrent requests on a cold cache trigger at most one DB query", "threshold": 7, "verify": "npm test -- health -t 'concurrent'" }
  ]
}
```

```json
{
  "chunkId": "2",
  "criteria": [
    { "name": "readme_documents_route", "description": "README Operations section names GET /health and both db values", "threshold": 7, "verify": "grep -n '/health' README.md" },
    { "name": "api_md_lists_route", "description": "docs/api.md lists GET /health in its route table, marked as requiring no auth", "threshold": 7, "verify": "grep -n 'GET /health' docs/api.md" },
    { "name": "doc_example_matches", "description": "The response example in docs/api.md is byte-identical to a live response with the DB up", "threshold": 7, "verify": "diff <(curl -s localhost:3000/health | jq -S .) <(the example block, jq -S .)" }
  ]
}
```

## Freeze point

Prep enumeration closed at plan approval (standard tier, no prep candidates). Prep ideas found during execution become follow-ups, not scope.

## Open questions

- Should the response include a build SHA or version string? (Default: no — keeps the response cacheable and the surface small.)

## Out of scope

- LB reconfiguration — ops team owns the load balancer config
- Probe configuration in Datadog/UptimeRobot — done post-deploy by the team that owns the monitor
- Auth or rate-limiting — `/health` is intentionally public + unrate-limited per the convention
