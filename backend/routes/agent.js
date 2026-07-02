const express = require('express');
const { v4: uuidv4 } = require('uuid');
const { getDB } = require('../lib/db');
const { jobEvents } = require('../lib/job-runner');
const router = express.Router();

const AGENT_SECRET = process.env.AGENT_SECRET || 'change-me';

// Derive a staging path from the Oracle home when stage_path is not explicitly configured.
// /grid/oracle/product/19.26  →  /grid/software
// /app/oracle/product/19.28   →  /app/software
function deriveStageFromHome(home) {
    if (!home) return '';
    var parts = home.split('/').filter(Boolean);
    return parts.length ? '/' + parts[0] + '/software' : '';
}

// Resolve the target home path the same way the X-Unzip-To logic does (vm override →
// patch_versions override → configured home_base + version). Used to record which home
// a successful gi_install/db_install/*_oh_switch actually targeted.
function deriveTargetHome(db, vm, patchVersionId, homeType) {
    var vmExplicit = homeType === 'db' ? vm.new_db_home : vm.new_gi_home;
    if (vmExplicit) return vmExplicit;
    var pv = patchVersionId ? db.prepare('SELECT version, new_gi_home, new_db_home FROM patch_versions WHERE id=?').get(patchVersionId) : null;
    var pvExplicit = pv && (homeType === 'db' ? pv.new_db_home : pv.new_gi_home);
    if (pvExplicit) return pvExplicit;
    if (!pv || !pv.version) return '';
    var cfgKey = homeType === 'db' ? 'db_home_base' : 'gi_home_base';
    var cfgBase = '';
    try { var bs = db.prepare('SELECT value FROM app_settings WHERE key=?').get(cfgKey); if (bs && bs.value) cfgBase = bs.value.replace(/\/$/, ''); } catch(_) {}
    var oldHome = homeType === 'db' ? (vm.old_db_home || vm.current_db_home) : vm.old_gi_home;
    var base = cfgBase || (oldHome ? oldHome.replace(/\/[^/]+$/, '') : '');
    return (base && pv.version) ? base + '/' + pv.version : '';
}

// Record (or refresh) an installed_homes row after a successful install/switch job.
function recordInstalledHome(db, job) {
    var homeType = /^gi_/.test(job.operation) ? 'gi' : 'db';
    var vm = db.prepare('SELECT * FROM vms WHERE id=?').get(job.vm_id);
    if (!vm) return;
    var homePath = deriveTargetHome(db, vm, job.target_patch_version_id, homeType);
    if (!homePath) return;
    try {
        db.prepare(`
            INSERT INTO installed_homes (id, vm_id, home_type, home_path, patch_version_id, installed_by_job_id, status, first_seen_missing_at, cleared_at)
            VALUES (?, ?, ?, ?, ?, ?, 'active', NULL, NULL)
            ON CONFLICT(vm_id, home_path) DO UPDATE SET
                patch_version_id = excluded.patch_version_id,
                installed_by_job_id = excluded.installed_by_job_id,
                status = 'active', first_seen_missing_at = NULL, cleared_at = NULL
        `).run(uuidv4(), job.vm_id, homeType, homePath, job.target_patch_version_id || null, job.id);
    } catch(e) { console.error('[installed_homes] record error:', e.message); }
}

function authenticateAgent(req, res, next) {
    const auth = req.headers.authorization;
    var expected = 'Bearer ' + AGENT_SECRET;
    if (auth !== expected) {
        return res.status(401).json({ error: 'Invalid agent token' });
    }
    next();
}

router.use(authenticateAgent);

