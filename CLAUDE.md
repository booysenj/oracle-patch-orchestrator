# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Start the backend (from backend/)
cd backend && node server.js
# or with auto-reload
cd backend && npx nodemon server.js

# Install dependencies (only needed after cloning or adding packages)
cd backend && npm install
```

No build step — frontend is vanilla JS served as static files directly by Express.

No test suite is configured.

## Deploy to server

```bash
# On the orchestrator server (172.16.36.95)
cd /opt/insight-patch-ui && git pull && systemctl restart insight-patch-ui
```

Agent (`insight-agent.py`) auto-updates within ~5 min after server restart via SHA256 check — **only if the agent already has the self-update mechanism** (the version in `frontend/agent-download/insight-agent.py`). The legacy simple agent in `agent/insight-agent.py` has no self-update; it requires a manual SSH redeploy via the Deploy Agent button in the admin UI.

## Architecture

### Components

```
frontend/index.html + app.js   ← Vanilla JS SPA (no bundler, no framework)
        ↓ REST + WebSocket
backend/server.js               ← Express on port 4000, same process serves frontend static files
        ↓ SQLite (better-sqlite3, synchronous — no async DB calls)
backend/data/orchestrator.db
        ↓ job queue (status = 'queued')
agent/insight-agent.py          ← Python, runs on each Oracle VM, polls /api/agent/poll every 5s
        ↓ bash
