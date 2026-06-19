#!/usr/bin/env python3
import os, sys, time, json as json_mod, subprocess, threading, signal, re

try:
    import requests
except ImportError:
    import urllib.request, urllib.error
    class _Resp:
        def __init__(self, r):
            self.status_code = r.getcode()
            self._raw = r.read()
            self._body = self._raw.decode('utf-8', errors='replace')
        def json(self):
            return json_mod.loads(self._body)
        @property
        def text(self):
            return self._body
        @property
        def content(self):
            return self._raw
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
_cached_script_hash = None
LOG_FLUSH_INTERVAL = 2  # seconds — flush partial batches so UI stays live

HEADERS = {
    'Authorization': 'Bearer ' + AGENT_TOKEN,
    'Content-Type': 'application/json'
}

running = True

def _self_hash():
    import hashlib
    with open(__file__, 'rb') as f:
        return hashlib.sha256(f.read()).hexdigest()

def check_for_update():
    """Download and apply a newer agent version if available, then re-exec.
    INSIGHT_JUST_UPDATED env var breaks infinite-exec loops when hashes diverge
    due to encoding differences (CRLF vs LF). Cleared after one guarded startup."""
    if os.environ.get('INSIGHT_JUST_UPDATED') == '1':
        # We just applied an update — skip the check this time to avoid loops
        del os.environ['INSIGHT_JUST_UPDATED']
        print('[agent] Skipping update check (just updated)')
        return
    try:
        r = requests.get(API_URL + '/api/agent/self/version', headers=HEADERS, timeout=10)
        if r.status_code != 200:
            return
        remote = r.json()
        if remote.get('hash') == _self_hash():
            return
        print('[agent] New version detected — downloading update...')
        dl_headers = {'Authorization': 'Bearer ' + AGENT_TOKEN}
        r2 = requests.get(API_URL + '/api/agent/self/download', headers=dl_headers, timeout=60)
        if r2.status_code != 200:
            print('[agent] Update download failed: HTTP %d' % r2.status_code)
            return
        tmp = __file__ + '.new'
        # Write binary to preserve exact bytes — avoids CRLF/LF hash mismatch
        with open(tmp, 'wb') as f:
            f.write(r2.content)
        os.replace(tmp, __file__)
        os.chmod(__file__, 0o755)
        print('[agent] Update applied — restarting...')
        env = os.environ.copy()
        env['INSIGHT_JUST_UPDATED'] = '1'
        os.execve(sys.executable, [sys.executable] + sys.argv, env)
    except Exception as e:
        print('[agent] Update check failed: %s' % e)

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
    """Run a shell command, return stdout string or '' on error.
    Uses run() so partial output is captured even when exit code != 0 (e.g. stale NFS mount makes df exit 1)."""
    try:
        r = subprocess.run(cmd, shell=True, text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           timeout=timeout)
        return (r.stdout or '').strip()
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

    # Mount points with free space (GB) — read /proc/mounts + os.statvfs()
    # Avoids df PATH issues and stale-NFS hangs that make df block forever.
    _SKIP_FSTYPES = frozenset([
        'tmpfs', 'devtmpfs', 'sysfs', 'proc', 'cgroup', 'cgroup2', 'pstore',
        'securityfs', 'debugfs', 'configfs', 'selinuxfs', 'hugetlbfs', 'mqueue',
        'fusectl', 'bpf', 'tracefs', 'devpts', 'autofs', 'efivarfs',
    ])
    _SKIP_PREFIXES = ('/boot', '/dev', '/proc', '/sys', '/run')
    try:
        with open('/proc/mounts') as _mf:
            for _ml in _mf:
                _mp = _ml.split()
                if len(_mp) < 3:
                    continue
                _mount, _fstype = _mp[1], _mp[2]
                if _fstype in _SKIP_FSTYPES:
                    continue
                if not _mount.startswith('/'):
                    continue
                if any(_mount == s or _mount.startswith(s + '/') for s in _SKIP_PREFIXES):
                    continue
                try:
                    _st = os.statvfs(_mount)
                    _free_gb = (_st.f_bavail * _st.f_frsize) // (1024 ** 3)
                    result['mounts'].append({'mount': _mount, 'free_gb': _free_gb})
                except Exception:
                    pass
    except Exception:
        pass

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

    # Grid home — try olr.loc first (most reliable; works for CRS/RAC and HAS alike),
    # then fall back to process-based detection, then +ASM oratab entry.
    # olr.loc keys seen in the wild: crs_home=, oracle_home=, ORACLE_HOME= (case varies by GI version)
    for _olr in ('/etc/oracle/olr.loc', '/var/opt/oracle/olr.loc'):
        try:
            with open(_olr) as _f:
                for _line in _f:
                    _m = re.match(r'\s*(?:crs_home|oracle_home)\s*=\s*(\S+)', _line, re.IGNORECASE)
                    if _m:
                        _candidate = _m.group(1).strip()
                        # Validate: must look like an absolute path with a bin/ subdirectory
                        if _candidate.startswith('/') and os.path.isdir(_candidate):
                            result['grid_home'] = _candidate
                            break
        except Exception:
            pass
        if result['grid_home']:
            break

    # Process-based fallback: ohasd.bin = Oracle Restart (HAS); ocssd/crsd/cssdagent = full RAC.
    # Also try /proc/<pid>/exe for CRS daemons which may rewrite argv[0].
    if not result['grid_home']:
        crs_out = _run("ps -eo args 2>/dev/null | grep -E 'ocssd\\.bin|crsd\\.bin|cssdagent|ohasd\\.bin' | grep -v grep | head -1")
        if crs_out:
            m = re.match(r'(/[^\s]+/bin/)', crs_out)
            if m:
                result['grid_home'] = m.group(1).rstrip('/').rsplit('/bin', 1)[0]

    if not result['grid_home']:
        # Last resort: find a running CRS/HAS daemon pid via ps comm and resolve its exe symlink
        pid_out = _run("ps -eo pid,comm 2>/dev/null | grep -E 'ocssd|crsd|ohasd|cssdagent' | grep -v grep | awk '{print $1}' | head -1")
        if pid_out.strip():
            try:
                exe = os.readlink('/proc/' + pid_out.strip() + '/exe')
                # exe is something like /grid/oracle/product/19.0.0/grid/bin/ocssd.bin
                if '/bin/' in exe:
                    result['grid_home'] = exe.rsplit('/bin/', 1)[0]
            except Exception:
                pass

    if not result['grid_home'] and asm_home_from_oratab:
        # ASM pmon can appear as different strings depending on OS/Oracle version:
        #   comm: ora_pmon_+ASM1   (most common on Linux)
        #   args: ora_pmon_+ASM1   (same as comm when process renamed itself)
        #   args: /grid/.../oracle +ASM1 (PMON)   (full path form on some systems)
        asm_running = (
            _run("ps -eo comm 2>/dev/null | grep -F 'pmon_+ASM' | grep -v grep") or
            _run("ps -eo comm 2>/dev/null | grep -E 'pmon_[+]?ASM' | grep -v grep") or
            _run("ps -eo args 2>/dev/null | grep -F 'pmon_+ASM' | grep -v grep") or
            _run("ps -eo args 2>/dev/null | grep -E 'pmon_[+]?ASM' | grep -v grep") or
            _run("ps -eo args 2>/dev/null | grep -F 'oracle +ASM' | grep -v grep") or
            _run("ps -eo args 2>/dev/null | grep -E '[+]ASM[0-9]* .PMON.' | grep -v grep")
        )
        if asm_running:
            result['grid_home'] = asm_home_from_oratab

    # DB unique name + role — try each running instance until sqlplus succeeds.
    # RAC instance SIDs have a node-number suffix: source1 → oratab has 'source',
    # or underscore form: sretest_1 → oratab has 'sretest'. Try both strip patterns.
    def _oratab_home(sid):
        home = next((o['home'] for o in result['oratab'] if o['sid'] == sid), None)
        if not home:
            # Strip trailing digits: source1 → source
            base = sid.rstrip('0123456789')
            home = next((o['home'] for o in result['oratab'] if o['sid'] == base), None)
        if not home:
            # Strip _N suffix: sretest_1 → sretest
            base = re.sub(r'_[0-9]+$', '', sid)
            home = next((o['home'] for o in result['oratab'] if o['sid'] == base), None)
        return home

    sql = (
        "SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF\n"
        "WHENEVER SQLERROR CONTINUE\n"
        "SELECT 'UNIQUE='||db_unique_name FROM v$database;\n"
        "SELECT 'ROLE='||database_role FROM v$database;\n"
        "EXIT\n"
    )
    for _sid in result['running_dbs']:
        _home = _oratab_home(_sid)
        if not _home or not os.path.isfile(_home + '/bin/sqlplus'):
            continue
        try:
            _env = os.environ.copy()
            _env['ORACLE_SID'] = _sid
            _env['ORACLE_HOME'] = _home
            _env['PATH'] = _home + '/bin:' + _env.get('PATH', '')
            out = subprocess.check_output(
                [_home + '/bin/sqlplus', '-S', '/ as sysdba'],
                input=sql, text=True, env=_env, timeout=15,
                stderr=subprocess.DEVNULL
            )
            for line in out.splitlines():
                line = line.strip()
                if line.startswith('UNIQUE=') and not result['db_unique_name']:
                    result['db_unique_name'] = line[7:]
                elif line.startswith('ROLE=') and not result['database_role']:
                    result['database_role'] = line[5:]
            if result['database_role']:
                break  # got what we need from this instance
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