router.get('/poll', (req, res) => {
    var hostname = req.query.hostname;
    if (hostname === undefined) return res.status(400).json({ error: 'hostname required' });

    const db = getDB();
    const vm = db.prepare('SELECT * FROM vms WHERE hostname = ?').get(hostname);
    if (vm === undefined) return res.status(404).json({ error: 'VM not found' });

    // Record heartbeat so dashboard can show agent online/offline status
    db.prepare(`UPDATE vms SET agent_last_seen = datetime('now') WHERE id = ?`).run(vm.id);

    // Recover stuck TRANSFERRING transfers (agent died mid-transfer, >60 min ago)
    // 60 min threshold: large depot tar streams (RU ~1-2 GB) over slow inter-subnet links
    // can take 30-60 min; resetting too early causes the agent to loop and never complete.
    db.prepare(
        "UPDATE patch_transfers SET status='PENDING', started_at=NULL WHERE target_host=? AND status='TRANSFERRING' AND started_at < datetime('now', '-60 minutes')"
    ).run(hostname);

    // Check for a pending file transfer first (transfers don't block jobs)
    const pendingTransfer = db.prepare(
        "SELECT * FROM patch_transfers WHERE target_host = ? AND status = 'PENDING' ORDER BY created_at ASC LIMIT 1"
    ).get(hostname);
    if (pendingTransfer) {
        db.prepare("UPDATE patch_transfers SET status='TRANSFERRING', started_at=datetime('now'), phase='' WHERE id=?").run(pendingTransfer.id);
        return res.json({
            transfer: {
                id: pendingTransfer.id,
                filename: pendingTransfer.file_name || require('path').basename(pendingTransfer.source_path || '') || ('transfer_' + pendingTransfer.id),
                destPath: pendingTransfer.target_stage_path,
                totalBytes: pendingTransfer.total_bytes || 0
            }
        });
    }

    // Find the next queued job — but gate install ops until all required transfers are STAGED.
    // Without the gate, the agent picks up a db_install/gi_install immediately after job creation
    // and fails because the base zip and RU haven't arrived on the VM yet.
    // Prechecks are gated on the RU only — it stages to a safe directory (not the live
    // home), so it's fetched automatically instead of just reporting "RU missing".
    // gi_base/db_base/opatch are NOT staged for prechecks (see job-runner.js) since
    // those unzip straight into the live home.
    const GATED_OPS = new Set(['gi_install','db_install','gi_upgrade_install','db_upgrade_install','gi_precheck','db_precheck']);
    const REQUIRED_TYPES = {
        gi_install:         ['gi_base','ru_patch','opatch'],
        db_install:         ['db_base','ru_patch','opatch'],
        gi_upgrade_install: ['gi_base','ru_patch','opatch'],
        db_upgrade_install: ['db_base','ru_patch','opatch'],
        gi_precheck:        ['ru_patch'],
        db_precheck:        ['ru_patch'],
    };

    const queuedJobs = db.prepare(
        'SELECT j.*, v.script_path, v.node_role, v.rollback_gi_home, v.rollback_db_home FROM jobs j JOIN vms v ON j.vm_id = v.id WHERE j.vm_id = ? AND j.status = ? ORDER BY j.created_at ASC'
    ).all(vm.id, 'queued');

    let job = null;
    try {
    for (const candidate of queuedJobs) {
        // Dry-run jobs never have real transfers queued for them (see job-runner.js) and
        // must never be held waiting for software that will never arrive — run immediately.
        if (GATED_OPS.has(candidate.operation) && candidate.target_patch_version_id && !candidate.dry_run) {
            var required = REQUIRED_TYPES[candidate.operation] || [];
            // DB_ONLY VMs have no GI home — job-runner never queues gi_base for them, so exclude it from the gate
            if (!vm.old_gi_home) required = required.filter(function(t) { return t !== 'gi_base'; });
            const pvId = candidate.target_patch_version_id;
            // If no typed transfers exist at all (old runs before file_type column was added),
            // skip the gate so legacy transfers don't block the job forever.
            const totalForPatch = db.prepare(
                "SELECT count(*) as n FROM patch_transfers WHERE patch_id=? AND target_host=?"
            ).get(pvId, hostname);
            const hasTypedTransfers = totalForPatch && totalForPatch.n > 0 &&
                db.prepare("SELECT 1 FROM patch_transfers WHERE patch_id=? AND target_host=? AND file_type != ''").get(pvId, hostname);
            const allStaged = !hasTypedTransfers || required.every(function(ft) {
                return db.prepare(
                    "SELECT 1 FROM patch_transfers WHERE patch_id=? AND target_host=? AND file_type=? AND status='STAGED'"
                ).get(pvId, hostname, ft);
            });
            if (!allStaged) {
                // If a required transfer has permanently FAILED with nothing PENDING/
                // TRANSFERRING/STAGED backing it, this job can never proceed on its own —
                // it would otherwise sit as 'queued' looking stuck until the 30-min
                // stale-job timeout eventually caught it. Fail fast with a clear reason.
                const stuckTypes = required.filter(function(ft) {
                    const hasActive = db.prepare(
                        "SELECT 1 FROM patch_transfers WHERE patch_id=? AND target_host=? AND file_type=? AND status IN ('PENDING','TRANSFERRING','STAGED')"
                    ).get(pvId, hostname, ft);
                    const hasFailed = db.prepare(
                        "SELECT 1 FROM patch_transfers WHERE patch_id=? AND target_host=? AND file_type=? AND status='FAILED'"
                    ).get(pvId, hostname, ft);
                    return !hasActive && hasFailed;
                });
                if (stuckTypes.length) {
                    // Pull the actual error for each stuck type so the reason is visible
                    // in the UI, not just the server console — this job never gets
                    // dispatched to the agent, so no job_logs rows would otherwise exist
                    // at all and the Logs/Report modal would show nothing.
                    const reasons = stuckTypes.map(function(ft) {
                        const failedRow = db.prepare(
                            "SELECT error_message FROM patch_transfers WHERE patch_id=? AND target_host=? AND file_type=? AND status='FAILED' ORDER BY completed_at DESC LIMIT 1"
                        ).get(pvId, hostname, ft);
                        return ft + (failedRow && failedRow.error_message ? ': ' + failedRow.error_message : '');
                    });
                    const failMsg = 'Required transfer(s) permanently failed with no retry in flight — ' + reasons.join(' | ') +
                        '. Re-run this operation to retry (the failed transfer(s) reset automatically for a new job).';
                    db.prepare("UPDATE jobs SET status='failed', exit_code=-1, started_at=datetime('now'), finished_at=datetime('now') WHERE id=?").run(candidate.id);
                    db.prepare("INSERT INTO job_logs (job_id, stream, line) VALUES (?, 'system', ?)").run(candidate.id, failMsg);
                    console.log('[poll] Job ' + candidate.id + ' (' + candidate.operation + ') failed: ' + failMsg);
                    continue;
                }
                // Log once per job (not every 5s poll) to avoid noise
                const pendingCount = db.prepare(
                    "SELECT count(*) as n FROM patch_transfers WHERE patch_id=? AND target_host=? AND status IN ('PENDING','TRANSFERRING')"
                ).get(pvId, hostname);
                if (pendingCount && pendingCount.n > 0) {
                    console.log('[poll] Job ' + candidate.id + ' (' + candidate.operation + ') waiting for ' + pendingCount.n + ' transfer(s) to STAGE on ' + hostname);
                }
                continue; // skip this job, check next
            }
        }
        job = candidate;
        break;
    }
    } catch(gateErr) {
        console.error('[poll] Gate check error for ' + hostname + ':', gateErr.message);
        return res.status(500).json({ error: 'Poll gate error: ' + gateErr.message });
    }

    if (job === null) return res.json({ noJob: true });

    db.prepare(
        'UPDATE jobs SET status = ?, started_at = datetime(?) WHERE id = ?'
    ).run('running', 'now', job.id);

    var phaseArg = job.phase;
    const needsDbName = ['db_oh_switch', 'db_rollback', 'db_oh_switch_scheduled', 'db_upgrade_upgrade', 'db_upgrade_rollback'];
    if (needsDbName.indexOf(job.operation) >= 0 && job.db_unique_name) {
        phaseArg = job.phase + ' ' + job.db_unique_name;
    }

    // Get configured home base paths from app_settings (may be empty — fallback to auto-strip)
    var giHomeBase = '', dbHomeBase = '';
    try {
        var _s = db.prepare("SELECT value FROM app_settings WHERE key='gi_home_base'").get();
        if (_s && _s.value) giHomeBase = _s.value.replace(/\/$/, '');
        _s = db.prepare("SELECT value FROM app_settings WHERE key='db_home_base'").get();
        if (_s && _s.value) dbHomeBase = _s.value.replace(/\/$/, '');
    } catch(_e) {}

    function _base(oldHome, cfgBase) {
        if (cfgBase) return cfgBase;
        if (!oldHome) return '';
        return oldHome.replace(/\/[^/]+$/, '');  // strip last segment e.g. 19c → base
    }
    function _deriveHome(explicit, pvExplicit, base, version) {
        if (explicit) return explicit;
        if (pvExplicit) return pvExplicit;
        if (!base || !version) return '';
        return base + '/' + version;
    }

    // Email settings: per-VM override > global admin setting
    var globalMailTo = '', globalMailFrom = '';
    try {
        var _ms = db.prepare("SELECT value FROM app_settings WHERE key='mail_to'").get();
        if (_ms && _ms.value) globalMailTo = _ms.value;
        _ms = db.prepare("SELECT value FROM app_settings WHERE key='mail_from'").get();
        if (_ms && _ms.value) globalMailFrom = _ms.value;
    } catch(_e) {}
    var _mailTo   = vm.mail_to   || globalMailTo;
    var _mailFrom = vm.mail_from || globalMailFrom;

    var env = {};
    var dbOldHome = vm.old_db_home || vm.current_db_home || '';
    if (vm.old_gi_home) env.OLD_GI_HOME = vm.old_gi_home;
    if (dbOldHome)      env.OLD_DB_HOME  = dbOldHome;
    if (_mailTo)        env.MAIL_TO      = _mailTo;
    if (_mailFrom)      env.MAIL_FROM    = _mailFrom;
    // Staging path — drives STAGING_DROP_DIR and is prepended to PATCH_SEARCH_ROOTS_ENV
    // so the bash script finds staged files in the VM's configured staging location.
    var stagingPath = vm.stage_path || vm.preferred_staging_mount ||
        deriveStageFromHome(vm.old_gi_home || vm.old_db_home || vm.current_db_home);
    if (stagingPath) {
        env.STAGE_PATH = stagingPath;
        var _defaultRoots = '/grid/software:/app/software:/app/software/db_software/patches:/staging/software';
        var _existingRoots = env.PATCH_SEARCH_ROOTS_ENV || _defaultRoots;
        if (_existingRoots.indexOf(stagingPath) < 0) {
            env.PATCH_SEARCH_ROOTS_ENV = stagingPath + ':' + _existingRoots;
        }
    }
    // Rollback homes — snapshotted at last gi_switch/db_switch via home_switched DISCOVERY_JSON.
    // Required by gi_rollback/db_rollback so the script targets the pre-switch home even after
    // discovery updates old_gi_home/old_db_home to the post-switch value.
    if (job.rollback_gi_home) env.ROLLBACK_GI_HOME = job.rollback_gi_home;
    if (job.rollback_db_home) env.ROLLBACK_DB_HOME = job.rollback_db_home;

    // Global admin settings — fallback when patch version doesn't override
    var globalGiZip = '', globalDbZip = '', globalPatchesBase = '';
    try {
        var _gs = db.prepare("SELECT value FROM app_settings WHERE key='gi_base_zip_path'").get();
        if (_gs && _gs.value) globalGiZip = _gs.value;
        _gs = db.prepare("SELECT value FROM app_settings WHERE key='db_base_zip_path'").get();
        if (_gs && _gs.value) globalDbZip = _gs.value;
        _gs = db.prepare("SELECT value FROM app_settings WHERE key='patches_base_path'").get();
        if (_gs && _gs.value) globalPatchesBase = _gs.value;
    } catch(_ge) {}

    var pv = null, pvVersion = vm.patch_target || '';
    if (job.target_patch_version_id) {
        pv = db.prepare('SELECT * FROM patch_versions WHERE id = ?').get(job.target_patch_version_id);
        if (pv) {
            if (pv.version)          pvVersion              = pv.version;
            if (pv.gi_base_zip)      env.GI_BASE_ZIP        = pv.gi_base_zip;
            if (pv.db_base_zip)      env.DB_BASE_ZIP        = pv.db_base_zip;
            if (pv.opatch_zip)       env.OPATCH_ZIP         = pv.opatch_zip;
            if (pv.patch_search_root) env.PATCH_SEARCH_ROOTS_ENV = pv.patch_search_root;
        }
    }
    // Always pass the selected patch version so the bash script can pin RU discovery
    // to the correct p<version> directory instead of always picking the latest p19.x
    if (pvVersion) env.PATCH_TARGET_VERSION = pvVersion;

    // Fall back to global admin ZIP paths when patch version doesn't set them
    if (!env.GI_BASE_ZIP && globalGiZip) env.GI_BASE_ZIP = globalGiZip;
    if (!env.DB_BASE_ZIP && globalDbZip) env.DB_BASE_ZIP = globalDbZip;
    // patches_base_path: add as a search root with version appended (e.g. /backup/patches/p19.30)
    if (globalPatchesBase && pvVersion) {
        var _patchRoot = globalPatchesBase + '/p' + pvVersion;
        if (!env.PATCH_SEARCH_ROOTS_ENV) {
            env.PATCH_SEARCH_ROOTS_ENV = _patchRoot;
        } else if (env.PATCH_SEARCH_ROOTS_ENV.indexOf(_patchRoot) < 0) {
            env.PATCH_SEARCH_ROOTS_ENV = _patchRoot + ':' + env.PATCH_SEARCH_ROOTS_ENV;
        }
    }

    // Re-inject staging path AFTER patch version config — pv.patch_search_root at line 144
    // overwrites PATCH_SEARCH_ROOTS_ENV and drops the staging path added earlier.
    if (stagingPath) {
        if (!env.PATCH_SEARCH_ROOTS_ENV) {
            env.PATCH_SEARCH_ROOTS_ENV = stagingPath;
        } else if (env.PATCH_SEARCH_ROOTS_ENV.indexOf(stagingPath) < 0) {
            env.PATCH_SEARCH_ROOTS_ENV = stagingPath + ':' + env.PATCH_SEARCH_ROOTS_ENV;
        }
        // GI_BASE_ZIP / DB_BASE_ZIP no longer need staging-path overrides:
        // the new zip-transfer approach unzips directly into NEW_GI_HOME / NEW_DB_HOME,
        // so the bash script finds gridSetup.sh / runInstaller there and skips the zip.
    }

    // Derive NEW_GI_HOME / NEW_DB_HOME: explicit stored > patch version explicit > base + version
    var newGiHome = vm.old_gi_home
        ? _deriveHome(vm.new_gi_home, pv && pv.new_gi_home, _base(vm.old_gi_home, giHomeBase), pvVersion)
        : '';
    var newDbHome = _deriveHome(vm.new_db_home, pv && pv.new_db_home, _base(dbOldHome, dbHomeBase), pvVersion);
    if (newGiHome) env.NEW_GI_HOME = newGiHome;
    if (newDbHome) env.NEW_DB_HOME = newDbHome;

    var crypto = require('crypto'), fs = require('fs'), path = require('path');
    var scriptFile = path.join(__dirname, '..', 'scripts', 'os-patch-auto.sh');
    var scriptHash = null;
    try {
        scriptHash = crypto.createHash('sha256').update(fs.readFileSync(scriptFile)).digest('hex');
    } catch(_) {}

    res.json({
        jobId: job.id,
        operation: job.operation,
        phase: job.phase,
        scriptHash: scriptHash,
        phaseArg: phaseArg,
        dryRun: job.dry_run,
        verbose: job.verbose ? true : false,
        applyOjvm: job.apply_ojvm ? true : false,
        nodeRole: job.node_role,
        stagePath: vm.stage_path || null,
        env: env
    });
});

