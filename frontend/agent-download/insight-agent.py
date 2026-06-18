#!/usr/bin/env python3
import os, sys, time, json as json_mod, subprocess, threading, signal, re

try:
    import requests
except ImportError:
    import urllib.request, urllib.error
    class _Resp:
        def __init__(self, r):
            self.status_code = r.getcode()
            self._body = r.read().decode()
        def json(self):
            return json_mod.loads(self._body)
        @property
        def text(self):
            return self._body
    class requests:
        @staticmethod
        def get(url, **kw):
            req = urllib.request.Request(url, headers=kw.get('headers', {}))
            return _Resp(urllib.request.urlopen(req, timeout=kw.get('timeout', 30)))
        @staticmethod
        def post(url, json=None, **kw):
            data = json_mod.dumps(json).encode() if json else None
            req = urllib.request.Request(url, data=data, headers={**kw.get('headers', {}), 'Content-Type': 'application/json'})
            return _Resp(urllib.request.urlopen(req, timeout=kw.get('timeout', 30)))

API_URL = os.environ.get('INSIGHT_API_URL', 'http://172.16.36.95:4000')
AGENT_TOKEN = os.environ.get('INSIGHT_AGENT_TOKEN', '')
HOSTNAME = os.environ.get('INSIGHT_HOSTNAME', os.uname()[1].split('.')[0])
POLL_INTERVAL = int(os.environ.get('INSIGHT_POLL_INTERVAL', '5'))
LOG_BATCH_SIZE = 5
LOG_FLUSH_INTERVAL = 2  # seconds — flush partial batches so UI stays live

HEADERS = {
    'Authorization': 'Bearer ' + AGENT_TOKEN,
    'Content-Type': 'application/json'
}

running = True
_cached_script_hash = None

def signal_handler(sig, frame):
    global running
    print('[agent] Received signal %d, shutting down...' % sig)
    running = False

signal.signal(signal.SIGTERM, signal_handler)
signal.signal(signal.SIGINT, signal_handler)

# ---------------------------------------------------------------------------
# Discovery — runs on every poll cycle, POSTs system inventory to orchestrator
# ---------------------------------------------------------------------------
def _run(cmd, timeout=10):
    """Run a shell command, return stdout string or '' on error."""
    try:
        return subprocess.check_output(cmd, shell=True, text=True,
                                       stderr=subprocess.DEVNULL, timeout=timeout).strip()
    except Exception:
        return ''