backend/scripts/os-patch-auto.sh ← Downloaded by agent before every job, contains all patching logic
```

### Job lifecycle

1. UI calls `POST /api/jobs` → `job-runner.js` inserts row with `status='queued'` (agent mode) or runs SSH immediately (legacy SSH mode)
2. Agent polls `/api/agent/poll` → receives job + env vars as JSON
3. Agent runs `bash os-patch-auto.sh <phase_arg>`, streams stdout/stderr to `POST /api/agent/:jobId/logs` in batches of 20 lines
4. Backend stores each line in `job_logs` and emits `jobEvents` (an EventEmitter)
5. `ws-relay.js` forwards `jobEvents` to any subscribed browser WebSocket connections at `/ws/logs`
6. Agent calls `POST /api/agent/:jobId/complete` when done

### Special log line protocols

The bash script embeds structured data in log lines that the backend intercepts in `agent.js`:

| Prefix | What it does |
|---|---|
| `[CHECK] label\|status\|details` | Frontend parses into the live Report tab. Emitted by `add_html_row()` only. |
| `[HTML_REPORT] subject\|<base64>` | Stored in `patch_reports` table as a full HTML report for download. Emitted by `send_html_report()` only when `sendmail` is unavailable. |
| `[DISCOVERY_JSON] {...}` | Updates VM inventory in the DB (GI home, DB home, cluster info, etc). |

**Important**: `_html_row()` is a silent variant of `add_html_row()` — it writes to `HTML_ROWS` for email content but does NOT emit `[CHECK]`. Use it inside `send_db_open_notification()` and other notification-only sub-reports so those rows don't appear in the main phase report tab.

### Report accumulators in the bash script

- `HTML_ROWS` → used by `send_html_report()` for the HTML email body and `[HTML_REPORT]` log line. Fed by `add_html_row()` and `_html_row()`.
- `REPORT_BODY` → used by `send_report()` for plain-text email fallback only. Fed by `add_report_step()`. **Never shown in the UI.**
- `send_phase_html_report` calls `send_html_report` (HTML path). Phases that use `send_phase_html_report` should NOT call `add_report_step()` — `REPORT_BODY` is never sent in that path.

### Rollback homes

After `gi_switch` or `db_switch`, the script emits:
```
[DISCOVERY_JSON] {"type":"home_switched","old_gi_home":"...","new_gi_home":"..."}
```
Backend snapshots `old_gi_home` → `vms.rollback_gi_home` and updates `vms.old_gi_home` = new home.  
The poll endpoint injects `ROLLBACK_GI_HOME` and `ROLLBACK_DB_HOME` into the agent env dict so the bash swap logic in `gi_rollback`/`db_rollback` can target the correct pre-switch home.

### DB schema evolution

New columns are added via `try { d.exec('ALTER TABLE ... ADD COLUMN ...') } catch(_) {}` in `db.js:initDB()`. Always use this pattern — never assume a column exists in a fresh schema; it may only be present after a migration.

### Authentication

- Users authenticate via `POST /api/auth/login` → JWT
- `/api/agent/*` routes use a separate `AGENT_SECRET` bearer token (not JWT) — the agent never logs in
- `authenticateToken` middleware on all user-facing routes; `agentRoutes` has its own `authenticateAgent`

### Frontend

- Single file: `frontend/app.js` (all UI logic) + `frontend/index.html`
- Additional UI modules: `frontend/patches-ui.js`, `frontend/scheduler-ui.js` (loaded separately)
- No bundler. Edit files directly. Backend serves them as static files with `no-cache` on `.js`
- `api(path, opts)` helper wraps `fetch` with the auth token
- Live log streaming: WS is primary; REST polling (`GET /api/logs/:jobId?offset=N`) is fallback when WS is closed

### Key backend routes

| File | Purpose |
|---|---|
| `routes/agent.js` | Poll, log upload, discovery, script delivery, file transfer coordination |
| `routes/jobs.js` | Job CRUD, operations list with priv levels, audit log |
| `routes/vms.js` | VM CRUD, `PATCH /:id/config` for DBA overrides (homes, role, mail, etc.) |
| `routes/admin.js` | SSH key management, deploy-agent, global settings (mail, base paths) |
| `routes/reports.js` | `patch_reports` table — HTML report storage and download |
| `lib/job-runner.js` | `createJob()`, `OPERATION_PHASES` map, `jobEvents` EventEmitter |
| `lib/scheduler-jobs.js` | Checks due scheduled jobs every 30s, times out stale running jobs every 5 min |
| `routes/scheduler.js` | Scheduler CRUD + its own tick that calls `createJob()` from `job-runner.js` |

### Scheduler architecture

Two independent ticks both fire every 30s for PENDING schedules — `routes/scheduler.js` `startSchedulerTick()` and `server.js` calling `checkDueSchedules()` from `scheduler-jobs.js`. They don't conflict (first to fire changes status away from PENDING). Always use `createJob()` from `job-runner.js` to queue scheduled jobs — it knows the correct schema and sets `execution_mode`. Never write a raw INSERT into `jobs` from scheduler code.

### Stale-job timeout

Running jobs time out to `failed` after **30 minutes** (`scheduler-jobs.js:timeoutStaleJobs`). AutoUpgrade-based db_switch takes 1–2 hours. If the backend restarts mid-job, the agent continues running and will POST `/api/agent/:jobId/complete` when done — but if the backend was down at that exact moment, the completion is lost and the job will time out to `failed`. The patch itself may have succeeded even when the job shows `failed`; always verify the Oracle DB state (`v$database`, current home in oratab) before re-running.

### Agent discovery

`insight-agent.py` runs `discover()` on startup and every 60 s (~12 poll cycles). It POSTs to `POST /api/agent/discover` which updates `vms` columns. Fields populated by agent discovery:

| Column | Source |
|---|---|
| `old_gi_home`, `current_db_home`, `old_db_home` | `olr.loc` / CRS process / oratab |
| `running_dbs` (in `static_json`) | `pmon_*` processes |
| `db_unique_name`, `database_role`, `db_version` | sqlplus `v$database` / `v$instance` per SID |
| `db_unique_names` (in `static_json`) | dict `{sid: unique_name}` for all running DBs |
| `cluster_type` | CRS daemon detection: `RAC_ONE_NODE` / `RAC` / `STANDALONE` |
| `crs_version` | `crsctl query crs activeversion` |
| `cluster_name`, `nodes_json` | `olsnodes` |
| `oracle_user`, `grid_user`, `oinstall_group` | file ownership of oracle/crsctl binary |

Fields populated only by `[DISCOVERY_JSON]` lines during job execution (not by periodic discovery): `cluster_type`, `db_version`, `switchover_status`, `rollback_gi_home`, `rollback_db_home`.

### Run Operation modal — DB Unique Name field

For VMs with a single DB, the field auto-fills from `vm.db_unique_name` or `static_json.running_dbs[0]`.  
For VMs with multiple DBs (e.g. OneNodeRAC), a `<select>` dropdown is shown. Values are resolved via `static_json.db_unique_names` (sid→unique_name map) so the actual `db_unique_name` (not the SID) is passed to the bash script. The SID and unique name differ on RAC: SID = `sretest_1`, unique name = `SRETEST`.

### DB-only VMs (DB_ONLY_MODE)

VMs without GI/ASM (`old_gi_home` is null or empty). The listener lives in the DB home and must be managed via `manage_db_only_listener`. In `db_switch_core` and `db_rollback`, `manage_db_only_listener` is called **before** `send_db_open_notification` so users can connect as soon as they receive the "DB Open" email. Listener status is included in that notification via `_html_row` (silent — not shown in main phase Report tab).