// Script delivery — agent downloads os-patch-auto.sh before each job
router.get('/script', (req, res) => {
    var fs = require('fs'), path = require('path'), crypto = require('crypto');
    var scriptPath = path.join(__dirname, '..', 'scripts', 'os-patch-auto.sh');
    if (!fs.existsSync(scriptPath)) return res.status(404).json({ error: 'Script not found on orchestrator' });
    var scriptBytes = fs.readFileSync(scriptPath);
    var hash = crypto.createHash('sha256').update(scriptBytes).digest('hex');
    res.setHeader('Content-Type', 'text/x-shellscript; charset=utf-8');
    res.setHeader('X-Script-Hash', hash);
    res.send(scriptBytes);
});

// Discovery — agent POSTs system inventory on every poll cycle
router.post('/discover', (req, res) => {
    var payload = req.body;
    var hostname = payload.hostname;
    if (!hostname) return res.status(400).json({ error: 'hostname required' });

    const db = getDB();
    const vm = db.prepare('SELECT * FROM vms WHERE hostname = ?').get(hostname);
    if (!vm) return res.status(404).json({ error: 'VM not found' });

    var mounts = payload.mounts || [];
    var oratab = payload.oratab || [];
    var gridHome = payload.grid_home || null;
    var dbUniqueName = payload.db_unique_name || null;
    var dbUniqueNames = payload.db_unique_names || {};  // sid -> unique_name map
    var dbRoles = payload.db_roles || {};              // unique_name -> role map
    var dbHomes = payload.db_homes || {};              // unique_name -> oracle_home map
    var databaseRole = payload.database_role || null;
    var clusterName = payload.cluster_name || null;
    var clusterType = payload.cluster_type || null;
    var crsVersion = payload.crs_version || null;
    var dbVersion = payload.db_version || null;
    var runningDbs = payload.running_dbs || [];
    var oracleUser = payload.oracle_user || null;
    var gridUser = payload.grid_user || null;
    var oinstallGroup = payload.oinstall_group || null;

    // Derive best staging mount — largest free mount that isn't / or /boot
    var preferredStaging = vm.preferred_staging_mount || null;
    if (!preferredStaging && mounts.length > 0) {
        var candidates = mounts.filter(function(m) {
            return m.mount && m.mount !== '/' && !m.mount.startsWith('/boot') &&
                   !m.mount.startsWith('/dev') && !m.mount.startsWith('/proc') &&
                   !m.mount.startsWith('/sys') && !m.mount.startsWith('/run');
        });
        if (candidates.length > 0) {
            candidates.sort(function(a, b) { return (b.free_gb || 0) - (a.free_gb || 0); });
            preferredStaging = candidates[0].mount + '/software';
        }
    }

    // Static values — always update GI home from agent (null clears it for DB-only VMs)
    var updates = {};
    // old_gi_home: update only when agent positively reports a GI home.
    // Never clear — a temporary detection failure shouldn't wipe the stored value.
    // To remove a wrong GI home on a DB-only VM, use Override Config.
    if (gridHome) updates.old_gi_home = gridHome;
    // old_db_home = pre-patch baseline — write-once so rollback always knows where to return
    if ((!vm.old_db_home || vm.old_db_home === '') && oratab.length > 0) updates.old_db_home = oratab[0].home;
    // current_db_home = live oratab value — always updated so card reflects post-switch state
    if (oratab.length > 0) updates.current_db_home = oratab[0].home;
    // Always refresh db_unique_name from discovery — keeps it current after switches/renames
    if (dbUniqueName) updates.db_unique_name = dbUniqueName;
    if (!vm.cluster_name && clusterName) updates.cluster_name = clusterName;
    // cluster_type and CRS version from agent discovery (overwrite — can change after patching)
    if (clusterType) updates.cluster_type = clusterType;
    if (crsVersion) updates.crs_version = crsVersion;
    if (dbVersion) updates.db_version = dbVersion;
    if (!vm.preferred_staging_mount && preferredStaging) updates.preferred_staging_mount = preferredStaging;
    // OS identity — write-once; only updated if discovered and currently unset
    if (oracleUser && !vm.oracle_user) updates.oracle_user = oracleUser;
    if (gridUser && !vm.grid_user) updates.grid_user = gridUser;
    if (oinstallGroup && !vm.oinstall_group) updates.oinstall_group = oinstallGroup;
    var scanName = payload.scan_name || null;
    var scanPort = payload.scan_port || null;
    var nodesList = payload.nodes || [];
    if (scanName) updates.scan_name = scanName;
    if (scanPort) updates.scan_port = scanPort;
    if (nodesList.length) updates.nodes_json = JSON.stringify(nodesList);

    // Dynamic values — always overwrite
    updates.database_role = databaseRole;
    updates.mounts_json = JSON.stringify(mounts);
    updates.last_discovery_at = new Date().toISOString();
    updates.static_json = JSON.stringify({
        grid_home: gridHome,
        db_unique_name: dbUniqueName,
        db_unique_names: dbUniqueNames,
        db_roles: dbRoles,
        db_homes: dbHomes,
        cluster_name: clusterName,
        cluster_type: clusterType,
        oratab: oratab,
        running_dbs: runningDbs
    });
    updates.dynamic_json = JSON.stringify({
        database_role: databaseRole,
        mounts: mounts,
        running_dbs: runningDbs
    });

    var cols = Object.keys(updates).map(function(k) { return k + ' = ?'; }).join(', ');
    var vals = Object.values(updates);
    vals.push(vm.id);
    db.prepare('UPDATE vms SET ' + cols + ' WHERE id = ?').run(...vals);

    // Apply any home-existence results the agent reported from the previous cycle's
    // homesToVerify list (see below). first_seen_missing_at is only set the first time a
    // home is reported missing — it's not reset on every check — so cleanupStaleHomes()
    // can measure how long it's been gone. A later exists=true clears it (self-healing).
    var homeChecks = payload.home_checks || [];
    if (homeChecks.length) {
        var updStmt = db.prepare(`
            UPDATE installed_homes SET
                last_verified_at = datetime('now'),
                last_verified_exists = ?,
                first_seen_missing_at = CASE
                    WHEN ? = 1 THEN NULL
                    WHEN first_seen_missing_at IS NULL THEN datetime('now')
                    ELSE first_seen_missing_at
                END
            WHERE id = ? AND status = 'active'
        `);
        homeChecks.forEach(function(c) {
            if (!c || !c.id) return;
            var existsFlag = c.exists ? 1 : 0;
            updStmt.run(existsFlag, existsFlag, c.id);
        });
    }

    // Tell the agent which tracked homes to check existence for next cycle — capped so a
    // VM with many homes doesn't turn every discovery into a filesystem-stat storm.
    var homesToVerify = db.prepare(`
        SELECT id, home_path AS path FROM installed_homes
        WHERE vm_id = ? AND status = 'active'
          AND (last_verified_at IS NULL OR last_verified_at < datetime('now', '-24 hours'))
        LIMIT 5
    `).all(vm.id);

    res.json({ ok: true, preferred_staging: preferredStaging, auto_populated: Object.keys(updates), homesToVerify: homesToVerify });
});

