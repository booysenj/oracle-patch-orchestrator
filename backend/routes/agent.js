const express = require('express');
const { v4: uuidv4 } = require('uuid');
const { getDB } = require('../lib/db');
const { jobEvents } = require('../lib/job-runner');
const router = express.Router();

const AGENT_SECRET = process.env.AGENT_SECRET || 'change-me';

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

    const job = db.prepare(
        'SELECT j.*, v.script_path, v.node_role FROM jobs j JOIN vms v ON j.vm_id = v.id WHERE j.vm_id = ? AND j.status = ? ORDER BY j.created_at ASC LIMIT 1'
    ).get(vm.id, 'queued');

    if (job === undefined) return res.json({ noJob: true });

    db.prepare(
        'UPDATE jobs SET status = ?, started_at = datetime(?) WHERE id = ?'
    ).run('running', 'now', job.id);

    var phaseArg = job.phase;
    const needsDbName = ['db_switch', 'db_rollback', 'db_switch_scheduled', 'db_upgrade_upgrade', 'db_upgrade_rollback'];
    if (needsDbName.indexOf(job.operation) >= 0 && job.db_unique_name) {
        phaseArg = job.phase + ' ' + job.db_unique_name;
    }

    var env = {};
    if (vm.old_gi_home) env.OLD_GI_HOME = vm.old_gi_home;
    if (vm.new_gi_home) env.NEW_GI_HOME = vm.new_gi_home;
    if (vm.old_db_home) env.OLD_DB_HOME = vm.old_db_home;
    if (vm.new_db_home) env.NEW_DB_HOME = vm.new_db_home;

    if (vm.target_patch_version_id) {
        const pv = db.prepare('SELECT * FROM patch_versions WHERE id = ?').get(vm.target_patch_version_id);
        if (pv) {
            if (pv.gi_base_zip) env.GI_BASE_ZIP = pv.gi_base_zip;
            if (pv.db_base_zip) env.DB_BASE_ZIP = pv.db_base_zip;
            if (pv.opatch_zip) env.OPATCH_ZIP = pv.opatch_zip;
            if (pv.patch_search_root) env.PATCH_SEARCH_ROOTS_ENV = pv.patch_search_root;
            if (pv.new_gi_home) env.NEW_GI_HOME = pv.new_gi_home;
            if (pv.new_db_home) env.NEW_DB_HOME = pv.new_db_home;
        }
    }

    res.json({
        jobId: job.id,
        operation: job.operation,
        phase: job.phase,
        scriptPath: job.script_path,
        phaseArg: phaseArg,
        dryRun: job.dry_run,
        nodeRole: job.node_role,
        stagePath: vm.stage_path || null,
        env: env
    });
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
    var databaseRole = payload.database_role || null;
    var clusterName = payload.cluster_name || null;
    var runningDbs = payload.running_dbs || [];

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

    // Static values — rarely change, only overwrite if not yet set
    var updates = {};
    if (!vm.old_gi_home && gridHome) updates.old_gi_home = gridHome;
    if (!vm.old_db_home && oratab.length > 0) updates.old_db_home = oratab[0].home;
    if (!vm.db_unique_name && dbUniqueName) updates.db_unique_name = dbUniqueName;
    if (!vm.cluster_name && clusterName) updates.cluster_name = clusterName;
    if (!vm.preferred_staging_mount && preferredStaging) updates.preferred_staging_mount = preferredStaging;

    // Dynamic values — always overwrite
    updates.database_role = databaseRole;
    updates.mounts_json = JSON.stringify(mounts);
    updates.last_discovery_at = new Date().toISOString();
    updates.static_json = JSON.stringify({
        grid_home: gridHome,
        db_unique_name: dbUniqueName,
        cluster_name: clusterName,
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

    res.json({ ok: true, preferred_staging: preferredStaging, auto_populated: Object.keys(updates) });
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

    var stagingRoot = job.preferred_staging_mount || job.stage_path || '/home/oracle/staging';

    var lines = [
        '# Generated by insight-patch-ui — job ' + jobId,
        '# DO NOT EDIT — regenerated on each job dispatch',
        '',
        'JOB_ID=' + jobId,
        'HOSTNAME=' + (job.hostname || ''),
        '',
        '# Oracle Homes',
        'OLD_GI_HOME=' + (job.old_gi_home || ''),
        'NEW_GI_HOME=' + (job.new_gi_home || (pv && pv.new_gi_home ? pv.new_gi_home : '')),
        'OLD_DB_HOME=' + (job.old_db_home || ''),
        'NEW_DB_HOME=' + (job.new_db_home || (pv && pv.new_db_home ? pv.new_db_home : '')),
        '',
        '# Database Identity',
        'DB_UNIQUE_NAME=' + (job.db_unique_name || ''),
        'DATABASE_ROLE=' + (job.database_role || ''),
        'CLUSTER_NAME=' + (job.cluster_name || ''),
        '',
        '# Patch Software',
        'GI_BASE_ZIP=' + (pv && pv.gi_base_zip ? pv.gi_base_zip : ''),
        'DB_BASE_ZIP=' + (pv && pv.db_base_zip ? pv.db_base_zip : ''),
        'OPATCH_ZIP=' + (pv && pv.opatch_zip ? pv.opatch_zip : ''),
        'PATCH_SEARCH_ROOTS_ENV=' + (pv && pv.patch_search_root ? pv.patch_search_root : stagingRoot),
        '',
        '# Staging',
        'STAGE_PATH=' + stagingRoot,
        'ORACLE_USER=oracle',
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
        'INSERT INTO patch_reports (id, job_id, hostname, operation, subject, result, html_content) VALUES (?, ?, ?, ?, ?, ?, ?)'
    );
    const discoveryStmt = db.prepare(
        'INSERT INTO discoveries (id, job_id, hostname, type, payload) VALUES (?, ?, ?, ?, ?)'
    );

    const insertBatch = db.transaction(function(items) {
        for (var i = 0; i < items.length; i++) {
            var line = items[i].line || '';

            // Intercept [HTML_REPORT] lines — store as a patch report, skip from log view
            if (line.startsWith('[HTML_REPORT] ')) {
                try {
                    var payload = line.slice('[HTML_REPORT] '.length);
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

            // Intercept [DISCOVERY_JSON] lines — store in discoveries table AND update vm inventory
            if (line.startsWith('[DISCOVERY_JSON] ')) {
                try {
                    var jsonStr = line.slice('[DISCOVERY_JSON] '.length);
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
            jobEvents.emit('log:' + jobId, {
                stream: items[i].stream || 'stdout',
                line: line,
                ts: new Date().toISOString()
            });
        }
    });
    insertBatch(lines);
    res.json({ ok: true, count: lines.length });
});

router.post('/:jobId/complete', (req, res) => {
    var jobId = req.params.jobId;
    var exitCode = req.body.exitCode;

    const db = getDB();
    var status = exitCode === 0 ? 'success' : 'failed';
    db.prepare(
        'UPDATE jobs SET status = ?, exit_code = ?, finished_at = datetime(?) WHERE id = ?'
    ).run(status, exitCode, 'now', jobId);
    jobEvents.emit('done:' + jobId, { status: status, exitCode: exitCode });
    res.json({ ok: true, status: status, exitCode: exitCode });
});

module.exports = router;