def execute_transfer(t):
    """Pull a file from the orchestrator and write it to the target staging path."""
    tid = t['id']
    filename = t.get('filename') or ('transfer_' + tid)
    dest_path = t.get('destPath', '/tmp')
    total_bytes = t.get('totalBytes', 0)

    try:
        os.makedirs(dest_path, exist_ok=True)
        dest_file = os.path.join(dest_path, filename)

        print('[agent] Transfer %s: downloading %s -> %s' % (tid, filename, dest_file))

        download_headers = {'Authorization': 'Bearer ' + AGENT_TOKEN}
        r = requests.get(
            API_URL + '/api/agent/transfer/' + tid,
            headers=download_headers, timeout=3600, stream=True
        )
        if r.status_code != 200:
            raise Exception('HTTP %d from orchestrator' % r.status_code)

        r.raw.decode_content = True
        bytes_received = 0
        last_pct = 0
        with open(dest_file, 'wb') as f:
            while True:
                chunk = r.raw.read(1048576)
                if not chunk:
                    break
                f.write(chunk)
                bytes_received += len(chunk)
                if total_bytes > 0:
                    pct = int(bytes_received * 100 / total_bytes)
                    if pct >= last_pct + 5:
                        last_pct = pct
                        try:
                            requests.post(
                                API_URL + '/api/agent/transfer/' + tid + '/progress',
                                json={'bytesReceived': bytes_received, 'totalBytes': total_bytes},
                                headers=HEADERS, timeout=5
                            )
                        except Exception:
                            pass

        requests.post(
            API_URL + '/api/agent/transfer/' + tid + '/complete',
            json={'success': True, 'bytesReceived': bytes_received},
            headers=HEADERS, timeout=10
        )
        print('[agent] Transfer %s complete: %s (%d bytes)' % (tid, dest_file, bytes_received))

    except Exception as e:
        err_str = str(e)
        print('[agent] Transfer %s failed: %s' % (tid, err_str))
        # Only report permanent failure (e.g. 404 not found, disk full).
        # Connection errors (server restart) → leave status as-is so the server's
        # startup reset or 10-min auto-recovery returns it to PENDING for retry.
        is_conn_error = any(k in err_str for k in ('RemoteDisconnected', 'ConnectionRefused',
                                                    'Connection refused', 'Connection aborted',
                                                    'NewConnectionError', 'timed out'))
        if not is_conn_error:
            try:
                requests.post(
                    API_URL + '/api/agent/transfer/' + tid + '/complete',
                    json={'success': False, 'error': err_str},
                    headers=HEADERS, timeout=10
                )
            except Exception:
                pass

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

    print('[agent] Checking for updates...')
    check_for_update()

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

        # Check for agent updates every 60 polls (~5 min)
        if poll_count % 60 == 0:
            check_for_update()

        # Re-run discovery every 12 polls (~60s at 5s interval)
        if poll_count % 12 == 0:
            try:
                payload = discover()
                post_discovery(payload)
            except Exception as e:
                print('[agent] Discovery error: %s' % e)

        if job and job.get('transfer'):
            execute_transfer(job['transfer'])
        elif job:
            execute_job(job)
        else:
            time.sleep(POLL_INTERVAL)

    print('[agent] Stopped.')

if __name__ == '__main__':
    main()