// Runtime config — returns shell-sourceable conf for a specific job
router.get('/:jobId/runtime-config', (req, res) => {
    var jobId = req.params.jobId;
    const db = getDB();
    var job = db.prepare('SELECT j.*, v.* FROM jobs j JOIN vms v ON j.vm_id = v.id WHERE j.id = ?').get(jobId);
    if (!job) return res.status(404).json({ error: 'Job not found' });

    var pv = null;
    if (job.target_patch_version_id) {
        pv = db.prepare('SELECT * FROM patch_versions WHERE id = ?').get(job.target_patch_version_id);
    }

    // App-level base paths + mail defaults from app_settings
    var giHomeBase = '', dbHomeBase = '', globalMailTo = '', globalMailFrom = '';
    try {
        var r = db.prepare("SELECT value FROM app_settings WHERE key = 'gi_home_base'").get();
        if (r && r.value) giHomeBase = r.value.replace(/\/$/, '');
        r = db.prepare("SELECT value FROM app_settings WHERE key = 'db_home_base'").get();
        if (r && r.value) dbHomeBase = r.value.replace(/\/$/, '');
        r = db.prepare("SELECT value FROM app_settings WHERE key = 'mail_to'").get();
        if (r && r.value) globalMailTo = r.value;
        r = db.prepare("SELECT value FROM app_settings WHERE key = 'mail_from'").get();
        if (r && r.value) globalMailFrom = r.value;
    } catch(_) {}
    // Per-VM override > global setting > script default
    var mailTo   = job.mail_to   || globalMailTo   || '';
    var mailFrom = job.mail_from || globalMailFrom  || '';

    // Derive new homes: explicit VM override > patch version explicit > auto from base+version
    // Falls back to vm.patch_target as version when no patch_version record is linked
    function deriveHome(explicitVal, pvVal, base, version) {
        if (explicitVal) return explicitVal;
        if (pvVal) return pvVal;
        if (base && version) return base + '/' + version;
        return '';
    }
    // Auto-derive base from old home when no global setting configured
    // e.g. old_gi_home=/grid/oracle/product/19c  → giHomeBase=/grid/oracle/product
    function baseFromOldHome(oldHome, configBase) {
        if (configBase) return configBase;
        if (!oldHome) return '';
        return oldHome.replace(/\/[^/]+$/, ''); // strip last path segment
    }
    var pvVersion = (pv && pv.version) ? pv.version : (job.patch_target || '');
    var effectiveGiBase = baseFromOldHome(job.old_gi_home, giHomeBase);
    var effectiveDbBase = baseFromOldHome(job.old_db_home, dbHomeBase);
    // Only derive NEW_GI_HOME if this VM actually has GI (old_gi_home is set)
    var newGiHome = job.old_gi_home
        ? deriveHome(job.new_gi_home, pv && pv.new_gi_home, effectiveGiBase, pvVersion)
        : '';
    var newDbHome = deriveHome(job.new_db_home, pv && pv.new_db_home, effectiveDbBase, pvVersion);

    var stagingRoot = job.stage_path || job.preferred_staging_mount ||
        deriveStageFromHome(job.old_gi_home || job.old_db_home) || '/home/oracle/staging';

    var lines = [
        '# Generated by insight-patch-ui — job ' + jobId,
        '# DO NOT EDIT — regenerated on each job dispatch',
        '',
        'JOB_ID=' + jobId,
        'HOSTNAME=' + (job.hostname || ''),
        '',
        '# Oracle Homes (OLD from agent discovery, NEW from patch version / base path + version)',
        'OLD_GI_HOME=' + (job.old_gi_home || ''),
        'NEW_GI_HOME=' + newGiHome,
        'OLD_DB_HOME=' + (job.old_db_home || ''),
        'NEW_DB_HOME=' + newDbHome,
        '# Rollback homes — snapshotted at last gi_switch/db_switch (fading: only one step back)',
        'ROLLBACK_GI_HOME=' + (job.rollback_gi_home || ''),
        'ROLLBACK_DB_HOME=' + (job.rollback_db_home || ''),
        '',
        '# Database Identity',
        'DB_UNIQUE_NAME=' + (job.db_unique_name || ''),
        'DATABASE_ROLE=' + (job.database_role || ''),
        '',
        '# Cluster / SCAN — populated from agent discovery',
        'GI_CLUSTER_NAME=' + (job.cluster_name || ''),
        'GI_SCAN_NAME=' + (job.scan_name || ''),
        'GI_SCAN_PORT=' + (job.scan_port || '1521'),
        'GI_CLUSTER_NODES=' + (function() {
            try { return (JSON.parse(job.nodes_json || '[]')).join(','); } catch(_) { return ''; }
        })(),
        'DB_CLUSTER_NODES=' + (function() {
            try { return (JSON.parse(job.nodes_json || '[]')).join(','); } catch(_) { return ''; }
        })(),
        '',
        '# Patch Software',
        'GI_BASE_ZIP=' + (pv && pv.gi_base_zip ? pv.gi_base_zip : ''),
        'DB_BASE_ZIP=' + (pv && pv.db_base_zip ? pv.db_base_zip : ''),
        'OPATCH_ZIP=' + (pv && pv.opatch_zip ? pv.opatch_zip : ''),
        '',
        '# Staging',
        'STAGE_PATH=' + stagingRoot,
        // Preferred staging mount first so stage_software and autoconfigure_patches
        // find patches immediately; well-known fallbacks cover manual layouts.
        'PATCH_SEARCH_ROOTS_ENV=' + (function() {
            if (pv && pv.patch_search_root) return pv.patch_search_root;
            var roots = [];
            if (stagingRoot && stagingRoot !== '/home/oracle/staging') roots.push(stagingRoot);
            ['/grid/software', '/app/software', '/app/software/db_software/patches', '/staging/software']
                .forEach(function(r) { if (roots.indexOf(r) < 0) roots.push(r); });
            return roots.join(':');
        })(),
        '',
        '# Job options — injected flags override script defaults',
        'APPLY_OJVM=' + (job.apply_ojvm ? 'true' : 'false'),
        '',
        '# OS Identity (discovered from file ownership on the target VM)',
        'ORACLE_USER=' + (job.oracle_user || 'oracle'),
        'GRID_USER=' + (job.grid_user || job.oracle_user || 'oracle'),
        'OINSTALL=' + (job.oinstall_group || 'oinstall'),
        '',
        '# Email (per-VM override > global setting > script default)',
        'MAIL_TO=' + mailTo,
        'MAIL_FROM=' + mailFrom,
    ];

    res.setHeader('Content-Type', 'text/plain; charset=utf-8');
    res.send(lines.join('\n') + '\n');
});