def discover():
    """Collect lightweight system inventory and return a dict."""
    result = {
        'hostname': HOSTNAME,
        'mounts': [],
        'oratab': [],
        'grid_home': None,
        'running_dbs': [],
        'db_unique_name': None,
        'database_role': None,
        'cluster_name': None,
    }

    # Mount points with free space (GB)
    skip_mounts = ('/boot', '/dev', '/proc', '/sys', '/run')

    def _parse_mounts(df_out, kb_mode=False):
        mounts = []
        for line in df_out.splitlines()[1:]:
            parts = line.split()
            if len(parts) < 6:
                continue
            mount = parts[5]
            avail_raw = parts[3]
            if not mount.startswith('/'):
                continue
            if any(mount == s or mount.startswith(s + '/') for s in skip_mounts):
                continue
            try:
                if kb_mode:
                    free_gb = int(avail_raw) // 1048576
                else:
                    free_gb = int(avail_raw.rstrip('G'))
                mounts.append({'mount': mount, 'free_gb': free_gb})
            except ValueError:
                pass
        return mounts

    df_out = _run("df -BG 2>/dev/null")
    result['mounts'] = _parse_mounts(df_out, kb_mode=False)
    if not result['mounts']:
        df_out = _run("df -k 2>/dev/null")
        result['mounts'] = _parse_mounts(df_out, kb_mode=True)

    # /etc/oratab — static DB registrations; also capture +ASM* home as GI home fallback
    asm_home_from_oratab = None
    try:
        with open('/etc/oratab') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    parts = line.split(':')
                    if len(parts) >= 2:
                        sid = parts[0].strip()
                        home = parts[1].strip()
                        if not sid or not home:
                            continue
                        if sid.startswith('+') or sid in ('MGMTDB', '*'):
                            if sid.startswith('+ASM') and home and not asm_home_from_oratab:
                                asm_home_from_oratab = home
                        else:
                            result['oratab'].append({'sid': sid, 'home': home})
    except Exception:
        pass

    # Running DB instances from pmon processes
    pmon_out = _run("ps -eo args 2>/dev/null | grep 'pmon_' | grep -v grep")
    for line in pmon_out.splitlines():
        m = re.search(r'pmon_([A-Za-z0-9_]+)', line)
        if m:
            sid = m.group(1)
            if not sid.startswith('+') and sid not in ('MGMTDB',):
                if sid not in result['running_dbs']:
                    result['running_dbs'].append(sid)

    # Grid home — detect from running CRS processes first, fall back to +ASM oratab entry
    # only if ASM is actually running (pmon_+ASM* process present)
    crs_out = _run("ps -eo args 2>/dev/null | grep -E 'ocssd\\.bin|crsd\\.bin|cssdagent' | grep -v grep | head -1")
    if crs_out:
        m = re.match(r'(/[^\s]+/bin/)', crs_out)
        if m:
            result['grid_home'] = m.group(1).rstrip('/').rsplit('/bin', 1)[0]
    if not result['grid_home'] and asm_home_from_oratab:
        asm_running = _run("ps -eo args 2>/dev/null | grep 'pmon_+ASM' | grep -v grep")
        if asm_running:
            result['grid_home'] = asm_home_from_oratab

    # DB unique name + role — query first running DB via sqlplus
    if result['running_dbs'] and result['oratab']:
        sid = result['running_dbs'][0]
        home = next((o['home'] for o in result['oratab'] if o['sid'] == sid), None)
        if not home and result['oratab']:
            home = result['oratab'][0]['home']
        if home and os.path.isfile(home + '/bin/sqlplus'):
            env = os.environ.copy()
            env['ORACLE_SID'] = sid
            env['ORACLE_HOME'] = home
            env['PATH'] = home + '/bin:' + env.get('PATH', '')
            sql = (
                "SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF\n"
                "WHENEVER SQLERROR CONTINUE\n"
                "SELECT 'UNIQUE='||db_unique_name FROM v$database;\n"
                "SELECT 'ROLE='||database_role FROM v$database;\n"
                "EXIT\n"
            )
            try:
                out = subprocess.check_output(
                    [home + '/bin/sqlplus', '-S', '/ as sysdba'],
                    input=sql, text=True, env=env, timeout=15,
                    stderr=subprocess.DEVNULL
                )
                for line in out.splitlines():
                    line = line.strip()
                    if line.startswith('UNIQUE='):
                        result['db_unique_name'] = line[7:]
                    elif line.startswith('ROLE='):
                        result['database_role'] = line[5:]
            except Exception:
                pass

    # Cluster name — olsnodes or cemutlo
    gi = result['grid_home']
    if gi:
        cn = _run('%s/bin/olsnodes -c 2>/dev/null | head -1' % gi) or \
             _run('%s/bin/cemutlo -n 2>/dev/null | head -1' % gi)
        if cn:
            result['cluster_name'] = cn

    return result

def post_discovery(payload):
    try:
        r = requests.post(
            API_URL + '/api/agent/discover',
            json=payload, headers=HEADERS, timeout=10
        )
        if r.status_code != 200:
            print('[agent] Discovery POST error: HTTP %d' % r.status_code)
    except Exception as e:
        print('[agent] Discovery POST failed: %s' % e)

# ---------------------------------------------------------------------------
# Script download — agent fetches os-patch-auto.sh from orchestrator API,
# caches by SHA256 so it only re-downloads when the script actually changes.
# ---------------------------------------------------------------------------
def _sha256(path):
    import hashlib
    try:
        h = hashlib.sha256()
        with open(path, 'rb') as f:
            for chunk in iter(lambda: f.read(65536), b''):
                h.update(chunk)
        return h.hexdigest()
    except Exception:
        return None

def ensure_script(script_hash):
    """Download /api/agent/script if hash changed or local copy is missing.
    Returns path to script, or None on failure."""
    global _cached_script_hash
    dest = '/tmp/oop-script.sh'

    if script_hash and _cached_script_hash == script_hash and os.path.exists(dest):
        if _sha256(dest) == script_hash:
            return dest

    print('[agent] Downloading script from orchestrator...')
    try:
        r = requests.get(API_URL + '/api/agent/script', headers=HEADERS, timeout=60)
        if r.status_code == 200:
            content = r.text if hasattr(r, 'text') else r._body
            with open(dest, 'w') as f:
                f.write(content)
            os.chmod(dest, 0o755)
            _cached_script_hash = _sha256(dest)
            print('[agent] Script ready: %s  SHA256=%s' % (dest, (_cached_script_hash or '?')[:16]))
            return dest
        else:
            print('[agent] Script download HTTP %d' % r.status_code)
    except Exception as e:
        print('[agent] Script download error: %s' % e)

    if os.path.exists(dest):
        print('[agent] Using cached script from previous download')
        return dest
    return None

