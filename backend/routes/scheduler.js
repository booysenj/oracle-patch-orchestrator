const { v4: uuidv4 } = require('uuid');
const schedule = require('node-schedule');
const { createJob } = require('../lib/job-runner');

module.exports = function(getDB, authenticateToken) {
    const router = require('express').Router();

    // ---- Schema ----
    (function() {
        const db = getDB();
        db.exec(`CREATE TABLE IF NOT EXISTS scheduled_jobs (
            id TEXT PRIMARY KEY,
            name TEXT DEFAULT '',
            vm_ids TEXT DEFAULT '[]',
            operation TEXT NOT NULL,
            patch_version_id TEXT DEFAULT '',
            scheduled_at TEXT NOT NULL,
            timezone TEXT DEFAULT 'Africa/Johannesburg',
            recurrence TEXT DEFAULT '',
            recurrence_cron TEXT DEFAULT '',
            status TEXT DEFAULT 'PENDING',
            execution_mode TEXT DEFAULT 'parallel',
            max_parallel INTEGER DEFAULT 0,
            created_by TEXT DEFAULT '',
            created_at TEXT DEFAULT (datetime('now')),
            updated_at TEXT DEFAULT (datetime('now')),
            started_at TEXT DEFAULT '',
            completed_at TEXT DEFAULT '',
            notes TEXT DEFAULT '',
            last_error TEXT DEFAULT ''
        )`);
        db.exec("CREATE INDEX IF NOT EXISTS idx_sched_status ON scheduled_jobs(status)");
        db.exec("CREATE INDEX IF NOT EXISTS idx_sched_at ON scheduled_jobs(scheduled_at)");
        try { db.exec("ALTER TABLE scheduled_jobs ADD COLUMN notification_sent_at TEXT DEFAULT ''"); } catch(_) {}
        try { db.exec("ALTER TABLE scheduled_jobs ADD COLUMN job_id TEXT DEFAULT ''"); } catch(_) {}
        try { db.exec("ALTER TABLE scheduled_jobs ADD COLUMN triggered_at TEXT DEFAULT ''"); } catch(_) {}

        db.exec(`CREATE TABLE IF NOT EXISTS maintenance_windows (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT DEFAULT '',
            vm_ids TEXT DEFAULT '[]',
            vm_group TEXT DEFAULT '',
            operations TEXT DEFAULT '[]',
            patch_version_id TEXT DEFAULT '',
            cron_expression TEXT NOT NULL,
            timezone TEXT DEFAULT 'Africa/Johannesburg',
            execution_mode TEXT DEFAULT 'sequential',
            max_parallel INTEGER DEFAULT 1,
            is_active INTEGER DEFAULT 1,
            next_run TEXT DEFAULT '',
            last_run TEXT DEFAULT '',
            last_status TEXT DEFAULT '',
            created_by TEXT DEFAULT '',
            created_at TEXT DEFAULT (datetime('now')),
            updated_at TEXT DEFAULT (datetime('now')),
            notes TEXT DEFAULT ''
        )`);
        db.exec("CREATE INDEX IF NOT EXISTS idx_mw_active ON maintenance_windows(is_active)");

        // Add columns if upgrading
        try { db.exec("ALTER TABLE scheduled_jobs ADD COLUMN recurrence TEXT DEFAULT ''"); } catch(e) {}
        try { db.exec("ALTER TABLE scheduled_jobs ADD COLUMN recurrence_cron TEXT DEFAULT ''"); } catch(e) {}
        try { db.exec("ALTER TABLE scheduled_jobs ADD COLUMN execution_mode TEXT DEFAULT 'parallel'"); } catch(e) {}
        try { db.exec("ALTER TABLE scheduled_jobs ADD COLUMN max_parallel INTEGER DEFAULT 0"); } catch(e) {}
    })();

    // ---- In-memory schedule registry ----
    const activeSchedules = {};
    const activeMaintWindows = {};

    // ---- Helper: create jobs for a scheduled run ----
    function executeScheduledJob(schedId) {
        const db = getDB();
        const sched = db.prepare('SELECT * FROM scheduled_jobs WHERE id = ?').get(schedId);
        if (!sched || sched.status === 'CANCELLED') return;

        db.prepare("UPDATE scheduled_jobs SET status = 'RUNNING', started_at = datetime('now'), updated_at = datetime('now') WHERE id = ?").run(schedId);

        try {
            const vmIds = JSON.parse(sched.vm_ids || '[]');
            if (!vmIds.length) {
                db.prepare("UPDATE scheduled_jobs SET status = 'FAILED', last_error = 'No VMs specified', updated_at = datetime('now') WHERE id = ?").run(schedId);
                return;
            }

            const mode = sched.execution_mode || 'parallel';

            if (mode === 'sequential') {
                // Create job for first VM only; completion handler triggers next
                createJobForVM(db, vmIds[0], sched, 0, vmIds);
            } else {
                // Parallel: create all jobs at once
                for (let i = 0; i < vmIds.length; i++) {
                    createJobForVM(db, vmIds[i], sched, i, null);
                }
            }

            if (mode !== 'sequential') {
                db.prepare("UPDATE scheduled_jobs SET status = 'DISPATCHED', updated_at = datetime('now') WHERE id = ?").run(schedId);
            }
        } catch (e) {
            db.prepare("UPDATE scheduled_jobs SET status = 'FAILED', last_error = ?, updated_at = datetime('now') WHERE id = ?").run(e.message, schedId);
        }
    }

    function createJobForVM(db, vmId, sched, seqIndex, seqVmIds) {
        // Use createJob from job-runner so the job is inserted with the correct schema
        // and picked up by the agent poll endpoint.
        const result = createJob({
            vmId,
            operation: sched.operation,
            dryRun: false,
            createdBy: 'scheduler:' + (sched.name || sched.id)
        });
        const jobId = result.jobId;

        // Store scheduling metadata for sequential orchestration and linking
        const meta = {
            scheduled_job_id: sched.id,
            seq_index: seqIndex,
            seq_vm_ids: seqVmIds
        };
        try {
            db.prepare('UPDATE jobs SET meta = ? WHERE id = ?').run(JSON.stringify(meta), jobId);
        } catch(_) {}

        return jobId;
    }

    // ---- Scheduler tick: check for due PENDING schedules every 30s ----
    function startSchedulerTick() {
        setInterval(function() {
            const db = getDB();
            try {
                const due = db.prepare(
                    "SELECT * FROM scheduled_jobs WHERE status = 'PENDING' AND scheduled_at <= strftime('%Y-%m-%dT%H:%M:%fZ', 'now')"
                ).all();

                for (const sched of due) {
                    console.log('[SCHEDULER] Firing scheduled job:', sched.id, sched.name, sched.operation);
                    executeScheduledJob(sched.id);
                }
            } catch (e) {
                console.error('[SCHEDULER] Tick error:', e.message);
            }
        }, 30000);
        console.log('[SCHEDULER] Tick started (30s interval)');
    }

    // ---- Sequential job completion handler ----
    function checkSequentialNext(db, completedJobId) {
        try {
            const job = db.prepare('SELECT * FROM jobs WHERE id = ?').get(completedJobId);
            if (!job || !job.meta) return;
            const meta = JSON.parse(job.meta || '{}');
            if (!meta.seq_vm_ids || !meta.scheduled_job_id) return;

            const nextIndex = (meta.seq_index || 0) + 1;
            if (nextIndex >= meta.seq_vm_ids.length) {
                // All VMs done
                db.prepare("UPDATE scheduled_jobs SET status = 'COMPLETED', completed_at = datetime('now'), updated_at = datetime('now') WHERE id = ?").run(meta.scheduled_job_id);
                return;
            }

            if (job.status === 'COMPLETED') {
                // Trigger next VM
                const sched = db.prepare('SELECT * FROM scheduled_jobs WHERE id = ?').get(meta.scheduled_job_id);
                if (sched) {
                    createJobForVM(db, meta.seq_vm_ids[nextIndex], sched, nextIndex, meta.seq_vm_ids);
                    console.log('[SCHEDULER] Sequential: triggered VM', nextIndex + 1, 'of', meta.seq_vm_ids.length);
                }
            } else {
                // Previous VM failed - mark schedule as failed
                db.prepare("UPDATE scheduled_jobs SET status = 'FAILED', last_error = ?, updated_at = datetime('now') WHERE id = ?")
                    .run('VM ' + (meta.seq_index + 1) + ' failed (' + job.hostname + '). Sequence stopped.', meta.scheduled_job_id);
            }
        } catch (e) {
            console.error('[SCHEDULER] Sequential check error:', e.message);
        }
    }

    // ---- Maintenance Windows: schedule recurring cron jobs ----
    function loadMaintenanceWindows() {
        const db = getDB();
        const windows = db.prepare("SELECT * FROM maintenance_windows WHERE is_active = 1").all();

        // Cancel existing cron schedules
        Object.keys(activeMaintWindows).forEach(function(id) {
            if (activeMaintWindows[id]) activeMaintWindows[id].cancel();
            delete activeMaintWindows[id];
        });

        windows.forEach(function(mw) {
            try {
                const cronJob = schedule.scheduleJob(mw.cron_expression, function() {
                    console.log('[MAINT-WINDOW] Firing:', mw.name, mw.id);
                    const db2 = getDB();

                    // Create a scheduled_job from this maintenance window
                    const schedId = uuidv4();
                    const ops = JSON.parse(mw.operations || '[]');
                    const operation = ops.length > 0 ? ops[0] : 'precheck';

                    db2.prepare(`INSERT INTO scheduled_jobs
                        (id, name, vm_ids, operation, patch_version_id, scheduled_at, timezone,
                         execution_mode, max_parallel, status, notes, created_by)
                        VALUES (?,?,?,?,?,datetime('now'),?,?,?,'PENDING',?,?)`).run(
                        schedId,
                        '[MW] ' + mw.name,
                        mw.vm_ids,
                        operation,
                        mw.patch_version_id || '',
                        mw.timezone || 'Africa/Johannesburg',
                        mw.execution_mode || 'sequential',
                        mw.max_parallel || 1,
                        'Auto-created from maintenance window: ' + mw.name,
                        'system/maintenance-window');

                    db2.prepare("UPDATE maintenance_windows SET last_run = datetime('now'), updated_at = datetime('now') WHERE id = ?").run(mw.id);

                    // The scheduler tick will pick it up within 30s
                });

                if (cronJob) {
                    activeMaintWindows[mw.id] = cronJob;
                    // Update next_run
                    const nextInv = cronJob.nextInvocation();
                    if (nextInv) {
                        db.prepare("UPDATE maintenance_windows SET next_run = ? WHERE id = ?").run(nextInv.toISOString(), mw.id);
                    }
                    console.log('[MAINT-WINDOW] Scheduled:', mw.name, '| Cron:', mw.cron_expression);
                }
            } catch (e) {
                console.error('[MAINT-WINDOW] Failed to schedule', mw.name, ':', e.message);
            }
        });

        console.log('[MAINT-WINDOW] Loaded', Object.keys(activeMaintWindows).length, 'active maintenance windows');
    }

    // ---- ROUTES: Scheduled Jobs ----

    // List all scheduled jobs
    router.get('/', authenticateToken, (req, res) => {
        const db = getDB();
        try {
            let sql = 'SELECT * FROM scheduled_jobs WHERE 1=1';
            const params = [];
            if (req.query.status) { sql += ' AND status = ?'; params.push(req.query.status); }
            sql += ' ORDER BY scheduled_at DESC LIMIT 200';
            const rows = db.prepare(sql).all(...params);
            // Hydrate with VM names
            rows.forEach(function(r) {
                try {
                    const ids = JSON.parse(r.vm_ids || '[]');
                    r.vm_names = ids.map(function(id) {
                        const vm = db.prepare('SELECT hostname FROM vms WHERE id = ?').get(id);
                        return vm ? vm.hostname : id;
                    });
                } catch(e) { r.vm_names = []; }
            });
            res.json(rows);
        } catch (e) { res.status(500).json({ error: e.message }); }
    });

    // Create a scheduled job
    router.post('/', authenticateToken, (req, res) => {
        const db = getDB();
        const b = req.body;
        if (!b.operation) return res.status(400).json({ error: 'operation is required' });
        if (!b.vm_ids || !b.vm_ids.length) return res.status(400).json({ error: 'vm_ids is required' });
        if (!b.scheduled_at) return res.status(400).json({ error: 'scheduled_at is required' });

        // Rollback guard: for rollback ops, ignore patch_version_id
        const isRollback = /rollback/i.test(b.operation);
        const pvId = isRollback ? '' : (b.patch_version_id || '');

        const id = uuidv4();
        try {
            db.prepare(`INSERT INTO scheduled_jobs
                (id, name, vm_ids, operation, patch_version_id, scheduled_at, timezone,
                 execution_mode, max_parallel, status, notes, created_by)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?)`).run(
                id,
                b.name || b.operation + ' - ' + new Date(b.scheduled_at).toLocaleDateString(),
                JSON.stringify(b.vm_ids),
                b.operation,
                pvId,
                b.scheduled_at,
                b.timezone || 'Africa/Johannesburg',
                b.execution_mode || 'parallel',
                b.max_parallel || 0,
                'PENDING',
                b.notes || '',
                req.user ? req.user.username : '');

            res.status(201).json({ id: id, message: 'Scheduled job created', scheduled_at: b.scheduled_at });
        } catch (e) { res.status(500).json({ error: e.message }); }
    });

    // Get a scheduled job
    router.get('/:id', authenticateToken, (req, res) => {
        const db = getDB();
        try {
            const row = db.prepare('SELECT * FROM scheduled_jobs WHERE id = ?').get(req.params.id);
            if (!row) return res.status(404).json({ error: 'Not found' });
            // Get associated jobs
            row.jobs = db.prepare("SELECT id, vm_id, hostname, status, started_at, completed_at FROM jobs WHERE meta LIKE ?")
                .all('%' + req.params.id + '%');
            res.json(row);
        } catch (e) { res.status(500).json({ error: e.message }); }
    });

    // Cancel a scheduled job
    router.delete('/:id', authenticateToken, (req, res) => {
        const db = getDB();
        try {
            const row = db.prepare('SELECT * FROM scheduled_jobs WHERE id = ?').get(req.params.id);
            if (!row) return res.status(404).json({ error: 'Not found' });
            if (row.status !== 'PENDING') return res.status(400).json({ error: 'Can only cancel PENDING schedules' });
            db.prepare("UPDATE scheduled_jobs SET status = 'CANCELLED', updated_at = datetime('now') WHERE id = ?").run(req.params.id);
            res.json({ message: 'Schedule cancelled' });
        } catch (e) { res.status(500).json({ error: e.message }); }
    });

    // Reschedule
    router.put('/:id', authenticateToken, (req, res) => {
        const db = getDB();
        try {
            const row = db.prepare('SELECT * FROM scheduled_jobs WHERE id = ?').get(req.params.id);
            if (!row) return res.status(404).json({ error: 'Not found' });
            if (row.status !== 'PENDING') return res.status(400).json({ error: 'Can only reschedule PENDING jobs' });
            const updates = [];
            const params = [];
            if (req.body.scheduled_at) { updates.push('scheduled_at = ?'); params.push(req.body.scheduled_at); }
            if (req.body.name) { updates.push('name = ?'); params.push(req.body.name); }
            if (req.body.notes) { updates.push('notes = ?'); params.push(req.body.notes); }
            if (req.body.execution_mode) { updates.push('execution_mode = ?'); params.push(req.body.execution_mode); }
            updates.push("updated_at = datetime('now')");
            params.push(req.params.id);
            db.prepare('UPDATE scheduled_jobs SET ' + updates.join(', ') + ' WHERE id = ?').run(...params);
            res.json({ message: 'Schedule updated' });
        } catch (e) { res.status(500).json({ error: e.message }); }
    });

    // ---- ROUTES: Maintenance Windows ----

    router.get('/maintenance/all', authenticateToken, (req, res) => {
        const db = getDB();
        try {
            const rows = db.prepare('SELECT * FROM maintenance_windows ORDER BY created_at DESC').all();
            rows.forEach(function(r) {
                try {
                    const ids = JSON.parse(r.vm_ids || '[]');
                    r.vm_names = ids.map(function(id) {
                        const vm = db.prepare('SELECT hostname FROM vms WHERE id = ?').get(id);
                        return vm ? vm.hostname : id;
                    });
                } catch(e) { r.vm_names = []; }
            });
            res.json(rows);
        } catch (e) { res.status(500).json({ error: e.message }); }
    });

    router.post('/maintenance', authenticateToken, (req, res) => {
        const db = getDB();
        const b = req.body;
        if (!b.name) return res.status(400).json({ error: 'name is required' });
        if (!b.cron_expression) return res.status(400).json({ error: 'cron_expression is required' });
        if (!b.vm_ids || !b.vm_ids.length) return res.status(400).json({ error: 'vm_ids is required' });

        const id = uuidv4();
        try {
            db.prepare(`INSERT INTO maintenance_windows
                (id, name, description, vm_ids, vm_group, operations, patch_version_id,
                 cron_expression, timezone, execution_mode, max_parallel, is_active, notes, created_by)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).run(
                id,
                b.name,
                b.description || '',
                JSON.stringify(b.vm_ids),
                b.vm_group || '',
                JSON.stringify(b.operations || ['precheck']),
                b.patch_version_id || '',
                b.cron_expression,
                b.timezone || 'Africa/Johannesburg',
                b.execution_mode || 'sequential',
                b.max_parallel || 1,
                b.is_active !== false ? 1 : 0,
                b.notes || '',
                req.user ? req.user.username : '');

            // Reload maintenance windows to activate
            loadMaintenanceWindows();

            res.status(201).json({ id: id, message: 'Maintenance window created' });
        } catch (e) { res.status(500).json({ error: e.message }); }
    });

    router.put('/maintenance/:id', authenticateToken, (req, res) => {
        const db = getDB();
        try {
            const row = db.prepare('SELECT * FROM maintenance_windows WHERE id = ?').get(req.params.id);
            if (!row) return res.status(404).json({ error: 'Not found' });
            const updates = [];
            const params = [];
            const fields = ['name','description','cron_expression','timezone','execution_mode','max_parallel','notes','patch_version_id','vm_group'];
            fields.forEach(function(f) {
                if (req.body[f] !== undefined) { updates.push(f + ' = ?'); params.push(req.body[f]); }
            });
            if (req.body.vm_ids) { updates.push('vm_ids = ?'); params.push(JSON.stringify(req.body.vm_ids)); }
            if (req.body.operations) { updates.push('operations = ?'); params.push(JSON.stringify(req.body.operations)); }
            if (req.body.is_active !== undefined) { updates.push('is_active = ?'); params.push(req.body.is_active ? 1 : 0); }
            updates.push("updated_at = datetime('now')");
            params.push(req.params.id);
            db.prepare('UPDATE maintenance_windows SET ' + updates.join(', ') + ' WHERE id = ?').run(...params);
            loadMaintenanceWindows();
            res.json({ message: 'Maintenance window updated' });
        } catch (e) { res.status(500).json({ error: e.message }); }
    });

    router.delete('/maintenance/:id', authenticateToken, (req, res) => {
        const db = getDB();
        try {
            if (activeMaintWindows[req.params.id]) {
                activeMaintWindows[req.params.id].cancel();
                delete activeMaintWindows[req.params.id];
            }
            db.prepare('DELETE FROM maintenance_windows WHERE id = ?').run(req.params.id);
            res.json({ message: 'Maintenance window deleted' });
        } catch (e) { res.status(500).json({ error: e.message }); }
    });

    // Toggle maintenance window active/inactive
    router.put('/maintenance/:id/toggle', authenticateToken, (req, res) => {
        const db = getDB();
        try {
            const row = db.prepare('SELECT * FROM maintenance_windows WHERE id = ?').get(req.params.id);
            if (!row) return res.status(404).json({ error: 'Not found' });
            const newActive = row.is_active ? 0 : 1;
            db.prepare("UPDATE maintenance_windows SET is_active = ?, updated_at = datetime('now') WHERE id = ?").run(newActive, req.params.id);
            loadMaintenanceWindows();
            res.json({ message: newActive ? 'Activated' : 'Deactivated', is_active: newActive });
        } catch (e) { res.status(500).json({ error: e.message }); }
    });

    // ---- Cron presets helper ----
    router.get('/maintenance/cron-presets', authenticateToken, (req, res) => {
        res.json([
            { label: 'Every Friday at 18:00', cron: '0 18 * * 5', description: 'Weekly Friday evening' },
            { label: 'Every Sunday at 02:00', cron: '0 2 * * 0', description: 'Weekly Sunday early morning' },
            { label: '1st Saturday of month at 22:00', cron: '0 22 1-7 * 6', description: 'Monthly first Saturday' },
            { label: '3rd Sunday of month at 02:00', cron: '0 2 15-21 * 0', description: 'Monthly third Sunday' },
            { label: 'Every day at 23:00', cron: '0 23 * * *', description: 'Nightly' },
            { label: 'Last Friday of month at 20:00', cron: '0 20 25-31 * 5', description: 'Monthly last Friday' },
            { label: 'Every 2 weeks Sunday at 03:00', cron: '0 3 1-7,15-21 * 0', description: 'Bi-weekly Sunday' }
        ]);
    });

    // ---- Initialize ----
    startSchedulerTick();
    loadMaintenanceWindows();

    // Export helpers for agent completion hook
    router._checkSequentialNext = checkSequentialNext;

    return router;
};