router.post('/:jobId/logs', (req, res) => {
    var jobId = req.params.jobId;
    var lines = req.body.lines;
    if (lines === undefined || lines.length === undefined) return res.status(400).json({ error: 'lines array required' });

    const db = getDB();
    const stmt = db.prepare('INSERT INTO job_logs (job_id, stream, line) VALUES (?, ?, ?)');
    const reportStmt = db.prepare(
        'INSERT INTO patch_reports (id, job_id, hostname, operation, subject, result, content) VALUES (?, ?, ?, ?, ?, ?, ?)'
    );
    const discoveryStmt = db.prepare(
        'INSERT INTO discoveries (id, job_id, hostname, type, payload) VALUES (?, ?, ?, ?, ?)'
    );

    var wsEvents = []; // collect events to emit after transaction commits

    const insertBatch = db.transaction(function(items) {
        for (var i = 0; i < items.length; i++) {
            var line = items[i].line || '';

            // Intercept [HTML_REPORT] lines — store as a patch report, skip from log view
            // Use indexOf (not startsWith) because log() prepends a timestamp prefix
            var _hrIdx = line.indexOf('[HTML_REPORT] ');
            if (_hrIdx >= 0) {
                try {
                    var payload = line.slice(_hrIdx + '[HTML_REPORT] '.length);
                    var pipeIdx = payload.indexOf('|');
                    var subject = pipeIdx >= 0 ? payload.slice(0, pipeIdx) : 'Report';
                    var b64 = pipeIdx >= 0 ? payload.slice(pipeIdx + 1) : payload;
                    var html = Buffer.from(b64, 'base64').toString('utf8');
                    var job = db.prepare('SELECT j.*, v.hostname FROM jobs j LEFT JOIN vms v ON j.vm_id = v.id WHERE j.id = ?').get(jobId);
                    var result = subject.toLowerCase().includes('fail') ? 'failed'
                               : subject.toLowerCase().includes('incomplete') ? 'failed' : 'success';
                    reportStmt.run(uuidv4(), jobId, job ? job.hostname : null, job ? job.operation : null, subject, result, html);
                } catch(e) {
                    console.error('[agent] Failed to store HTML report:', e.message);
                }
                continue; // don't add to job_logs
            }

            // Intercept [TRANSFER_RESET] lines — the bash script hits this when a depot
            // home is missing AND the source zip is also missing (e.g. someone manually
            // deleted an extracted home after the agent already cleaned up its zip copy
            // post-extract). Reset the matching STAGED transfer back to PENDING so the
            // next job creation for this patch/host automatically re-fetches it, instead
            // of requiring manual SQL every time this happens.
            var _trIdx = line.indexOf('[TRANSFER_RESET] ');
            if (_trIdx >= 0) {
                try {
                    var fileType = line.slice(_trIdx + '[TRANSFER_RESET] '.length).trim();
                    var trJob = db.prepare('SELECT j.*, v.hostname FROM jobs j LEFT JOIN vms v ON j.vm_id = v.id WHERE j.id = ?').get(jobId);
                    if (trJob && trJob.target_patch_version_id && trJob.hostname && fileType) {
                        var reset = db.prepare(
                            "UPDATE patch_transfers SET status='PENDING', bytes_transferred=0, started_at=NULL, completed_at=NULL, phase='' " +
                            "WHERE patch_id=? AND target_host=? AND file_type=? AND status='STAGED'"
                        ).run(trJob.target_patch_version_id, trJob.hostname, fileType);
                        if (reset.changes) {
                            console.log('[agent] [TRANSFER_RESET] reset ' + fileType + ' transfer to PENDING for ' + trJob.hostname + ' (job ' + jobId + ')');
                        }
                        // Flag the job itself so Job History can show "auto re-staging" instead
                        // of a plain Failed badge, whether or not a STAGED row existed to reset.
                        db.prepare('UPDATE jobs SET retry_reset_file_type=? WHERE id=?').run(fileType, jobId);
                    }
                } catch(e) {
                    console.error('[agent] Failed to process TRANSFER_RESET:', e.message);
                }
                // fall through — still record this as a normal log line too, since it's
                // useful context in the job's own Logs tab, unlike HTML_REPORT/DISCOVERY_JSON
                // which are pure noise there.
            }

            // Intercept [DISCOVERY_JSON] lines — store in discoveries table AND update vm inventory
            var _djIdx = line.indexOf('[DISCOVERY_JSON] ');
            if (_djIdx >= 0) {
                try {
                    var jsonStr = line.slice(_djIdx + '[DISCOVERY_JSON] '.length);
                    var parsed = JSON.parse(jsonStr);
                    var discJob = db.prepare('SELECT j.*, v.* FROM jobs j LEFT JOIN vms v ON j.vm_id = v.id WHERE j.id = ?').get(jobId);
                    discoveryStmt.run(uuidv4(), jobId, discJob ? discJob.hostname : null, parsed.type || 'unknown', jsonStr);

                    // Feed discovery back into vm inventory — only overwrite if not yet set
                    if (discJob) {
                        var vmUpdates = {};
                        var type = parsed.type || '';

                        if (type === 'db_discovery') {
                            // DB home: oracle_home from discovery populates old_db_home
                            if (!discJob.old_db_home && parsed.oracle_home) vmUpdates.old_db_home = parsed.oracle_home;
                            if (!discJob.db_unique_name && parsed.db_unique_name) vmUpdates.db_unique_name = parsed.db_unique_name;
                            // Database role always refreshed (changes during switchover)
                            if (parsed.database_role) vmUpdates.database_role = parsed.database_role;
                            if (parsed.switchover_status) vmUpdates.switchover_status = parsed.switchover_status;
                            if (parsed.cluster_type) vmUpdates.cluster_type = parsed.cluster_type;
                            if (parsed.db_version) vmUpdates.db_version = parsed.db_version;
                            // Store full static identity
                            vmUpdates.static_json = JSON.stringify({
                                db_name: parsed.db_name,
                                db_unique_name: parsed.db_unique_name,
                                database_role: parsed.database_role,
                                open_mode: parsed.open_mode,
                                switchover_status: parsed.switchover_status,
                                protection_mode: parsed.protection_mode,
                                oracle_home: parsed.oracle_home,
                                db_version: parsed.db_version,
                                cluster_type: parsed.cluster_type,
                                instances: parsed.instances || [],
                                services: parsed.services || []
                            });
                        } else if (type === 'gi_discovery') {
                            if (!discJob.old_gi_home && parsed.grid_home) vmUpdates.old_gi_home = parsed.grid_home;
                            if (!discJob.cluster_name && parsed.cluster_name) vmUpdates.cluster_name = parsed.cluster_name;
                            if (parsed.crs_active_version) vmUpdates.crs_version = parsed.crs_active_version;
                            if (parsed.nodes && parsed.nodes.length) vmUpdates.nodes_json = JSON.stringify(parsed.nodes);
                        } else if (type === 'staged_software') {
                            // Emitted by stage_software after extracting the RU ZIP.
                            // ru_version e.g. "19.29" drives all subsequent home derivations.
                            if (parsed.ru_version) vmUpdates.patch_target = parsed.ru_version;
                        } else if (type === 'home_switched') {
                            // Emitted by gi_switch / db_switch after the switch completes.
                            // Snapshot the OLD home as the rollback target so future rollbacks
                            // always go back to the home that was active before this switch,
                            // not an even older one (fading).
                            if (parsed.old_gi_home) vmUpdates.rollback_gi_home = parsed.old_gi_home;
                            if (parsed.old_db_home) vmUpdates.rollback_db_home = parsed.old_db_home;
                            if (parsed.new_gi_home) vmUpdates.old_gi_home = parsed.new_gi_home;
                            if (parsed.new_db_home) vmUpdates.old_db_home = parsed.new_db_home;
                        }

                        if (Object.keys(vmUpdates).length > 0) {
                            var setCols = Object.keys(vmUpdates).map(function(k) { return k + ' = ?'; }).join(', ');
                            var setVals = Object.values(vmUpdates);
                            setVals.push(discJob.vm_id);
                            try {
                                db.prepare('UPDATE vms SET ' + setCols + ' WHERE id = ?').run(...setVals);
                            } catch(ue) {
                                // Column may not exist yet on old DBs — add it and retry
                                Object.keys(vmUpdates).forEach(function(col) {
                                    try { db.exec('ALTER TABLE vms ADD COLUMN ' + col + ' TEXT'); } catch(_) {}
                                });
                                db.prepare('UPDATE vms SET ' + setCols + ' WHERE id = ?').run(...setVals);
                            }
                        }
                    }
                } catch(e) {
                    console.error('[agent] Failed to store discovery JSON:', e.message);
                }
                continue; // don't add to job_logs
            }

            stmt.run(jobId, items[i].stream || 'stdout', line);
            wsEvents.push({ stream: items[i].stream || 'stdout', line: line, ts: new Date().toISOString() });
        }
    });
    try {
        insertBatch(lines);
    } catch(e) {
        console.error('[agent] insertBatch failed:', e.message);
        return res.status(500).json({ error: 'Failed to store logs: ' + e.message });
    }
    // Emit WebSocket events after transaction commits — keeps WS errors from rolling back DB writes
    for (var i = 0; i < wsEvents.length; i++) {
        try { jobEvents.emit('log:' + jobId, wsEvents[i]); } catch(_) {}
    }
    res.json({ ok: true, count: lines.length });
});