# ---------------------------------------------------------------------------
# Core agent loop
# ---------------------------------------------------------------------------
def poll():
    try:
        r = requests.get(
            API_URL + '/api/agent/poll?hostname=' + HOSTNAME,
            headers=HEADERS, timeout=10
        )
        if r.status_code != 200:
            print('[agent] Poll error: HTTP %d' % r.status_code)
            return None
        data = r.json()
        if data.get('noJob'):
            return None
        return data
    except Exception as e:
        print('[agent] Poll failed: %s' % e)
        return None

def send_logs(job_id, lines):
    try:
        r = requests.post(
            API_URL + '/api/agent/' + job_id + '/logs',
            json={'lines': lines},
            headers=HEADERS, timeout=30
        )
        if r.status_code != 200:
            print('[agent] Log send HTTP %d: %s' % (r.status_code, r.text[:200]))
    except Exception as e:
        print('[agent] Log send failed: %s' % e)

def complete_job(job_id, exit_code):
    try:
        requests.post(
            API_URL + '/api/agent/' + job_id + '/complete',
            json={'exitCode': exit_code},
            headers=HEADERS, timeout=10
        )
    except Exception as e:
        print('[agent] Complete failed: %s' % e)

def execute_job(job):
    job_id = job['jobId']
    phase_arg = job['phaseArg']
    dry_run = job.get('dryRun', False)
    node_role = job.get('nodeRole', '')

    # Download script from orchestrator (cached by SHA256 — only re-downloads on change)
    script = ensure_script(job.get('scriptHash'))
    if not script:
        send_logs(job_id, [{'stream': 'stderr', 'line': 'ERROR: could not obtain patch script from orchestrator'}])
        complete_job(job_id, 1)
        return

    env = os.environ.copy()
    env['JOB_ID'] = job_id
    if dry_run:
        env['DRYRUN'] = 'true'
    if node_role:
        env['INSIGHT_NODE_ROLE'] = node_role
    if job.get('env'):
        env.update(job['env'])

    verbose = job.get('verbose', False)
    cmd = 'bash -x %s %s' % (script, phase_arg) if verbose else 'bash %s %s' % (script, phase_arg)
    print('[agent] Executing: %s' % cmd)

    try:
        proc = subprocess.Popen(
            cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=env, bufsize=1, universal_newlines=True
        )

        log_buffer = []
        job_done = threading.Event()

        def stream_output(pipe, stream_name):
            for line in pipe:
                line = line.rstrip('\n')
                if line:
                    log_buffer.append({'stream': stream_name, 'line': line})
                    if len(log_buffer) >= LOG_BATCH_SIZE:
                        batch = log_buffer[:]
                        del log_buffer[:]
                        send_logs(job_id, batch)

        def flush_periodically():
            while not job_done.wait(timeout=LOG_FLUSH_INTERVAL):
                if log_buffer:
                    batch = log_buffer[:]
                    del log_buffer[:]
                    send_logs(job_id, batch)

        t_out = threading.Thread(target=stream_output, args=(proc.stdout, 'stdout'))
        t_err = threading.Thread(target=stream_output, args=(proc.stderr, 'stderr'))
        t_flush = threading.Thread(target=flush_periodically, daemon=True)
        t_out.start()
        t_err.start()
        t_flush.start()

        proc.wait()
        t_out.join()
        t_err.join()
        job_done.set()

        if log_buffer:
            send_logs(job_id, log_buffer)

        print('[agent] Job %s finished with exit code %d' % (job_id, proc.returncode))
        complete_job(job_id, proc.returncode)

    except Exception as e:
        print('[agent] Execution error: %s' % e)
        send_logs(job_id, [{'stream': 'stderr', 'line': 'Agent error: %s' % e}])
        complete_job(job_id, 1)

def main():
    print('[agent] Starting - hostname=%s api=%s poll=%ds' % (HOSTNAME, API_URL, POLL_INTERVAL))
    if not AGENT_TOKEN:
        print('[agent] ERROR: INSIGHT_AGENT_TOKEN not set')
        sys.exit(1)

    print('[agent] Running initial system discovery...')
    try:
        payload = discover()
        post_discovery(payload)
        print('[agent] Discovery: gi=%s db_unique=%s role=%s mounts=%d' % (
            payload.get('grid_home') or 'none',
            payload.get('db_unique_name') or 'none',
            payload.get('database_role') or 'none',
            len(payload.get('mounts', []))
        ))
    except Exception as e:
        print('[agent] Initial discovery error: %s' % e)

    poll_count = 0
    while running:
        job = poll()
        poll_count += 1

        # Re-run discovery every 12 polls (~60s at 5s interval)
        if poll_count % 12 == 0:
            try:
                payload = discover()
                post_discovery(payload)
            except Exception as e:
                print('[agent] Discovery error: %s' % e)

        if job:
            execute_job(job)
        else:
            time.sleep(POLL_INTERVAL)

    print('[agent] Stopped.')

if __name__ == '__main__':
    main()
