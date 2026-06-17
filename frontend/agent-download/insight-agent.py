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
_cached_script_path = None
_cached_script_mtime = None

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
    df_out = _run("df -BG --output=target,avail 2>/dev/null || df -k")
    skip_prefixes = ('/', '/boot', '/dev', '/proc', '/sys', '/run', 'tmpfs', 'devtmpfs', 'udev')
    for line in df_out.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 2:
            mount = parts[0]
            free_raw = parts[1].replace('G', '').replace('K', '')
            if mount.startswith('/') and not any(mount == s or mount.startswith(s + '/') for s in ('/boot', '/dev', '/proc', '/sys', '/run')):
                try:
                    free_gb = int(free_raw) if 'G' in parts[1] else max(0, int(free_raw) // (1024 * 1024))
                    result['mounts'].append({'mount': mount, 'free_gb': free_gb})
                except ValueError:
                    pass

    # /etc/oratab — static DB registrations
    try:
        with open('/etc/oratab') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    parts = line.split(':')
                    if len(parts) >= 2:
                        sid = parts[0].strip()
                        home = parts[1].strip()
                        if sid and home and sid not in ('+ASM', 'MGMTDB', '*') and not sid.startswith('+'):
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

    # Grid home — detect from running CRS processes
    crs_out = _run("ps -eo args 2>/dev/null | grep -E 'ocssd\\.bin|crsd\\.bin|cssdagent' | grep -v grep | head -1")
    if crs_out:
        m = re.match(r'(/[^\s]+/bin/)', crs_out)
        if m:
            result['grid_home'] = m.group(1).rstrip('/').rsplit('/bin', 1)[0]

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
# Runtime config — fetch per-job conf file and write to /tmp
# ---------------------------------------------------------------------------
def fetch_script(script_url, script_mtime, legacy_path):
    """
    Download the orchestration script from the orchestrator.
    Returns the local path to execute. Falls back to legacy_path if download fails.
    Caches by mtime — only re-downloads when the script changes on the orchestrator.
    """
    global _cached_script_path, _cached_script_mtime

    # If orchestrator hasn't provided a URL, fall back to local copy
    if not script_url:
        return legacy_path or '/home/oracle/os-patch-auto.sh'

    script_dest = '/tmp/oop-script.sh'

    # Skip re-download if mtime matches cached version
    if script_mtime and _cached_script_mtime == script_mtime and _cached_script_path and os.path.exists(_cached_script_path):
        print('[agent] Script unchanged (mtime=%s), using cached %s' % (script_mtime, _cached_script_path))
        return _cached_script_path

    full_url = API_URL + script_url
    print('[agent] Downloading script from %s' % full_url)
    try:
        r = requests.get(full_url, headers=HEADERS, timeout=30)
        if r.status_code == 200:
            content = r.text if hasattr(r, 'text') else r._body
            with open(script_dest, 'w') as f:
                f.write(content)
            os.chmod(script_dest, 0o755)
            _cached_script_path = script_dest
            _cached_script_mtime = script_mtime
            print('[agent] Script downloaded to %s (%d bytes)' % (script_dest, len(content)))
            return script_dest
        else:
            print('[agent] Script download failed: HTTP %d — falling back to %s' % (r.status_code, legacy_path or 'none'))
    except Exception as e:
        print('[agent] Script download error: %s — falling back to %s' % (e, legacy_path or 'none'))

    # Fallback: use previously cached version if available
    if _cached_script_path and os.path.exists(_cached_script_path):
        print('[agent] Using previously cached script: %s' % _cached_script_path)
        return _cached_script_path

    return legacy_path or '/home/oracle/os-patch-auto.sh'

def fetch_runtime_config(job_id):
    """Download per-job runtime conf and write to /tmp/oop-runtime-{jobId}.conf"""
    conf_path = '/tmp/oop-runtime-%s.conf' % job_id
    try:
        r = requests.get(
            API_URL + '/api/agent/' + job_id + '/runtime-config',
            headers=HEADERS, timeout=10
        )
        if r.status_code == 200:
            with open(conf_path, 'w') as f:
                f.write(r.text)
            print('[agent] Runtime config written to %s' % conf_path)
            return conf_path
        else:
            print('[agent] Runtime config fetch error: HTTP %d' % r.status_code)
    except Exception as e:
        print('[agent] Runtime config fetch failed: %s' % e)
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
        requests.post(
            API_URL + '/api/agent/' + job_id + '/logs',
            json={'lines': lines},
            headers=HEADERS, timeout=10
        )
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

    # Download script from orchestrator (or use cached if unchanged)
    script = fetch_script(
        job.get('scriptUrl'),
        job.get('scriptMtime'),
        job.get('scriptPath')  # legacy fallback
    )

    # Fetch per-job runtime config — script will source it
    conf_path = fetch_runtime_config(job_id)

    env = os.environ.copy()
    env['JOB_ID'] = job_id
    if dry_run:
        env['DRYRUN'] = 'true'
    if node_role:
        env['INSIGHT_NODE_ROLE'] = node_role
    if conf_path:
        env['OOP_RUNTIME_CONF'] = conf_path
    # Also pass env vars directly (backward compat)
    if job.get('env'):
        env.update(job['env'])

    cmd = 'bash %s %s' % (script, phase_arg)
    print('[agent] Executing: %s (conf: %s)' % (cmd, conf_path or 'none'))

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

        # Clean up conf file
        if conf_path and os.path.exists(conf_path):
            try:
                os.remove(conf_path)
            except Exception:
                pass

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