router.post('/:jobId/complete', (req, res) => {
    var jobId = req.params.jobId;
    var exitCode = req.body.exitCode;

    const db = getDB();
    var status = exitCode === 0 ? 'success' : 'failed';

    // Scan [CHECK] log lines for WARN/FAIL rows to determine actual oracle-level result.
    // A clean exit (0) with FAIL rows → 'failed'; with WARN rows → 'warn'.
    if (exitCode === 0) {
        var logs = db.prepare(
            "SELECT line FROM job_logs WHERE job_id = ? AND line LIKE '%[CHECK]%'"
        ).all(jobId);
        var hasFail = logs.some(function(r) { return r.line.indexOf('|FAIL|') >= 0; });
        var hasWarn = logs.some(function(r) { return r.line.indexOf('|WARN|') >= 0; });
        if (hasFail) status = 'failed';
        else if (hasWarn) status = 'warn';
    }

    db.prepare(
        'UPDATE jobs SET status = ?, exit_code = ?, finished_at = datetime(?) WHERE id = ?'
    ).run(status, exitCode, 'now', jobId);

    // Track the home this job installed/switched to, so it can later be verified to
    // still exist on disk and auto-cleared if manually deinstalled (see installed_homes).
    if (status === 'success') {
        var INSTALL_OPS = ['gi_install', 'db_install', 'gi_oh_switch', 'db_oh_switch', 'gi_upgrade_install', 'db_upgrade_install'];
        var completedJob = db.prepare('SELECT * FROM jobs WHERE id=?').get(jobId);
        if (completedJob && INSTALL_OPS.indexOf(completedJob.operation) >= 0 && !completedJob.dry_run) {
            recordInstalledHome(db, completedJob);
        }
    }

    jobEvents.emit('done:' + jobId, { status: status, exitCode: exitCode });
    res.json({ ok: true, status: status, exitCode: exitCode });
});

// GET /api/agent/transfer/:id — agent pulls file content
// If a ready depot exists for this patch+type, streams a tar of the pre-extracted directory.
// Otherwise falls back to serving the raw zip.
router.get('/transfer/:id', (req, res) => {
    const db = getDB();
    const fs = require('fs');
    const path = require('path');
    const { spawn } = require('child_process');
    const t = db.prepare('SELECT * FROM patch_transfers WHERE id = ?').get(req.params.id);
    if (!t) return res.status(404).json({ error: 'Transfer not found' });

    // gi_base and db_base: serve zip directly — agent downloads then unzips on the VM.
    // This halves network traffic (zip is ~7 GB vs ~14 GB extracted) and avoids the
    // orchestrator needing pre-extracted depot copies for large base installers.
    // Pass X-Unzip-To so the agent knows where to unzip (NEW_GI_HOME / NEW_DB_HOME).
    var fileType = t.file_type || 'ru_patch';
    if (fileType === 'gi_base' || fileType === 'db_base') {
        var _vmRow2 = db.prepare('SELECT * FROM vms WHERE hostname=? OR ip=?').get(t.target_host, t.target_host);
        if (_vmRow2 && t.patch_id) {
            var _pv3 = db.prepare('SELECT version, new_gi_home, new_db_home FROM patch_versions WHERE id=?').get(t.patch_id);
            var _pvVer3 = _pv3 && _pv3.version;
            var _explicit3 = _pv3 && (fileType === 'db_base' ? _pv3.new_db_home : _pv3.new_gi_home);
            var _vmExplicit3 = fileType === 'db_base' ? _vmRow2.new_db_home : _vmRow2.new_gi_home;
            var _unzipTo = _vmExplicit3 || _explicit3 || '';
            if (!_unzipTo && _pvVer3) {
                var _cfgKey3 = fileType === 'db_base' ? 'db_home_base' : 'gi_home_base';
                var _cfgBase3 = '';
                try { var _bs3 = db.prepare('SELECT value FROM app_settings WHERE key=?').get(_cfgKey3); if (_bs3 && _bs3.value) _cfgBase3 = _bs3.value.replace(/\/$/, ''); } catch(_) {}
                var _oldH3 = fileType === 'db_base' ? (_vmRow2.old_db_home || _vmRow2.current_db_home) : _vmRow2.old_gi_home;
                var _base3 = _cfgBase3 || (_oldH3 ? _oldH3.replace(/\/[^/]+$/, '') : '');
                if (_base3 && _pvVer3) _unzipTo = _base3 + '/' + _pvVer3;
            }
            if (_unzipTo) res.setHeader('X-Unzip-To', _unzipTo);
        }
        // Fall through to raw zip serving below
    } else if (fileType === 'ru_patch') {
        // RU: unzip to the staging path — creates the patch number subdir (e.g. 38629535/) there
        // which the bash script finds via PATCH_SEARCH_ROOTS_ENV
        if (t.target_stage_path) res.setHeader('X-Unzip-To', t.target_stage_path);
    } else if (fileType === 'opatch') {
        // OPatch: unzip directly into NEW_GI_HOME or NEW_DB_HOME to replace the bundled OPatch.
        // Try GI home first, fall back to DB home — one of the two will be set depending on the operation.
        var _vmRowOp = db.prepare('SELECT * FROM vms WHERE hostname=? OR ip=?').get(t.target_host, t.target_host);
        if (_vmRowOp && t.patch_id) {
            var _pvOp = db.prepare('SELECT version, new_gi_home, new_db_home FROM patch_versions WHERE id=?').get(t.patch_id);
            var _pvVerOp = _pvOp && _pvOp.version;
            var _unzipToOp = (_vmRowOp.new_gi_home || (_pvOp && _pvOp.new_gi_home))
                          || (_vmRowOp.new_db_home  || (_pvOp && _pvOp.new_db_home)) || '';
            if (!_unzipToOp && _pvVerOp) {
                // Derive from the old GI home base first, then DB home base
                var _oldHOp = _vmRowOp.old_gi_home || _vmRowOp.old_db_home || _vmRowOp.current_db_home;
                var _isGiOp = !!_vmRowOp.old_gi_home;
                var _cfgKeyOp = _isGiOp ? 'gi_home_base' : 'db_home_base';
                var _cfgBaseOp = '';
                try { var _bsOp = db.prepare('SELECT value FROM app_settings WHERE key=?').get(_cfgKeyOp); if (_bsOp && _bsOp.value) _cfgBaseOp = _bsOp.value.replace(/\/$/, ''); } catch(_) {}
                var _baseOp = _cfgBaseOp || (_oldHOp ? _oldHOp.replace(/\/[^/]+$/, '') : '');
                if (_baseOp && _pvVerOp) _unzipToOp = _baseOp + '/' + _pvVerOp;
            }
            if (_unzipToOp) res.setHeader('X-Unzip-To', _unzipToOp);
        }
    }
    var src = t.source_path;
    if (!src || !fs.existsSync(src)) return res.status(404).json({ error: 'Source file not found: ' + src });
    var stat = fs.statSync(src);
    if (stat.isDirectory()) {
        // source_path is a directory — find the right file inside it
        var files = fs.readdirSync(src).filter(function(f) { return f.endsWith('.zip'); });
        if (files.length === 0) return res.status(400).json({ error: 'No .zip files found in directory: ' + src });
        var ft = t.file_type || '';
        var chosen;
        if (ft === 'opatch') {
            chosen = files.find(function(f) { return f.startsWith('p6880880'); }) || files[0];
        } else {
            // Pick largest zip (RU) — exclude OPatch
            var ruFiles = files.filter(function(f) { return !f.startsWith('p6880880'); });
            chosen = ruFiles.length > 0 ? ruFiles[0] : files[0];
        }
        src = path.join(src, chosen);
        stat = fs.statSync(src);
        // Record the resolved filename so the UI can display it and the agent saves it correctly
        try { db.prepare("UPDATE patch_transfers SET file_name=? WHERE id=?").run(path.basename(src), t.id); } catch(_) {}
    }
    res.setHeader('Content-Length', stat.size);
    res.setHeader('Content-Type', 'application/octet-stream');
    res.setHeader('X-Filename', path.basename(src));
    res.setHeader('X-Total-Bytes', stat.size);
    var stream = fs.createReadStream(src);
    stream.on('error', function(err) {
        console.error('[transfer] Stream error for ' + src + ':', err.message);
        if (!res.headersSent) res.status(500).json({ error: 'Stream error: ' + err.message });
        else res.destroy();
    });
    stream.pipe(res);
});

// POST /api/agent/transfer/:id/complete — agent reports transfer done or failed
router.post('/transfer/:id/complete', (req, res) => {
    const db = getDB();
    const { success, error, bytesReceived, actualFilename } = req.body || {};
    if (success) {
        var stmt = "UPDATE patch_transfers SET status='STAGED', bytes_transferred=?, checksum_verified=1, completed_at=datetime('now')" +
            (actualFilename ? ", file_name=?" : "") + " WHERE id=?";
        var args = actualFilename
            ? [bytesReceived || 0, actualFilename, req.params.id]
            : [bytesReceived || 0, req.params.id];
        db.prepare(stmt).run(...args);
    } else {
        db.prepare("UPDATE patch_transfers SET status='FAILED', error_message=?, completed_at=datetime('now') WHERE id=?")
            .run(error || 'Agent reported failure', req.params.id);
    }
    res.json({ ok: true });
});

// POST /api/agent/transfer/:id/progress — agent reports bytes received so far
router.post('/transfer/:id/progress', (req, res) => {
    const db = getDB();
    const { bytesReceived, totalBytes, phase } = req.body || {};
    if (phase) {
        // Phase-only ping (e.g. "extracting") — don't stomp bytes_transferred/total_bytes
        // with zeros if the agent didn't also send them on this particular call.
        db.prepare("UPDATE patch_transfers SET phase=? WHERE id=?").run(phase, req.params.id);
    } else {
        db.prepare("UPDATE patch_transfers SET bytes_transferred=?, total_bytes=? WHERE id=?")
            .run(bytesReceived || 0, totalBytes || 0, req.params.id);
    }
    res.json({ ok: true });
});

// GET /api/agent/self/version — returns SHA-256 hash of current agent script
router.get('/self/version', (req, res) => {
    const crypto = require('crypto');
    const fs = require('fs');
    const agentPath = require('path').join(__dirname, '..', '..', 'frontend', 'agent-download', 'insight-agent.py');
    try {
        const hash = crypto.createHash('sha256').update(fs.readFileSync(agentPath)).digest('hex');
        const stat = fs.statSync(agentPath);
        res.json({ hash, size: stat.size });
    } catch (e) {
        res.status(500).json({ error: 'Could not read agent script: ' + e.message });
    }
});

// GET /api/agent/self/download — serves the latest agent script
router.get('/self/download', (req, res) => {
    const fs = require('fs');
    const agentPath = require('path').join(__dirname, '..', '..', 'frontend', 'agent-download', 'insight-agent.py');
    if (!fs.existsSync(agentPath)) return res.status(404).json({ error: 'Agent script not found' });
    res.setHeader('Content-Type', 'text/x-python');
    res.setHeader('Content-Disposition', 'attachment; filename="insight-agent.py"');
    fs.createReadStream(agentPath).pipe(res);
});

module.exports = router;
