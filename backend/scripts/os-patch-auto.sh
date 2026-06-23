# ============================================================
# 🔽 PASTE YOUR FULL ORCHESTRATOR SCRIPT BELOW THIS LINE
# ============================================================
#!/bin/sh
# Re-exec under bash when launched by sh/EPC
if [ -z "${BASH_VERSION:-}" ]; then
    if [ -n "${REEXEC_DONE:-}" ]; then
        echo "ERROR: bash is required but re-exec into bash failed." >&2
        exit 1
    fi
    REEXEC_DONE=1
    export REEXEC_DONE
    exec /bin/bash "$0" "$@"
fi
# ============================================================
# Oracle OS, GI + DB Out-of-Place Patch & Upgrade Orchestrator (PROD)
# Author : Jason Booysen, Alrick Speller
# Version: 0.0.2 (OOP + 19c->23/26ai Upgrades)
#
# Major features:
#   - GI/DB out-of-place patching (existing)
#   - GI/DB out-of-place upgrade 19c -> 23/26ai via separate ?upgrade? homes
#   - GI upgrade precheck with ASM compat + RPM/kernel checks
#   - DB upgrade precheck using AutoUpgrade ANALYZE + HTML mail attachment
#   - Dynamic 23ai GI responsefiles (clusterUsage, clusterNodes, sudoPath)
#   - HTML colour-coded mail with attachments
#   - SSH remote orchestration (opt-in): DB VM orchestrates APP VM
#     shutdown/startup via patchuser SSH for cross-VM patching
#
# Prerequisites:
#   - The oracle OS user must be able to execute sudo commands as root
#     without being prompted for a password. This is required for GI
#     upgrade steps that invoke root scripts automatically.
#
#     Example entry in /etc/sudoers:
#       oracle ALL=(ALL) NOPASSWD:ALL
#
# Recommended Memory and CPU requirement: 16g and 8 respectively.
#
# Cluster / OS maintenance notes (added for MEC / VM patching flow):
#   - cluster_precheck now prints DB summaries safely using perl HTML->text conversion
#     (avoids the previous sed unterminated substitution issue on Oracle VMs)
#   - PMON-based cluster precheck now handles multiple matching SIDs per DB name
#   - cluster_os_patch is the live OS patching phase and is intended to run before downtime
#   - cluster_reboot is the downtime phase and delegates controlled shutdown/reboot to
#     insight_shutdown-osgidb.sh
#   - cluster_postreboot_db is now validation-focused and no longer re-runs the startup
#     script when called from the normal shutdown wrapper path, avoiding duplicate startup
#     execution and duplicate mail
#
# SSH Remote Orchestration notes:
#   - Opt-in via ENABLE_SSH_REMOTE_ORCHESTRATION=true (default: false)
#   - Creates a dedicated 'patchuser' account in 'patchgrp' group (no Oracle dependency)
#   - Scripts at /etc/patching/shutdown_services.sh and /etc/patching/startup_services.sh
#     are TOOL-AGNOSTIC (EPC today, SCCM tomorrow, any tool)
#   - No cron, no emails from SSH functions — logs only, EPC controls timing
#   - Proper EPC exit codes: 0=success, 100-124=specific failures
#   - Timeouts on every SSH call + global script timeout + loop detection
#   - Scripts must NOT block patching — non-zero exit → EPC can force-patch

set -euo pipefail
IFS=$'\n\t'

# ------------------------------------------------------------
# RUNTIME CONFIG — sourced from orchestrator before any defaults
# Agent writes /tmp/oop-runtime-${JOB_ID}.conf before execution.
# Variables set here take precedence over the defaults below.
# ------------------------------------------------------------
if [[ -n "${OOP_RUNTIME_CONF:-}" && -f "${OOP_RUNTIME_CONF}" ]]; then
    # shellcheck source=/dev/null
    source "${OOP_RUNTIME_CONF}"
elif [[ -n "${JOB_ID:-}" && -f "/tmp/oop-runtime-${JOB_ID}.conf" ]]; then
    # shellcheck source=/dev/null
    source "/tmp/oop-runtime-${JOB_ID}.conf"
fi

# ------------------------------------------------------------
# CONFIGURATION (defaults – overridden by runtime conf above)
# Runtime conf is sourced before this block, so use ${VAR:-default}
# so that any value injected by the orchestrator is preserved.
# ------------------------------------------------------------
ORACLE_USER="${ORACLE_USER:-oracle}"
GRID_USER="${GRID_USER:-oracle}"
OINSTALL="${OINSTALL:-oinstall}"
OLD_GI_OSOPER_GROUP="${OLD_GI_OSOPER_GROUP:-}"

MAIL_TO="${MAIL_TO:-ps.devops@4cgroup.co.za}"
MAIL_FROM="${MAIL_FROM:-oop-orchestrator@4cgroup.co.za}"

# Oracle homes — injected by orchestrator runtime config (OLD from agent discovery,
# NEW auto-derived from gi_home_base/db_home_base + patch version).
# For manual CLI use, set these in your environment before calling the script.
OLD_GI_HOME="${OLD_GI_HOME:-}"
NEW_GI_HOME="${NEW_GI_HOME:-}"
OLD_DB_HOME="${OLD_DB_HOME:-}"
NEW_DB_HOME="${NEW_DB_HOME:-}"

# Precheck-only homes — derived from NEW homes so they're always in sync
PRECHECK_GI_HOME="${NEW_GI_HOME:+${NEW_GI_HOME}-precheck}"
PRECHECK_DB_HOME="${NEW_DB_HOME:+${NEW_DB_HOME}-precheck}"

# Patch software ZIPs — injected by orchestrator runtime config
GI_BASE_ZIP="${GI_BASE_ZIP:-}"
DB_BASE_ZIP="${DB_BASE_ZIP:-}"

# ----------------------------
# PATCH DISCOVERY
# Always auto — stage_software writes to known locations derived from STAGE_PATH
# so the script always knows where to find RU, OPatch, and OJVM.
# ----------------------------
AUTO_DISCOVER_PATCHES=true

# Search roots — injected via PATCH_SEARCH_ROOTS_ENV (colon-separated) from
# the orchestrator, which derives it from the VM's preferred_staging_mount.
# Falls back to well-known defaults so manual CLI use still works.
if [[ -n "${PATCH_SEARCH_ROOTS_ENV:-}" ]]; then
    IFS=':' read -ra PATCH_SEARCH_ROOTS <<< "$PATCH_SEARCH_ROOTS_ENV"
else
    PATCH_SEARCH_ROOTS=( /grid/software /app/software /app/software/db_software/patches /staging/software )
fi

# OPatch ZIP pattern — internal constant, no need to expose in UI
OPATCH_ZIP_PATTERN='p688088*_190000_Linux-x86-64.zip'

# ----------------------------
# OJVM — opt-in per run, off by default.
# Turned on by the "Apply OJVM" checkbox in the Run Job modal, which injects
# APPLY_OJVM=true into the runtime config. OJVM paths derive from STAGE_PATH
# so they follow wherever stage_software staged the zip.
# ----------------------------
APPLY_OJVM_ON_DB_INSTALL="${APPLY_OJVM:-false}"
APPLY_OJVM_DURING_DB_INSTALL="${APPLY_OJVM:-false}"
# OJVM zip dir: stage_software puts it at <STAGE_PATH>/db_software/ojvm
# Fall back to the traditional hardcoded path if STAGE_PATH is not set.
OJVM_ZIP_DIR="${OJVM_ZIP_DIR:-${STAGE_PATH:+${STAGE_PATH}/db_software/ojvm}}"
OJVM_ZIP_DIR="${OJVM_ZIP_DIR:-/app/software/db_software/ojvm}"
OJVM_ZIP_PATTERN='p*_190000_Linux-x86-64.zip'
OJVM_ONEOFF_DIR="${OJVM_ONEOFF_DIR:-${OJVM_ZIP_DIR}/ojvm_extracted}"
OJVM_PATCH_DIR="${OJVM_PATCH_DIR:-$OJVM_ONEOFF_DIR}"

# ----------------------------
# SOFTWARE STAGING
# Drop ALL downloaded ZIPs into this single directory.
# stage_software will identify, move, and extract them automatically.
# ----------------------------
STAGING_DROP_DIR="${STAGE_PATH:-/home/oracle/staging}"

# Leave empty — auto-discovery fills these in at boot
OPATCH_ZIP_DIR=""
OPATCH_ZIP=""
RU_DIR=""
RU_README=""

EMBED_RSP=true
GI_RSP=/home/oracle/grid-demo-setup.rsp
DB_RSP=${DB_RSP:-/home/oracle/db-install.rsp}
DB_AUTOCFG=/home/oracle/autoupgrade.cfg

# ------------------------------------------------------------
# AUTO-DETECT OS IDENTITY (oracle user, groups)
# Runs after the runtime conf is sourced so homes are available.
# Only fills in variables that are still at their defaults —
# explicit overrides from the runtime conf / env are preserved.
# ------------------------------------------------------------
_autodetect_os_identity() {
    # ORACLE_USER — owner of the oracle binary in any known DB home
    if [[ "${ORACLE_USER:-oracle}" == "oracle" ]]; then
        local _oh
        for _oh in "${OLD_DB_HOME:-}" "${NEW_DB_HOME:-}"; do
            [[ -z "$_oh" ]] && continue
            if [[ -f "$_oh/bin/oracle" ]]; then
                local _u
                _u=$(stat -c '%U' "$_oh/bin/oracle" 2>/dev/null || true)
                if [[ -n "$_u" && "$_u" != "root" ]]; then
                    ORACLE_USER="$_u"
                    break
                fi
            fi
        done
    fi

    # GRID_USER — owner of crsctl in any known GI home (may differ from ORACLE_USER)
    if [[ "${GRID_USER:-oracle}" == "oracle" ]]; then
        local _gh
        for _gh in "${OLD_GI_HOME:-}" "${NEW_GI_HOME:-}"; do
            [[ -z "$_gh" ]] && continue
            if [[ -f "$_gh/bin/crsctl" ]]; then
                local _g
                _g=$(stat -c '%U' "$_gh/bin/crsctl" 2>/dev/null || true)
                if [[ -n "$_g" && "$_g" != "root" ]]; then
                    GRID_USER="$_g"
                    break
                fi
            fi
        done
    fi

    # OINSTALL — primary group of the oracle OS user
    if [[ "${OINSTALL:-oinstall}" == "oinstall" ]]; then
        local _grp
        _grp=$(id -gn "$ORACLE_USER" 2>/dev/null || true)
        [[ -n "$_grp" ]] && OINSTALL="$_grp"
    fi

    # OLD_GI_OSOPER_GROUP — from GI home config.c (already handled by get_old_gi_osoper_group)
    # Populate early here so callers don't need to call the function themselves
    if [[ -z "${OLD_GI_OSOPER_GROUP:-}" && -n "${OLD_GI_HOME:-}" ]]; then
        local _cfg="${OLD_GI_HOME}/rdbms/lib/config.c"
        if [[ -f "$_cfg" ]]; then
            local _osoper
            _osoper=$(awk '/#define[[:space:]]+SS_OPER_GRP/ {gsub(/"/, "", $3); print $3; exit}' "$_cfg" 2>/dev/null || true)
            [[ -n "$_osoper" ]] && OLD_GI_OSOPER_GROUP="$_osoper"
        fi
        # Fallback: first 'asm*' group of the grid user
        if [[ -z "$OLD_GI_OSOPER_GROUP" ]]; then
            OLD_GI_OSOPER_GROUP=$(id -Gn "${GRID_USER:-oracle}" 2>/dev/null \
                | tr ' ' '\n' | grep -E '^asm' | head -1 || true)
        fi
    fi
}
_autodetect_os_identity

# ----------------------------
# Logging (DEFINE ONLY here)
# Do NOT mkdir/chown here - do it via ensure_phase_log_dirs()
# ----------------------------
LOG_DIR=/home/oracle/oop_logs
GI_LOG_DIR="${LOG_DIR}/gi"
DB_LOG_DIR="${LOG_DIR}/db"
CLUSTER_LOG_DIR="${LOG_DIR}/cluster"
GI_UPGRADE_LOG_DIR="${LOG_DIR}/gi_upgrade"
DB_UPGRADE_LOG_DIR="${LOG_DIR}/db_upgrade"

# GI precheck marker + GI state snapshots live under GI logs
PRECHECK_MARKER="${GI_LOG_DIR}/gi_precheck.ok"

current_phase_log_dir() {
    case "${LOG_FILE:-}" in
        "${CLUSTER_LOG_DIR}"/*)    printf '%s' "$CLUSTER_LOG_DIR" ;;
        "${GI_LOG_DIR}"/*)         printf '%s' "$GI_LOG_DIR" ;;
        "${DB_LOG_DIR}"/*)         printf '%s' "$DB_LOG_DIR" ;;
        "${GI_UPGRADE_LOG_DIR}"/*) printf '%s' "$GI_UPGRADE_LOG_DIR" ;;
        "${DB_UPGRADE_LOG_DIR}"/*) printf '%s' "$DB_UPGRADE_LOG_DIR" ;;
        *)                         printf '%s' "$LOG_DIR" ;;
    esac
}

# Cluster / SCAN — injected by orchestrator from agent discovery.
# Fallback: query CRS directly at runtime if not supplied.
GI_SCAN_NAME="${GI_SCAN_NAME:-}"
GI_SCAN_PORT="${GI_SCAN_PORT:-1521}"
GI_CLUSTER_NAME="${GI_CLUSTER_NAME:-}"
GI_CLUSTER_NODES="${GI_CLUSTER_NODES:-}"
DB_CLUSTER_NODES="${DB_CLUSTER_NODES:-${GI_CLUSTER_NODES:-}}"

# Auto-discover scan/cluster info from CRS when not injected
_autodetect_cluster_identity() {
    local _srvctl=""
    for _h in "${OLD_GI_HOME:-}" "${NEW_GI_HOME:-}"; do
        [[ -n "$_h" && -x "$_h/bin/srvctl" ]] && _srvctl="$_h/bin/srvctl" && break
    done

    if [[ -z "${GI_SCAN_NAME:-}" && -n "$_srvctl" ]]; then
        GI_SCAN_NAME=$("$_srvctl" config scan 2>/dev/null | awk -F': *' '/SCAN name/{print $2; exit}' || true)
    fi
    if [[ -z "${GI_CLUSTER_NAME:-}" && -n "$_srvctl" ]]; then
        GI_CLUSTER_NAME=$("$_srvctl" config cluster 2>/dev/null | awk -F': *' '/Cluster name/{print $2; exit}' || true)
        # Fallback: olsnodes -c
        [[ -z "$GI_CLUSTER_NAME" && -x "${OLD_GI_HOME:-x}/bin/olsnodes" ]] && \
            GI_CLUSTER_NAME=$("${OLD_GI_HOME}/bin/olsnodes" -c 2>/dev/null || true)
    fi
    if [[ -z "${GI_CLUSTER_NODES:-}" && -n "$_srvctl" ]]; then
        GI_CLUSTER_NODES=$(command -v olsnodes >/dev/null 2>&1 && olsnodes 2>/dev/null | paste -sd ',' - || true)
        [[ -z "$GI_CLUSTER_NODES" && -x "${OLD_GI_HOME:-x}/bin/olsnodes" ]] && \
            GI_CLUSTER_NODES=$("${OLD_GI_HOME}/bin/olsnodes" 2>/dev/null | paste -sd ',' - || true)
    fi
    # DB cluster nodes default to same as GI nodes
    [[ -z "${DB_CLUSTER_NODES:-}" ]] && DB_CLUSTER_NODES="${GI_CLUSTER_NODES:-}"
}
_autodetect_cluster_identity

DRYRUN=false
REPORT_BODY=""
LOG_FILE=/dev/null
SCRIPT_PATH=$(readlink -f "$0")
HOSTNAME=$(hostname -s)
IP=$(hostname -I | awk '{print $1}')
HOST="${HOSTNAME} (${IP})"
SRVCTL_BIN=""
GI_CLUSTER_MODE="UNKNOWN"
GI_MGMTDB_SID=""
ORATAB_FILE="/etc/oratab"
GI_ORATAB_SNAPSHOT="${GI_LOG_DIR}/gi_oratab_entry.txt"
GI_MGMTDB_SID_FILE="${GI_LOG_DIR}/gi_mgmtdb_sid.txt"
DB_LAST_ROLE=""
DB_LAST_MODE=""
CONFIG_MODE="AUTO"
GI_UPGRADE_STOPPED_DBS=()
DB_NAME_TO_SID_MAP=""

STATE_FILE="${LOG_DIR}/cluster_state_$(date +%F_%H%M%S).txt"
CLUSTER_STOPPED_DBS_FILE="${LOG_DIR}/cluster_stopped_dbs.list"

# ============================================================
# GI & DB UPGRADE CONFIG (19c -> 23/26ai)
# NOTE: define log dirs only; do NOT mkdir here
# ============================================================
GI_UPGRADE_OLD_HOME="$OLD_GI_HOME"
GI_UPGRADE_NEW_HOME=/grid/oracle/product/23ai-demo
GI_UPGRADE_BASE_ZIP=/home/oracle/upgrades/23ai_gi_soft/V1054596-01.zip
GI_UPGRADE_RSP=/home/oracle/23ai-grid.rsp
GI_UPGRADE_RSP_UPGRADE=/home/oracle/23ai-upgrade-grid.rsp

DB_UPGRADE_OLD_HOME="$OLD_DB_HOME"
DB_UPGRADE_NEW_HOME=/app/oracle/product/23ai
DB_UPGRADE_BASE_ZIP=/app/software/db_23ai.zip
DB_UPGRADE_CONFIG="${DB_UPGRADE_LOG_DIR}/orcl19cfg"
DB_UPGRADE_JAR="$DB_UPGRADE_NEW_HOME/rdbms/admin/autoupgrade.jar"

GI_USE_SUDO_FOR_ROOT=true

# ============================================================
# SSH REMOTE ORCHESTRATION CONFIG (opt-in)
# ============================================================
# Set ENABLE_SSH_REMOTE_ORCHESTRATION=true on the DB VM to
# orchestrate remote APP VM shutdown/startup via SSH.
# Default: false — script works on any platform without SSH.
#
# EPC ERROR CODES:
#   0   = Success
#   100 = APP hosts file not found/empty
#   101 = SSH connection test failed
#   102 = Remote shutdown failed/timed out
#   103 = Remote startup failed/timed out
#   110 = Local DB shutdown failed
#   111 = Local DB startup failed
#   124 = Global script timeout
# ============================================================
ENABLE_SSH_REMOTE_ORCHESTRATION="${ENABLE_SSH_REMOTE_ORCHESTRATION:-false}"

if [[ "$ENABLE_SSH_REMOTE_ORCHESTRATION" == true ]]; then
    APP_HOSTS_FILE="${APP_HOSTS_FILE:-/etc/patching/app_vm_hosts.txt}"
    SSH_USER="${SSH_USER:-patchuser}"
    SSH_KEY="${SSH_KEY:-/home/patchuser/.ssh/id_ed25519_patch}"
    SSH_OPTS="-i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=no"

    SSH_BATCH_SIZE="${SSH_BATCH_SIZE:-3}"

    # Tool-agnostic paths — /etc/patching/ works with EPC, SCCM, or any tool
    REMOTE_SHUTDOWN_SCRIPT="${REMOTE_SHUTDOWN_SCRIPT:-/etc/patching/shutdown_services.sh}"
    REMOTE_STARTUP_SCRIPT="${REMOTE_STARTUP_SCRIPT:-/etc/patching/startup_services.sh}"

    SSH_CMD_TIMEOUT="${SSH_CMD_TIMEOUT:-1800}"
    MAX_REMOTE_EXECUTION_TIME="${MAX_REMOTE_EXECUTION_TIME:-3600}"
    REMOTE_START_TIME=$(date +%s)
fi

# ------------------------------------------------------------
# LOG DIRECTORY BOOTSTRAP (safe even before log() works)
# ------------------------------------------------------------
resolve_primary_group_for_user() {
    local u="${1:-oracle}"
    id -gn "$u" 2>/dev/null || echo ""
}

resolve_oracle_group() {
    local grp="${OINSTALL:-oinstall}"
    local u="${ORACLE_USER:-oracle}"

    if getent group "$grp" >/dev/null 2>&1; then
        echo "$grp"
        return 0
    fi

    resolve_primary_group_for_user "$u"
}

ensure_dir_writable_for_oracle() {
    local d="$1"
    local u="${ORACLE_USER:-oracle}"
    local g
    g="$(resolve_oracle_group)"

    if ! mkdir -p "$d" 2>/dev/null; then
        if command -v sudo >/dev/null 2>&1; then
            if ! sudo -n mkdir -p "$d"; then
                echo "FATAL: cannot create '$d' (no permission) and sudo -n failed." >&2
                echo "       Fix perms or grant NOPASSWD sudo for $u." >&2
                exit 1
            fi
        else
            echo "FATAL: cannot create '$d' (no permission) and sudo not available." >&2
            exit 1
        fi
    fi

    if [[ -n "$g" ]]; then
        chown "${u}:${g}" "$d" 2>/dev/null || sudo -n chown "${u}:${g}" "$d" 2>/dev/null || true
    else
        chown "${u}" "$d" 2>/dev/null || sudo -n chown "${u}" "$d" 2>/dev/null || true
    fi

    chmod 775 "$d" 2>/dev/null || sudo -n chmod 775 "$d" 2>/dev/null || true
}

ensure_phase_log_dirs() {
    local which="${1:-all}"

    : "${LOG_DIR:=/home/oracle/oop_logs}"
    : "${GI_LOG_DIR:=${LOG_DIR}/gi}"
    : "${DB_LOG_DIR:=${LOG_DIR}/db}"
    : "${CLUSTER_LOG_DIR:=${LOG_DIR}/cluster}"
    : "${GI_UPGRADE_LOG_DIR:=${LOG_DIR}/gi_upgrade}"
    : "${DB_UPGRADE_LOG_DIR:=${LOG_DIR}/db_upgrade}"

    ensure_dir_writable_for_oracle "$LOG_DIR"

    case "$which" in
        gi)         ensure_dir_writable_for_oracle "$GI_LOG_DIR" ;;
        db)         ensure_dir_writable_for_oracle "$DB_LOG_DIR" ;;
        cluster)    ensure_dir_writable_for_oracle "$CLUSTER_LOG_DIR" ;;
        gi_upgrade) ensure_dir_writable_for_oracle "$GI_UPGRADE_LOG_DIR" ;;
        db_upgrade) ensure_dir_writable_for_oracle "$DB_UPGRADE_LOG_DIR" ;;
        all)
            ensure_dir_writable_for_oracle "$GI_LOG_DIR"
            ensure_dir_writable_for_oracle "$DB_LOG_DIR"
            ensure_dir_writable_for_oracle "$CLUSTER_LOG_DIR"
            ensure_dir_writable_for_oracle "$GI_UPGRADE_LOG_DIR"
            ensure_dir_writable_for_oracle "$DB_UPGRADE_LOG_DIR"
            ;;
    esac
}

# Bootstrap all log dirs at startup (safe, does not depend on log())
ensure_phase_log_dirs all

# ============================================================
# Minimal log stub — used by init_srvctl before the full log() is defined
# The real log() function defined later in the script will override this
# ============================================================
if ! declare -f log >/dev/null 2>&1; then
    log() {
        local msg="$1"
        local ts
        ts=$(date '+%F %T')
        echo "${ts} - ${msg}"
        [[ -n "${LOG_FILE:-}" && "${LOG_FILE:-}" != "/dev/null" ]] && \
            echo "${ts} - ${msg}" >> "$LOG_FILE" 2>/dev/null || true
    }
fi

# ============================================================
# SRVCTL INIT + DB-ONLY MODE — MUST run before autoconfigure_patches
# ============================================================
init_srvctl() {
    SRVCTL_BIN=""

    # Try GI homes first — these are the real srvctl
    if [[ -x "$OLD_GI_HOME/bin/srvctl" ]]; then
        SRVCTL_BIN="$OLD_GI_HOME/bin/srvctl"
    elif [[ -x "$NEW_GI_HOME/bin/srvctl" ]]; then
        SRVCTL_BIN="$NEW_GI_HOME/bin/srvctl"
    fi

    # Verify srvctl actually works (DB homes ship srvctl too but it can't manage CRS)
    if [[ -n "$SRVCTL_BIN" ]]; then
        if "$SRVCTL_BIN" config database >/dev/null 2>&1; then
            DB_ONLY_MODE=false
            return 0
        else
            log "WARN: srvctl found at $SRVCTL_BIN but 'srvctl config database' failed."
            SRVCTL_BIN=""
        fi
    fi

    # Check for running ASM — definitive proof of GI
    if ps -eo args 2>/dev/null | grep -q '[p]mon_+ASM'; then
        DB_ONLY_MODE=false
        log "WARN: ASM detected but srvctl not functional."
        return 0
    fi

    # Check for running CRS/HAS
    local has_gi=false
    if [[ -d "$OLD_GI_HOME" && -x "$OLD_GI_HOME/bin/crsctl" ]]; then
        if "$OLD_GI_HOME/bin/crsctl" check crs >/dev/null 2>&1 || \
           "$OLD_GI_HOME/bin/crsctl" check has >/dev/null 2>&1; then
            has_gi=true
        fi
    fi

    if [[ "$has_gi" == true ]]; then
        DB_ONLY_MODE=false
        log "WARN: CRS/HAS detected but srvctl not available."
    else
        DB_ONLY_MODE=true
        log "INFO: DB_ONLY_MODE auto-detected (no GI, no ASM, no functional srvctl)."
    fi
}

# Run init_srvctl FIRST so DB_ONLY_MODE is set before anything else
init_srvctl

# ------------------------------------------------------------
# PATCHSET VERSION DETECTION
# DB-only mode: always uses NEW_DB_HOME
# GI+DB mode:   uses the higher of NEW_GI_HOME / NEW_DB_HOME
# ------------------------------------------------------------
derive_patchset_version() {
    local version=""

    if [[ "${DB_ONLY_MODE:-false}" == true ]]; then
        if [[ "$NEW_DB_HOME" =~ (19\.[0-9]+) ]]; then
            version="${BASH_REMATCH[1]}"
        fi
        printf '%s' "$version"
        return
    fi

    if [[ -n "${1:-}" && "$1" =~ (19\.[0-9]+) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return
    fi

    local gi_ver="" db_ver=""

    if [[ "$NEW_GI_HOME" =~ (19\.[0-9]+) ]]; then
        gi_ver="${BASH_REMATCH[1]}"
    fi
    if [[ "$NEW_DB_HOME" =~ (19\.[0-9]+) ]]; then
        db_ver="${BASH_REMATCH[1]}"
    fi

    if [[ -n "$gi_ver" && -n "$db_ver" ]]; then
        local gi_minor db_minor
        gi_minor="${gi_ver#19.}"
        db_minor="${db_ver#19.}"
        if (( db_minor > gi_minor )); then
            version="$db_ver"
        else
            version="$gi_ver"
        fi
    elif [[ -n "$db_ver" ]]; then
        version="$db_ver"
    elif [[ -n "$gi_ver" ]]; then
        version="$gi_ver"
    fi

    # Fallback: peek at the RU ZIP in the staging drop dir to detect version without
    # needing NEW_GI_HOME/NEW_DB_HOME pre-set. Uses unzip -p to read only README.html.
    if [[ -z "$version" ]]; then
        local _drop="${STAGING_DROP_DIR:-/home/oracle/staging}"
        for _zip in "${_drop}"/p[0-9]*_190000_*.zip "${_drop}"/p[0-9]*_190000_LINUX.zip; do
            [[ -f "$_zip" ]] || continue
            local _sz; _sz=$(stat -c%s "$_zip" 2>/dev/null || echo 0)
            (( _sz > 500000000 )) || continue  # skip OPatch/OJVM zips (<500 MB)
            local _ver
            _ver=$(unzip -p "$_zip" "*/README.html" 2>/dev/null \
                   | grep -oE '19\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
            if [[ "$_ver" =~ (19\.[0-9]+) ]]; then
                version="${BASH_REMATCH[1]}"
                # Back-derive NEW homes so the rest of the script has correct paths
                if [[ -z "${NEW_GI_HOME:-}" && -n "${OLD_GI_HOME:-}" ]]; then
                    NEW_GI_HOME="${OLD_GI_HOME%/*}/$version"
                fi
                if [[ -z "${NEW_DB_HOME:-}" && -n "${OLD_DB_HOME:-}" ]]; then
                    NEW_DB_HOME="${OLD_DB_HOME%/*}/$version"
                fi
                break
            fi
        done
    fi

    printf '%s' "$version"
}

# ------------------------------------------------------------
# PATCH AUTO-DISCOVERY HELPERS (RU / OPatch / OJVM)
# ------------------------------------------------------------
_pick_latest_by_version() {
    local glob_pat="$1"
    shopt -s nullglob
    local items=( $glob_pat )
    shopt -u nullglob
    (( ${#items[@]} == 0 )) && return 1
    printf '%s\n' "${items[@]}" | sort -V | tail -n1
}

_pick_latest_numeric_subdir() {
    local parent="$1"
    [[ -d "$parent" ]] || return 1
    local d
    d=$(find "$parent" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
        | grep -E '^[0-9]+$' | sort -n | tail -n1 || true)
    [[ -n "$d" ]] && printf '%s' "${parent%/}/$d" || return 1
}

_discover_ru_dir() {
    local root patchset ru
    for root in "${PATCH_SEARCH_ROOTS[@]}"; do
        [[ -d "$root" ]] || continue
        # DB-only mode — skip /grid/ paths entirely
        if [[ "${DB_ONLY_MODE:-false}" == true && "$root" == /grid* ]]; then
            continue
        fi
        patchset="$(_pick_latest_by_version "${root%/}/p19.*")" || continue
        [[ -n "$patchset" ]] || continue
        ru="$(_pick_latest_numeric_subdir "$patchset")" || continue
        [[ -n "$ru" ]] && { printf '%s' "$ru"; return 0; }
    done
    return 1
}

_discover_ru_readme() {
    local ru_dir="$1"
    [[ -d "$ru_dir" ]] || return 1
    [[ -f "$ru_dir/README.html" ]] && { echo "$ru_dir/README.html"; return 0; }
    local readme
    readme=$(find "$ru_dir" -maxdepth 2 -type f -iname 'readme*.html' 2>/dev/null | sort | head -n1 || true)
    [[ -n "$readme" ]] && echo "$readme" || return 1
}

_discover_opatch_zip() {
    local dir="$1" pat="$2"
    [[ -d "$dir" ]] || return 1
    shopt -s nullglob
    local zips=( "$dir"/$pat )
    shopt -u nullglob
    (( ${#zips[@]} == 0 )) && return 1
    printf '%s\n' "${zips[@]}" | sort -V | tail -n1
}

autoconfigure_patches() {
    [[ "${AUTO_DISCOVER_PATCHES:-true}" == true ]] || return 0

    if [[ -z "${RU_DIR:-}" || ! -d "${RU_DIR:-}" ]]; then
        RU_DIR="$(_discover_ru_dir)" || true
    fi

    # FIX: If RU_DIR is still empty, try to find and auto-extract the RU ZIP
    if [[ -z "${RU_DIR:-}" || ! -d "${RU_DIR:-}" ]]; then
        local _root _ps
        for _root in "${PATCH_SEARCH_ROOTS[@]}"; do
            [[ -d "$_root" ]] || continue
            [[ "${DB_ONLY_MODE:-false}" == true && "$_root" == /grid* ]] && continue
            _ps="$(_pick_latest_by_version "${_root%/}/p19.*")" || continue
            if [[ -n "$_ps" && -d "$_ps" ]]; then
                # Look for an un-extracted RU ZIP (largest non-OPatch ZIP)
                shopt -s nullglob
                local _ru_candidates=()
                local _z
                for _z in "$_ps"/p[0-9]*_190000_Linux-x86-64.zip "$_ps"/p[0-9]*_190000_LINUX.zip; do
                    [[ -f "$_z" ]] || continue
                    local _bname
                    _bname=$(basename "$_z")
                    # Skip OPatch ZIPs
                    [[ "$_bname" == p688088* ]] && continue
                    _ru_candidates+=("$_z")
                done
                shopt -u nullglob

                if (( ${#_ru_candidates[@]} > 0 )); then
                    # Pick the largest as the RU
                    local _ru_zip
                    _ru_zip=$(for _c in "${_ru_candidates[@]}"; do stat -c '%s %n' "$_c" 2>/dev/null; done | sort -rn | head -n1 | awk '{print $2}')
                    if [[ -n "$_ru_zip" && -f "$_ru_zip" ]]; then
                        log "INFO: autoconfigure_patches: RU ZIP found but not extracted: $_ru_zip — extracting now..."
                        (cd "$_ps" && unzip -oq "$(basename "$_ru_zip")" 2>/dev/null) || true
                        # Re-try discovery
                        local _extracted
                        _extracted="$(_pick_latest_numeric_subdir "$_ps")" || true
                        if [[ -n "$_extracted" && -d "$_extracted" ]]; then
                            RU_DIR="$_extracted"
                            log "INFO: autoconfigure_patches: RU_DIR discovered after auto-extract: $RU_DIR"
                        else
                            log "WARN: autoconfigure_patches: Extracted $_ru_zip but no numeric subdir found in $_ps"
                        fi
                    fi
                fi
                # Whether or not RU extraction worked, set OPATCH_ZIP_DIR from this patchset dir
                if [[ -z "${OPATCH_ZIP_DIR:-}" || ! -d "${OPATCH_ZIP_DIR:-}" ]]; then
                    shopt -s nullglob
                    local _opatch_check=( "$_ps"/${OPATCH_ZIP_PATTERN} )
                    shopt -u nullglob
                    if (( ${#_opatch_check[@]} > 0 )); then
                        OPATCH_ZIP_DIR="$_ps"
                        log "INFO: autoconfigure_patches: OPATCH_ZIP_DIR discovered via fallback: $OPATCH_ZIP_DIR"
                    fi
                fi
                # If we found RU_DIR, stop searching
                [[ -n "${RU_DIR:-}" && -d "${RU_DIR:-}" ]] && break
            fi
        done
    fi

    if [[ -n "${RU_DIR:-}" && ( -z "${OPATCH_ZIP_DIR:-}" || ! -d "${OPATCH_ZIP_DIR:-}" ) ]]; then
        OPATCH_ZIP_DIR="$(dirname "$RU_DIR")"
    fi

    # FIX: Fallback for OPATCH_ZIP_DIR if still empty (RU_DIR was set but OPATCH_ZIP_DIR wasn't)
    if [[ -z "${OPATCH_ZIP_DIR:-}" || ! -d "${OPATCH_ZIP_DIR:-}" ]]; then
        local _root2 _ps2
        for _root2 in "${PATCH_SEARCH_ROOTS[@]}"; do
            [[ -d "$_root2" ]] || continue
            [[ "${DB_ONLY_MODE:-false}" == true && "$_root2" == /grid* ]] && continue
            _ps2="$(_pick_latest_by_version "${_root2%/}/p19.*")" || continue
            if [[ -n "$_ps2" && -d "$_ps2" ]]; then
                shopt -s nullglob
                local _oc=( "$_ps2"/${OPATCH_ZIP_PATTERN} )
                shopt -u nullglob
                if (( ${#_oc[@]} > 0 )); then
                    OPATCH_ZIP_DIR="$_ps2"
                    log "INFO: OPATCH_ZIP_DIR discovered via secondary fallback: $OPATCH_ZIP_DIR"
                    break
                fi
            fi
        done
    fi

    if [[ -n "${RU_DIR:-}" && ( -z "${RU_README:-}" || ! -f "${RU_README:-}" ) ]]; then
        RU_README="$(_discover_ru_readme "$RU_DIR")" || true
    fi

    if [[ -n "${OPATCH_ZIP_DIR:-}" && ( -z "${OPATCH_ZIP:-}" || ! -f "${OPATCH_ZIP:-}" ) ]]; then
        OPATCH_ZIP="$(_discover_opatch_zip "$OPATCH_ZIP_DIR" "${OPATCH_ZIP_PATTERN}")" || true
    fi

    if [[ -n "${OJVM_ZIP_DIR:-}" && -d "$OJVM_ZIP_DIR" ]]; then
        shopt -s nullglob
        local ojvm_zips=( "$OJVM_ZIP_DIR"/${OJVM_ZIP_PATTERN} )
        shopt -u nullglob
        if (( ${#ojvm_zips[@]} > 0 )); then
            local ojvm_zip
            ojvm_zip=$(printf '%s\n' "${ojvm_zips[@]}" | sort -V | tail -n1)
            if [[ -d "${OJVM_ONEOFF_DIR:-}" ]] && \
               find "${OJVM_ONEOFF_DIR}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -q .; then
                OJVM_PATCH_DIR="$OJVM_ONEOFF_DIR"
            else
                mkdir -p "${OJVM_ONEOFF_DIR}" 2>/dev/null || sudo -n mkdir -p "${OJVM_ONEOFF_DIR}" 2>/dev/null || true
                unzip -oq "$ojvm_zip" -d "${OJVM_ONEOFF_DIR}" 2>/dev/null || true
                OJVM_PATCH_DIR="$OJVM_ONEOFF_DIR"
            fi
        fi
    fi

    echo "PATCH AUTO-CONFIG:" >&2
    echo "  OPATCH_ZIP_DIR = ${OPATCH_ZIP_DIR:-<not found>}" >&2
    echo "  RU_DIR         = ${RU_DIR:-<not found>}" >&2
    echo "  RU_README      = ${RU_README:-<not found>}" >&2
    echo "  OPATCH_ZIP     = ${OPATCH_ZIP:-<not found>}" >&2
    echo "  OJVM_PATCH_DIR = ${OJVM_PATCH_DIR:-<not found>}" >&2

    if [[ -z "${RU_DIR:-}" || ! -d "${RU_DIR:-}" ]]; then
        echo "WARN: RU_DIR could not be discovered under: ${PATCH_SEARCH_ROOTS[*]}" >&2
        echo "      Run: $0 stage_software   to stage patches first." >&2
    fi
}

# autoconfigure_patches runs AFTER init_srvctl so DB_ONLY_MODE is set
autoconfigure_patches

# ------------------------------------------------------------
# OUI LOG ATTACHMENT HELPER
# ------------------------------------------------------------
attach_latest_oui_logs_since_marker() {
    local marker="$1"
    local label="${2:-OUI logs}"

    local attached=0
    local best_log=""

    # 1) Check central inventory for the single newest installer log
    local inv_root=""
    if [[ -f /etc/oraInst.loc ]]; then
        inv_root=$(awk -F= '/inventory_loc/ {gsub(/[[:space:]]/, "", $2); print $2}' /etc/oraInst.loc 2>/dev/null || true)
    fi

    if [[ -n "$inv_root" && -d "$inv_root/logs" ]]; then
        best_log=$(
            find "$inv_root/logs" -type f -newer "$marker" 2>/dev/null \
            \( -iname '*installactions*.log' -o -iname '*gridsetupactions*.log' \) \
            -printf '%T@ %p\n' | sort -nr | head -n1 | awk '{print $2}' || true
        )
    fi

    # 2) If nothing in central inventory, check cfgtoollogs/oui under the homes
    if [[ -z "$best_log" ]]; then
        local search_dirs=()
        [[ -n "${NEW_DB_HOME:-}" ]]         && search_dirs+=( "${NEW_DB_HOME}/cfgtoollogs/oui" )
        [[ -n "${NEW_GI_HOME:-}" ]]         && search_dirs+=( "${NEW_GI_HOME}/cfgtoollogs/oui" )
        [[ -n "${PRECHECK_DB_HOME:-}" ]]    && search_dirs+=( "${PRECHECK_DB_HOME}/cfgtoollogs/oui" )
        [[ -n "${PRECHECK_GI_HOME:-}" ]]    && search_dirs+=( "${PRECHECK_GI_HOME}/cfgtoollogs/oui" )
        [[ -n "${DB_UPGRADE_NEW_HOME:-}" ]] && search_dirs+=( "${DB_UPGRADE_NEW_HOME}/cfgtoollogs/oui" )
        [[ -n "${GI_UPGRADE_NEW_HOME:-}" ]] && search_dirs+=( "${GI_UPGRADE_NEW_HOME}/cfgtoollogs/oui" )

        local d
        for d in "${search_dirs[@]}"; do
            [[ -d "$d" ]] || continue
            best_log=$(
                find "$d" -type f -newer "$marker" 2>/dev/null \
                -iname '*installactions*.log' \
                -printf '%T@ %p\n' | sort -nr | head -n1 | awk '{print $2}' || true
            )
            [[ -n "$best_log" ]] && break
        done
    fi

    if [[ -n "$best_log" && -f "$best_log" && -s "$best_log" ]]; then
        add_attachment "$best_log"
        attached=1
        add_html_row "${label} (details)" "INFO" \
            "Attached OUI installer log: $(basename "$best_log")"
    else
        add_html_row "${label} (details)" "INFO" \
            "No relevant OUI installer logs found newer than marker."
    fi
}

# ------------------------------------------------------------
# ORACLE INVENTORY CHECK
# Returns 0 (true) if the given path is registered in the central Oracle inventory.
# Checks /etc/oraInst.loc → inventory_loc → ContentsXML/inventory.xml
# Also checks the home-local inventory.xml as a fallback.
# Never overwrite a home that Oracle has already registered — even if no processes run.
# ------------------------------------------------------------
is_home_in_inventory() {
    local target_home="$1"
    [[ -z "$target_home" ]] && return 1

    # Central inventory via /etc/oraInst.loc
    local inv_root=""
    if [[ -f /etc/oraInst.loc ]]; then
        inv_root=$(awk -F= '/inventory_loc/ {gsub(/[[:space:]]/, "", $2); print $2}' /etc/oraInst.loc 2>/dev/null || true)
    fi
    if [[ -n "$inv_root" && -f "$inv_root/ContentsXML/inventory.xml" ]]; then
        # Match LOC="<target_home>" in inventory.xml — handles trailing slash variants
        local norm_target
        norm_target="${target_home%/}"
        if grep -qE "LOC=\"${norm_target}/?\"" "$inv_root/ContentsXML/inventory.xml" 2>/dev/null; then
            return 0
        fi
    fi

    # Fallback: home-local inventory (present after install even without central inventory)
    if [[ -f "$target_home/inventory/ContentsXML/comps.xml" ]]; then
        return 0
    fi

    return 1
}

# ------------------------------------------------------------
# SOFTWARE STAGING VALIDATION
# FIX: Added DB_ONLY_MODE guards for GI checks
# ------------------------------------------------------------
validate_staged_software_html() {
    local which="${1:-all}"
    local has_failures=false

    # FIX: Skip GI Base ZIP check on DB-only VMs
    if [[ "$which" == "gi" || "$which" == "all" ]]; then
        if [[ "${DB_ONLY_MODE:-false}" == true ]]; then
            add_html_row "GI Base ZIP" "INFO" \
                "DB-only mode — GI base ZIP not required"
        elif [[ -n "${NEW_GI_HOME:-}" && -f "${NEW_GI_HOME}/gridSetup.sh" ]]; then
            add_html_row "GI Base (depot)" "PASS" \
                "$NEW_GI_HOME already extracted (depot mode) — no zip required"
        elif [[ -f "$GI_BASE_ZIP" ]]; then
            local gi_size
            gi_size=$(du -h "$GI_BASE_ZIP" 2>/dev/null | awk '{print $1}' || echo "unknown")
            add_html_row "GI Base ZIP" "PASS" "$GI_BASE_ZIP (${gi_size})"
        else
            add_html_row "GI Base ZIP" "FAIL" \
                "GI base ZIP missing: ${GI_BASE_ZIP:-<not discovered>} — drop the GI base ZIP into $STAGING_DROP_DIR and run stage_software"
            has_failures=true
        fi
    fi

    if [[ "$which" == "db" || "$which" == "all" ]]; then
        if [[ -n "${NEW_DB_HOME:-}" && -f "${NEW_DB_HOME}/runInstaller" ]]; then
            add_html_row "DB Base (depot)" "PASS" \
                "$NEW_DB_HOME already extracted (depot mode) — no zip required"
        elif [[ -f "$DB_BASE_ZIP" ]]; then
            local db_size
            db_size=$(du -h "$DB_BASE_ZIP" 2>/dev/null | awk '{print $1}' || echo "unknown")
            add_html_row "DB Base ZIP" "PASS" "$DB_BASE_ZIP (${db_size})"
        else
            add_html_row "DB Base ZIP" "FAIL" \
                "DB base ZIP missing: ${DB_BASE_ZIP:-<not discovered>} — drop the DB base ZIP into $STAGING_DROP_DIR and run stage_software"
            has_failures=true
        fi
    fi

    if [[ -d "${RU_DIR:-}" ]]; then
        local ru_patch_id
        ru_patch_id=$(basename "$RU_DIR")
        add_html_row "RU Directory" "PASS" "$RU_DIR (patch ID: ${ru_patch_id})"
    else
        add_html_row "RU Directory" "FAIL" \
            "RU directory missing: ${RU_DIR:-<not discovered>} — drop the RU ZIP into $STAGING_DROP_DIR and run stage_software"
        has_failures=true
    fi

    if [[ -f "${RU_README:-}" ]]; then
        add_html_row "RU README" "PASS" "$RU_README"
    else
        add_html_row "RU README" "WARN" \
            "RU README missing: ${RU_README:-<not set>} — OPatch version check may not work"
    fi

    if [[ -f "${OPATCH_ZIP:-}" ]]; then
        add_html_row "OPatch ZIP" "PASS" "$OPATCH_ZIP"
    else
        add_html_row "OPatch ZIP" "WARN" \
            "OPatch ZIP missing: ${OPATCH_ZIP:-<not discovered>} — drop the OPatch ZIP (p6880880_*.zip) into $STAGING_DROP_DIR and run stage_software"
    fi

    if [[ "$which" == "db" || "$which" == "all" ]]; then
        if [[ "${APPLY_OJVM_DURING_DB_INSTALL:-false}" == true ]]; then
            if [[ -d "${OJVM_ZIP_DIR:-}" ]]; then
                local ojvm_zip
                ojvm_zip=$(find "$OJVM_ZIP_DIR" -maxdepth 1 -name "${OJVM_ZIP_PATTERN}" -print -quit 2>/dev/null || true)
                if [[ -n "$ojvm_zip" ]]; then
                    add_html_row "OJVM ZIP" "PASS" "$ojvm_zip"
                else
                    add_html_row "OJVM ZIP" "WARN" \
                        "OJVM ZIP matching '${OJVM_ZIP_PATTERN}' not found in $OJVM_ZIP_DIR"
                fi
            else
                add_html_row "OJVM ZIP" "WARN" \
                    "OJVM_ZIP_DIR ($OJVM_ZIP_DIR) does not exist"
            fi
        else
            add_html_row "OJVM" "INFO" \
                "APPLY_OJVM_DURING_DB_INSTALL=false — OJVM validation skipped"
        fi
    fi

    # FIX: Skip NEW_GI_HOME check on DB-only VMs
    if [[ "$which" == "gi" || "$which" == "all" ]]; then
        if [[ "${DB_ONLY_MODE:-false}" == true ]]; then
            add_html_row "NEW_GI_HOME" "INFO" \
                "DB-only mode — GI home not required"
        elif [[ -d "$NEW_GI_HOME" ]]; then
            # Check whether CRS/HAS is actively running from NEW_GI_HOME.
            # If crsctl from that home reports CRS/HAS online, installing into it would
            # corrupt a live GI stack (ASM, listeners, voting disks, OCR) — hard FAIL.
            local _gi_crs_live=false
            if [[ -x "$NEW_GI_HOME/bin/crsctl" ]]; then
                if "$NEW_GI_HOME/bin/crsctl" check crs >/dev/null 2>&1 || \
                   "$NEW_GI_HOME/bin/crsctl" check has >/dev/null 2>&1; then
                    _gi_crs_live=true
                fi
            fi
            # Also block if NEW_GI_HOME == OLD_GI_HOME (admin misconfigured target home)
            if [[ "$_gi_crs_live" == true || "$NEW_GI_HOME" == "$OLD_GI_HOME" ]]; then
                local _gi_block_reason
                if [[ "$NEW_GI_HOME" == "$OLD_GI_HOME" ]]; then
                    _gi_block_reason="NEW_GI_HOME is the same as OLD_GI_HOME ($OLD_GI_HOME) — the target install home must differ from the currently active GI home."
                else
                    _gi_block_reason="CRS/HAS is currently RUNNING from $NEW_GI_HOME (crsctl check crs/has returned success). Installing into a live GI home will corrupt ASM, voting disks, and OCR."
                fi
                add_html_row "NEW_GI_HOME" "FAIL" \
                    "HARD BLOCK: $_gi_block_reason Run gi_rollback first to return CRS to $OLD_GI_HOME, then retry gi_install."
                has_failures=true
            else
                # Directory exists but CRS not running from it — check if it's in Oracle inventory
                if is_home_in_inventory "$NEW_GI_HOME"; then
                    add_html_row "NEW_GI_HOME" "FAIL" \
                        "HARD BLOCK: $NEW_GI_HOME is already registered in the Oracle central inventory. \
This home was previously installed — installing into it again will corrupt the existing Oracle stack. \
Choose a different target home path (e.g. add a suffix like .new) or remove it from the inventory first."
                    has_failures=true
                else
                    add_html_row "NEW_GI_HOME" "WARN" \
                        "$NEW_GI_HOME exists on disk but is NOT in the Oracle inventory and CRS is not running from it. \
This may be a leftover partial install. gi_install will overwrite it."
                fi
            fi
        else
            add_html_row "NEW_GI_HOME" "PASS" \
                "$NEW_GI_HOME does not exist yet and is not in Oracle inventory — safe to install"
        fi
    fi
    if [[ "$which" == "db" || "$which" == "all" ]]; then
        if [[ -d "$NEW_DB_HOME" ]]; then
            # Check if any database instance is actively running from NEW_DB_HOME.
            local _running_from_new=()
            local _pmon_sid
            while IFS= read -r _pmon_sid; do
                local _phome
                _phome=$(get_home_from_pmon_sid "$_pmon_sid" 2>/dev/null || true)
                [[ "$_phome" == "$NEW_DB_HOME" ]] && _running_from_new+=("$_pmon_sid")
            done < <(ps -eo args 2>/dev/null | grep -oP '(?<=ora_pmon_)[A-Za-z0-9_]+' | grep -v '^\+' | grep -v 'MGMTDB' | sort -u)
            if (( ${#_running_from_new[@]} > 0 )); then
                add_html_row "NEW_DB_HOME" "FAIL" \
                    "HARD BLOCK: Database instance(s) ${_running_from_new[*]} are currently RUNNING from $NEW_DB_HOME. \
Installing into a live Oracle home will corrupt it. Run db_rollback first, then re-run db_install."
                has_failures=true
            elif is_home_in_inventory "$NEW_DB_HOME"; then
                add_html_row "NEW_DB_HOME" "FAIL" \
                    "HARD BLOCK: $NEW_DB_HOME is already registered in the Oracle central inventory. \
This home was previously installed — installing into it again will corrupt the existing Oracle database installation. \
Choose a different target home path or remove it from the inventory first."
                has_failures=true
            else
                add_html_row "NEW_DB_HOME" "WARN" \
                    "$NEW_DB_HOME exists on disk but is NOT in the Oracle inventory and no running instance detected. \
This may be a leftover partial install. db_install will overwrite it."
            fi
        else
            add_html_row "NEW_DB_HOME" "PASS" \
                "$NEW_DB_HOME does not exist yet and is not in Oracle inventory — safe to install"
        fi
    fi

    if [[ "$has_failures" == true ]]; then
        return 1
    fi
    return 0
}

# ------------------------------------------------------------
# SOFTWARE STAGING: Flat drop directory -> auto-identify -> auto-sort
# ------------------------------------------------------------

ensure_staging_dirs() {
    log "Ensuring all target directories exist..."

    local dirs=()

    if [[ "${DB_ONLY_MODE:-false}" != true ]]; then
        dirs+=( "$(dirname "$GI_BASE_ZIP")" )
    fi

    dirs+=( "$(dirname "$DB_BASE_ZIP")" )
    dirs+=( "${OJVM_ZIP_DIR:-}" )
    dirs+=( "${STAGING_DROP_DIR:-/home/oracle/staging}" )

    for d in "${dirs[@]}"; do
        [[ -z "$d" ]] && continue
        if [[ ! -d "$d" ]]; then
            run_cmd "sudo mkdir -p \"$d\""
            run_cmd "sudo chown -R ${ORACLE_USER}:${OINSTALL} \"$d\""
            run_cmd "sudo chmod 775 \"$d\""
            local fixdir
            fixdir=$(dirname "$d")
            while [[ "$fixdir" != "/" && "$fixdir" != "." ]]; do
                if [[ -d "$fixdir" ]]; then
                    local owner
                    owner=$(stat -c '%U' "$fixdir" 2>/dev/null || echo "")
                    if [[ "$owner" == "root" ]]; then
                        run_cmd "sudo chown ${ORACLE_USER}:${OINSTALL} \"$fixdir\""
                        run_cmd "sudo chmod 775 \"$fixdir\""
                    else
                        break
                    fi
                fi
                fixdir=$(dirname "$fixdir")
            done
            add_html_row "Created directory" "PASS" "$d"
        fi
    done
}

distribute_staged_files() {
    local drop="${STAGING_DROP_DIR:-/home/oracle/staging}"

    if [[ ! -d "$drop" ]]; then
        add_html_row "Staging drop dir" "WARN" \
            "$drop does not exist. Creating it — drop your ZIPs there and re-run."
        run_cmd "sudo mkdir -p \"$drop\""
        run_cmd "sudo chown ${ORACLE_USER}:${OINSTALL} \"$drop\""
        return 1
    fi

    # FIX: Call derive_patchset_version without args — it checks DB_ONLY_MODE internally
    local target_version
    target_version=$(derive_patchset_version)

    if [[ -z "$target_version" ]]; then
        add_html_row "Patchset detection" "FAIL" \
            "Could not derive patchset version from NEW_GI_HOME ($NEW_GI_HOME) or NEW_DB_HOME ($NEW_DB_HOME). Expected path containing 19.XX"
        return 1
    fi

    if [[ "${DB_ONLY_MODE:-false}" == true ]]; then
        add_html_row "Patchset detection" "INFO" \
            "Target patchset: <b>p${target_version}</b> (from NEW_DB_HOME=$NEW_DB_HOME) [DB-only mode]"
    else
        add_html_row "Patchset detection" "INFO" \
            "Target patchset: <b>p${target_version}</b> (from NEW_GI_HOME=$NEW_GI_HOME / NEW_DB_HOME=$NEW_DB_HOME)"
    fi

    local patchset_dir
    if [[ "${DB_ONLY_MODE:-false}" == true ]]; then
        patchset_dir="$(dirname "$DB_BASE_ZIP")/patches/p${target_version}"
    else
        local search_root="${PATCH_SEARCH_ROOTS[0]:-/grid/software}"
        patchset_dir="${search_root}/p${target_version}"
    fi

    add_html_row "Patchset directory" "INFO" "$patchset_dir"

    _ensure_dir() {
        local d="$1"
        [[ -d "$d" ]] && return 0
        run_cmd "sudo mkdir -p \"$d\""
        run_cmd "sudo chown -R ${ORACLE_USER}:${OINSTALL} \"$d\""
        run_cmd "sudo chmod 775 \"$d\""
        local fixdir
        fixdir=$(dirname "$d")
        while [[ "$fixdir" != "/" && "$fixdir" != "." ]]; do
            if [[ -d "$fixdir" ]]; then
                local owner
                owner=$(stat -c '%U' "$fixdir" 2>/dev/null || echo "")
                if [[ "$owner" == "root" ]]; then
                    run_cmd "sudo chown ${ORACLE_USER}:${OINSTALL} \"$fixdir\""
                    run_cmd "sudo chmod 775 \"$fixdir\""
                else
                    break
                fi
            fi
            fixdir=$(dirname "$fixdir")
        done
    }

    # Copy src→dest only if missing or size differs; fail hard if copy fails
    _stage_copy() {
        local label="$1" src="$2" dest="$3"
        local src_size dest_size
        src_size=$(stat -c '%s' "$src" 2>/dev/null || echo "")
        if [[ -f "$dest" ]]; then
            dest_size=$(stat -c '%s' "$dest" 2>/dev/null || echo "")
            if [[ "$src_size" == "$dest_size" && -n "$src_size" ]]; then
                add_html_row "$label" "INFO" \
                    "Already staged at $dest (size matches — skipping)"
                return 0
            else
                add_html_row "$label" "INFO" \
                    "Size mismatch (src=${src_size}B dest=${dest_size}B) — recopying"
                rm -f "$dest"
            fi
        fi
        if ! cp "$src" "$dest" 2>/tmp/_stage_err; then
            local err; err=$(cat /tmp/_stage_err 2>/dev/null)
            add_html_row "$label" "FAIL" \
                "Copy failed: $src → $dest — ${err:-unknown error}"
            return 1
        fi
        add_html_row "$label" "PASS" \
            "Staged $(basename "$src") → $dest ($(du -h "$dest" 2>/dev/null | awk '{print $1}'))"
    }

    # GI BASE MEDIA — skip on DB-only VMs
    if [[ "${DB_ONLY_MODE:-false}" != true ]]; then
        shopt -s nullglob
        local gi_bases=( "$drop"/V982068*.zip )
        shopt -u nullglob
        if (( ${#gi_bases[@]} > 0 )); then
            local gi_src="${gi_bases[0]}"
            local gi_dest_dir
            gi_dest_dir=$(dirname "$GI_BASE_ZIP")
            _ensure_dir "$gi_dest_dir"

            _stage_copy "GI Base ZIP" "$gi_src" "$GI_BASE_ZIP" || return 1
        fi
    else
        add_html_row "GI Base ZIP" "INFO" \
            "DB-only mode — GI base ZIP not required"
    fi

    # DB BASE MEDIA
    shopt -s nullglob
    local db_bases=( "$drop"/V982063*.zip )
    shopt -u nullglob
    if (( ${#db_bases[@]} > 0 )); then
        local db_src="${db_bases[0]}"
        local db_dest_dir
        db_dest_dir=$(dirname "$DB_BASE_ZIP")
        _ensure_dir "$db_dest_dir"

        _stage_copy "DB Base ZIP" "$db_src" "$DB_BASE_ZIP" || return 1
    fi

    # FIX: OPatch — matches both p688088_ (6 digits) and p6880880_ (7 digits)
    local opatch_src=""
    shopt -s nullglob
    local opatch_zips=( "$drop"/p688088*_*_Linux-x86-64.zip "$drop"/p688088*_*_LINUX.zip )
    shopt -u nullglob

    if (( ${#opatch_zips[@]} > 0 )); then
        opatch_src="${opatch_zips[0]}"

        _ensure_dir "$patchset_dir"
        add_html_row "Created patchset dir" "PASS" "$patchset_dir"

        local opatch_dest="${patchset_dir}/$(basename "$opatch_src")"
        _stage_copy "OPatch ZIP" "$opatch_src" "$opatch_dest" || return 1
    fi

    # Remaining p*_190000_*.zip — largest=RU, smaller=OJVM
    shopt -s nullglob
    local remaining_patches=( "$drop"/p[0-9]*_190000_Linux-x86-64.zip "$drop"/p[0-9]*_190000_LINUX.zip )
    shopt -u nullglob

    local candidate_patches=()
    for z in "${remaining_patches[@]}"; do
        [[ -f "$z" ]] || continue
        local bname
        bname=$(basename "$z")
        # FIX: Skip OPatch — match both p688088_ and p6880880_
        [[ "$bname" == p688088* ]] && continue
        candidate_patches+=("$z")
    done

    if (( ${#candidate_patches[@]} > 0 )); then
        local sorted_by_size
        sorted_by_size=$(for z in "${candidate_patches[@]}"; do
            stat -c '%s %n' "$z" 2>/dev/null
        done | sort -rn)

    local ru_src="" ojvm_src=""
    local line_num=0
    local largest_size=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local fsize fpath
        fsize=$(echo "$line" | awk '{print $1}')
        fpath=$(echo "$line" | awk '{print $2}')
        line_num=$((line_num + 1))

        if (( line_num == 1 )); then
            ru_src="$fpath"
            largest_size="$fsize"
            add_html_row "Patch detection" "INFO" \
                "$(basename "$fpath") ($(du -h "$fpath" | awk '{print $1}')) → <b>RU patch</b> (largest)"
        else
            # Only treat as OJVM if less than 50% the size of the RU
            local half_size=$(( largest_size / 2 ))
            if (( fsize < half_size )); then
                ojvm_src="$fpath"
                add_html_row "Patch detection" "INFO" \
                    "$(basename "$fpath") ($(du -h "$fpath" | awk '{print $1}')) → <b>OJVM one-off</b> (significantly smaller than RU)"
            else
                add_html_row "Patch detection" "INFO" \
                    "$(basename "$fpath") ($(du -h "$fpath" | awk '{print $1}')) → <b>Skipped</b> (similar size to RU — not OJVM)"
            fi
        fi
    done <<< "$sorted_by_size"

        # Copy RU patch
        if [[ -n "$ru_src" ]]; then
            _ensure_dir "$patchset_dir"

            local ru_dest="${patchset_dir}/$(basename "$ru_src")"
            _stage_copy "RU patch ZIP" "$ru_src" "$ru_dest" || return 1

            local already_extracted=false
            local extracted_dir
            extracted_dir=$(find "$patchset_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
                | grep -E '^[0-9]+$' | sort -n | tail -n1 || true)

            if [[ -n "$extracted_dir" && -f "${patchset_dir}/${extracted_dir}/README.html" ]]; then
                already_extracted=true
                add_html_row "RU extraction" "INFO" \
                    "Already extracted at ${patchset_dir}/${extracted_dir}/ — skipping"
            fi

            if [[ "$already_extracted" != true ]]; then
                log "Extracting RU patch in $patchset_dir..."
                run_cmd "cd \"$patchset_dir\" && unzip -oq \"$(basename "$ru_dest")\""

                extracted_dir=$(find "$patchset_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
                    | grep -E '^[0-9]+$' | sort -n | tail -n1 || true)

                if [[ -n "$extracted_dir" ]]; then
                    add_html_row "RU extraction" "PASS" \
                        "Extracted → ${patchset_dir}/${extracted_dir}/ (patch ID: ${extracted_dir})"

                    # Detect RU version from README inside the extracted patch dir.
                    # README.html contains e.g. "Database Release Update 19.29.0.0.250415"
                    local ru_readme="${patchset_dir}/${extracted_dir}/README.html"
                    local detected_ru_ver=""
                    if [[ -f "$ru_readme" ]]; then
                        detected_ru_ver=$(grep -oE '19\.[0-9]+\.[0-9]+\.[0-9]+' "$ru_readme" 2>/dev/null | head -1 || true)
                    fi
                    # Fall back to the patchset_dir name (already contains version like 19.29)
                    if [[ -z "$detected_ru_ver" && "$patchset_dir" =~ (19\.[0-9]+) ]]; then
                        detected_ru_ver="${BASH_REMATCH[1]}"
                    fi

                    if [[ -n "$detected_ru_ver" ]]; then
                        # Trim to major.minor (19.29.0.0 → 19.29)
                        local ru_short
                        ru_short=$(echo "$detected_ru_ver" | grep -oE '^19\.[0-9]+')
                        local gi_base db_base new_gi="" new_db=""
                        gi_base=$(dirname "${OLD_GI_HOME:-/grid/oracle/product/x}")
                        db_base=$(dirname "${OLD_DB_HOME:-/app/oracle/product/x}")
                        [[ -n "$OLD_GI_HOME" ]] && new_gi="${gi_base}/${ru_short}"
                        [[ -n "$OLD_DB_HOME" ]] && new_db="${db_base}/${ru_short}"

                        add_html_row "RU version detected" "INFO" \
                            "<b>${detected_ru_ver}</b> — will derive NEW_GI_HOME=<code>${new_gi}</code> NEW_DB_HOME=<code>${new_db}</code>"
                        log "INFO: Detected RU version: $detected_ru_ver → patch_target=$ru_short"

                        # Emit discovery so orchestrator updates vm.patch_target automatically
                        echo "[DISCOVERY_JSON] {\"type\":\"staged_software\",\"ru_version\":\"${ru_short}\",\"ru_full_version\":\"${detected_ru_ver}\",\"new_gi_home\":\"${new_gi}\",\"new_db_home\":\"${new_db}\",\"patch_id\":\"${extracted_dir}\"}"
                    fi
                else
                    add_html_row "RU extraction" "WARN" \
                        "Unzip completed but no numbered directory found in $patchset_dir"
                fi
            fi
        fi

        # Copy OJVM
        if [[ -n "$ojvm_src" ]]; then
            local ojvm_dest_dir="${OJVM_ZIP_DIR:-/app/software/db_software/ojvm}"
            _ensure_dir "$ojvm_dest_dir"

            local ojvm_dest="${ojvm_dest_dir}/$(basename "$ojvm_src")"
            if [[ -f "$ojvm_dest" ]]; then
                add_html_row "OJVM ZIP" "INFO" \
                    "Already exists at $ojvm_dest — skipping copy"
            else
                run_cmd "cp \"$ojvm_src\" \"$ojvm_dest\""
                add_html_row "OJVM ZIP" "PASS" \
                    "Copied $(basename "$ojvm_src") → $ojvm_dest"
            fi

            local ojvm_extract_dir="${OJVM_ONEOFF_DIR:-${ojvm_dest_dir}/ojvm_extracted}"
            if [[ -d "$ojvm_extract_dir" ]] && \
               find "$ojvm_extract_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -q .; then
                add_html_row "OJVM extraction" "INFO" \
                    "Already extracted in $ojvm_extract_dir — skipping"
            else
                run_cmd "mkdir -p \"$ojvm_extract_dir\""
                run_cmd "unzip -oq \"$ojvm_dest\" -d \"$ojvm_extract_dir\""
                add_html_row "OJVM extraction" "PASS" \
                    "Extracted $(basename "$ojvm_dest") → $ojvm_extract_dir"
            fi
            OJVM_PATCH_DIR="$ojvm_extract_dir"
        fi
    fi

    # FIX: Clear stale values before re-running discovery
    RU_DIR=""
    RU_README=""
    OPATCH_ZIP_DIR=""
    OPATCH_ZIP=""

    log "Re-running patch auto-discovery after staging..."
    autoconfigure_patches

    return 0
}

stage_software() {
    reset_report
    reset_html_report
    ensure_phase_log_dirs all

    LOG_FILE="${LOG_DIR}/stage_software_$(date +%F_%H%M%S).log"
    add_attachment "$LOG_FILE"

    # ── Dry-run banner ────────────────────────────────────────────────────────
    if [[ "${DRYRUN:-false}" == true ]]; then
        log "INFO: =========================================="
        log "INFO:  DRY-RUN MODE — no files will be moved"
        log "INFO:  or extracted. Review the plan below."
        log "INFO: =========================================="
        add_html_row "DRY-RUN MODE" "WARN" \
            "<b style='color:#856404;font-size:13px'>This is a dry-run — no files will be moved, directories created, or software extracted. All steps are simulated.</b>"
    fi

    log "INFO: =========================================="
    log "INFO:  SOFTWARE STAGING"
    log "INFO: =========================================="

    local drop="${STAGING_DROP_DIR:-/home/oracle/staging}"

    # Detect the version from the staged RU ZIP FIRST — this is the authoritative
    # source for what version is being staged, overriding whatever homes were derived.
    local _ru_detected=""
    for _zip in "${drop}"/p[0-9]*_190000_*.zip "${drop}"/p[0-9]*_190000_LINUX.zip; do
        [[ -f "$_zip" ]] || continue
        local _sz; _sz=$(stat -c%s "$_zip" 2>/dev/null || echo 0)
        (( _sz > 500000000 )) || continue   # skip OPatch/OJVM (<500 MB)
        local _ver
        _ver=$(unzip -p "$_zip" "*/README.html" 2>/dev/null \
               | grep -oE '19\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
        if [[ "$_ver" =~ (19\.[0-9]+) ]]; then
            _ru_detected="${BASH_REMATCH[1]}"
            if [[ -n "${OLD_GI_HOME:-}" ]]; then
                NEW_GI_HOME="${OLD_GI_HOME%/*}/$_ru_detected"
            fi
            if [[ -n "${OLD_DB_HOME:-}" ]]; then
                NEW_DB_HOME="${OLD_DB_HOME%/*}/$_ru_detected"
            fi
            break
        fi
    done

    local target_version
    target_version=$(derive_patchset_version)

    # ── Environment summary ───────────────────────────────────────────────────
    add_html_row "Staging drop directory" "INFO" "<code>$drop</code>"
    log "INFO: Staging drop directory : $drop"

    if [[ "${DB_ONLY_MODE:-false}" == true ]]; then
        local pv_detail="p${target_version:-UNKNOWN} — DB-only mode (NEW_DB_HOME=$NEW_DB_HOME)"
    else
        local pv_detail="p${target_version:-UNKNOWN} (NEW_GI_HOME=$NEW_GI_HOME / NEW_DB_HOME=$NEW_DB_HOME)"
    fi
    add_html_row "Target patchset" "INFO" "$pv_detail"
    log "INFO: Target patchset        : $pv_detail"

    local instr_patchset_dir
    if [[ "${DB_ONLY_MODE:-false}" == true ]]; then
        instr_patchset_dir="$(dirname "$DB_BASE_ZIP")/patches/p${target_version}"
    else
        instr_patchset_dir="${PATCH_SEARCH_ROOTS[0]:-/grid/software}/p${target_version}"
    fi

    # ── Show drop directory contents ──────────────────────────────────────────
    log "INFO: ------------------------------------------"
    log "INFO: Scanning drop directory: $drop"
    if [[ -d "$drop" ]]; then
        shopt -s nullglob
        local all_files=( "$drop"/*.zip )
        shopt -u nullglob
        if (( ${#all_files[@]} > 0 )); then
            local file_html=""
            file_html+="<table style='border-collapse:collapse;font-size:12px;width:100%'>"
            file_html+="<thead><tr style='background:#1a3a2a;color:#aee8c0'>"
            file_html+="<th style='padding:5px 10px;text-align:left'>File</th>"
            file_html+="<th style='padding:5px 10px;text-align:left'>Size</th>"
            file_html+="<th style='padding:5px 10px;text-align:left'>Detected as</th>"
            file_html+="<th style='padding:5px 10px;text-align:left'>Will be moved to</th></tr></thead><tbody>"
            local ridx=0
            for f in "${all_files[@]}"; do
                local sz fname detected dest
                fname=$(basename "$f")
                sz=$(du -h "$f" 2>/dev/null | awk '{print $1}' || echo "?")
                if [[ "$fname" == V982068* ]]; then
                    detected="GI Base Media"
                    dest="$(dirname "$GI_BASE_ZIP")/"
                elif [[ "$fname" == V982063* ]]; then
                    detected="DB Base Media"
                    dest="$(dirname "$DB_BASE_ZIP")/"
                elif [[ "$fname" == p688088* ]]; then
                    detected="OPatch Utility"
                    dest="${instr_patchset_dir}/"
                else
                    detected="RU / OJVM patch (sorted by size)"
                    dest="${instr_patchset_dir}/ (auto-extracted)"
                fi
                log "INFO:   Found: $fname ($sz) → $detected"
                local bg; (( ridx % 2 == 0 )) && bg="#0f2d1e" || bg="#122a1c"
                file_html+="<tr style='background:${bg}'>"
                file_html+="<td style='padding:4px 10px;color:#e0ffe0;font-family:monospace'>${fname}</td>"
                file_html+="<td style='padding:4px 10px;color:#aaa'>${sz}</td>"
                file_html+="<td style='padding:4px 10px;color:#6fcf97;font-weight:bold'>${detected}</td>"
                file_html+="<td style='padding:4px 10px;color:#aaa;font-family:monospace'>${dest}</td>"
                file_html+="</tr>"
                (( ridx++ )) || true
            done
            file_html+="</tbody></table>"
            add_html_row "Files in drop directory (${#all_files[@]} found)" "INFO" "$file_html"
        else
            log "WARN: No ZIP files found in $drop"
            add_html_row "Files in drop directory" "WARN" \
                "No ZIP files found in <code>$drop</code> — transfer patch ZIPs to this directory first, then re-run Stage Software."
        fi
    else
        log "WARN: Drop directory does not exist: $drop (will be created)"
        add_html_row "Drop directory" "WARN" "<code>$drop</code> does not exist — will be created in Step 1"
    fi

    # ── Step 1: Create target directories ────────────────────────────────────
    log "INFO: ------------------------------------------"
    log "INFO: Step 1/3 — Create target directories"
    add_html_row "Step 1/3 — Create directories" "INFO" \
        "Creating staging tree under <code>${PATCH_SEARCH_ROOTS[0]:-/grid/software}</code>"
    ensure_staging_dirs
    log "INFO: Step 1/3 complete — directories ready"
    add_html_row "Step 1/3 — Directories" "PASS" "All target directories exist or were created"

    # ── Step 2: Identify, distribute, and extract ─────────────────────────────
    log "INFO: ------------------------------------------"
    log "INFO: Step 2/3 — Distribute and extract software"

    # Depot mode: agent extracted the base software tar directly into the Oracle home
    # (NEW_GI_HOME / NEW_DB_HOME) via X-Depot-Install-Path. Detect by presence of
    # the installer binary in the target home — not in dirname(BASE_ZIP).
    local _depot_gi=false _depot_db=false
    [[ "${DB_ONLY_MODE:-false}" != true && -n "${NEW_GI_HOME:-}" && -f "${NEW_GI_HOME}/gridSetup.sh" ]] && _depot_gi=true
    [[ -n "${NEW_DB_HOME:-}" && -f "${NEW_DB_HOME}/runInstaller" ]] && _depot_db=true

    if [[ "$_depot_gi" == true || "$_depot_db" == true ]]; then
        local _depot_note=""
        [[ "$_depot_gi" == true ]] && _depot_note+="GI base "
        [[ "$_depot_db" == true ]] && _depot_note+="DB base "
        add_html_row "Step 2/3 — Depot mode" "PASS" \
            "Pre-extracted content detected (${_depot_note}from orchestrator depot) — skipping zip distribution and extraction."
        log "INFO: Depot mode — pre-extracted content found (${_depot_note}), skipping distribute_staged_files"
    else
        add_html_row "Step 2/3 — Distribute &amp; extract" "INFO" \
            "Moving ZIPs from drop directory to target locations and extracting patches${DRYRUN:+ <b>(DRY-RUN — simulated only)</b>}"
        distribute_staged_files
        log "INFO: Step 2/3 complete — distribution done"
        add_html_row "Step 2/3 — Distribution" "PASS" \
            "File distribution and extraction complete${DRYRUN:+ <b>(dry-run — no actual changes made)</b>}"
    fi

    # ── Step 3: Validate ──────────────────────────────────────────────────────
    log "INFO: ------------------------------------------"
    log "INFO: Step 3/3 — Validate staged software"
    add_html_row "Step 3/3 — Validation" "INFO" "Checking all required files are present in target locations"
    local staging_ok=true
    validate_staged_software_html all || staging_ok=false

    if [[ "$staging_ok" != true ]]; then
        log "WARN: Software staging validation FAILED — missing files"
        local instructions=""
        instructions+="<b>Transfer the missing patch ZIPs to the drop directory:</b><br/>"
        instructions+="<code>$drop</code><br/><br/>"
        instructions+="<table style='border-collapse:collapse;font-size:11px;width:100%'>"
        instructions+="<thead><tr style='background:#343a40;color:#fff'>"
        instructions+="<th style='padding:4px 8px'>Filename pattern</th>"
        instructions+="<th style='padding:4px 8px'>Detected as</th>"
        instructions+="<th style='padding:4px 8px'>Target location</th></tr></thead><tbody>"
        if [[ "${DB_ONLY_MODE:-false}" != true ]]; then
            instructions+="<tr><td style='padding:4px 8px'><code>V982068*.zip</code></td><td>GI Base Media</td><td><code>$(dirname "$GI_BASE_ZIP")/</code></td></tr>"
        fi
        instructions+="<tr><td style='padding:4px 8px'><code>V982063*.zip</code></td><td>DB Base Media</td><td><code>$(dirname "$DB_BASE_ZIP")/</code></td></tr>"
        instructions+="<tr><td style='padding:4px 8px'><code>p688088*_190000_*.zip</code></td><td>OPatch Utility</td><td><code>${instr_patchset_dir}/</code></td></tr>"
        instructions+="<tr><td style='padding:4px 8px'><code>p*_190000_*.zip</code> (largest)</td><td>RU Patch</td><td><code>${instr_patchset_dir}/</code> (auto-extracted)</td></tr>"
        instructions+="<tr><td style='padding:4px 8px'><code>p*_190000_*.zip</code> (smaller)</td><td>OJVM patch</td><td><code>${OJVM_ZIP_DIR}/</code> (auto-extracted)</td></tr>"
        instructions+="</tbody></table><br/>"
        instructions+="<b>Then re-run Stage Software from the UI.</b>"
        add_html_row "How to complete staging" "WARN" "$instructions"
        add_html_row "Step 3/3 — Validation" "FAIL" "Staging INCOMPLETE — see missing files above"
        add_html_row "Overall result" "FAIL" "Re-run Stage Software after transferring missing files"
        send_html_report "Software Staging INCOMPLETE - $HOST" "Software Staging Report"
        log "WARN: Software staging incomplete."
        return 1
    fi

    log "INFO: Step 3/3 complete — all software validated"
    add_html_row "Step 3/3 — Validation" "PASS" "All required software present and validated in target locations"

    # ── Cleanup drop directory (skipped in dry-run) ───────────────────────────
    log "INFO: ------------------------------------------"
    if [[ -d "$drop" ]]; then
        shopt -s nullglob
        local staged_zips=( "$drop"/*.zip )
        shopt -u nullglob
        if (( ${#staged_zips[@]} > 0 )); then
            local cleanup_list=""
            for f in "${staged_zips[@]}"; do
                log "INFO: Removing staging drop file: $(basename "$f")"
                cleanup_list+="$(basename "$f")<br/>"
                run_cmd "rm -f \"$f\""
            done
            if [[ "${DRYRUN:-false}" == true ]]; then
                add_html_row "Drop directory cleanup" "INFO" \
                    "<b>(DRY-RUN)</b> Would remove ${#staged_zips[@]} ZIP(s) from <code>$drop</code>:<br/>${cleanup_list}"
            else
                add_html_row "Drop directory cleanup" "PASS" \
                    "Removed ${#staged_zips[@]} ZIP(s) from <code>$drop</code> (all verified in target locations):<br/>${cleanup_list}"
            fi
        else
            log "INFO: Drop directory already empty — no cleanup needed"
        fi
    fi

    # ── Final summary ─────────────────────────────────────────────────────────
    if [[ "${DRYRUN:-false}" == true ]]; then
        add_html_row "Overall result (DRY-RUN)" "WARN" \
            "<b>Dry-run complete — no files were moved.</b> Review the plan above and re-run without dry-run to apply."
        log "INFO: Dry-run complete. Re-run without dry-run to apply staging."
        send_html_report "Software Staging DRY-RUN - $HOST" "Software Staging Report (Dry-run)"
    else
        add_html_row "Overall result" "PASS" \
            "All required software staged and validated. Ready to proceed with <b>gi_precheck</b> / <b>db_precheck</b>."
        log "INFO: All software staged successfully. Ready for gi_precheck / db_precheck."
        send_html_report "Software Staging OK - $HOST" "Software Staging Report"
    fi
    return 0
}
# ------------------------------------------------------------
# LOGGING / HELPERS
# ------------------------------------------------------------
log() {
    local msg="$(date '+%F %T') - $*"
    { echo "$msg" >> "$LOG_FILE"; } 2>/dev/null
    { echo "$msg"; } 2>/dev/null
}

# Stream a spool file's content through log() so it appears in the UI log viewer.
# The file is still kept and emailed as an attachment — this just makes the same
# content visible in the orchestrator without SSH access.
log_file_content() {
    local file="$1"
    local label="${2:-$(basename "$file")}"
    [[ -f "$file" ]] || return 0
    log "=== ${label} (start) ==="
    while IFS= read -r _fc_line; do
        log "  ${_fc_line}"
    done < "$file"
    log "=== ${label} (end) ==="
}

run_cmd() {
    if [[ "$DRYRUN" == true ]]; then
        log "[DRYRUN] $*"
        return 0
    fi
    log "[RUN] $*"
    eval "$@"
}

run_cmd_allow_fail() {
    if [[ "$DRYRUN" == true ]]; then
        log "[DRYRUN-ALLOW-FAIL] $*"
        return 0
    fi
    log "[RUN-ALLOW-FAIL] $*"
    set +e
    eval "$@"
    local rc=$?
    set -e
    if (( rc != 0 )); then
        log "WARN: Command failed (rc=$rc) but continuing: $*"
    fi
    return 0
}

safe_rm_rf() {
    local target="$1"
    local use_sudo="${2:-false}"
    if [[ -z "$target" || "$target" == "/" ]]; then
        log "WARN: safe_rm_rf called with unsafe target '$target' – skipping rm -rf."
        return 1
    fi
    if [[ "$target" != *"-precheck" ]]; then
        log "WARN: safe_rm_rf refused to delete non-precheck path: $target"
        add_html_row "Safety check" "WARN" \
            "Refused to rm -rf non-precheck path: $target"
        return 1
    fi
    if [[ "$use_sudo" == true ]]; then
        run_cmd "sudo rm -rf \"$target\""
    else
        run_cmd "rm -rf \"$target\""
    fi
}

log_to_state_file() {
    local kv="$1"
    echo "$kv" >> "$STATE_FILE"
}

add_report_step() {
    local label="$1"
    local status="$2"
    local msg="${3:-}"
    REPORT_BODY+=$(printf "[%s] %s %s\n" "$status" "$label" "$msg")
}

reset_report() {
    REPORT_BODY=""
    PHASE_STATUS="PASS"
}

die() {
    add_report_step "FATAL" "FAIL" "$1"
    log "FATAL: $1"
    exit 1
}

send_report() {
    local subject="$1"
    local now
    now=$(date '+%F %T')
    if [[ "$DRYRUN" == true ]]; then
        log "[DRYRUN] Would send email: $subject"
        log "[DRYRUN] Report body:"
        printf '%s\n' "$REPORT_BODY" | tee -a "$LOG_FILE"
        return 0
    fi
    local body
    body="Host: ${HOST}\nTime: ${now}\n\n${REPORT_BODY}"
    if ! printf '%b\n' "$body" | mailx -r "$MAIL_FROM" -s "$subject" "$MAIL_TO"; then
        log "WARN: failed to send mail for subject '$subject' from '$MAIL_FROM' to '$MAIL_TO'"
    else
        log "Report emailed to $MAIL_TO: $subject"
    fi
}

# Resolve an effective group for Oracle-owned files if OINSTALL doesn't exist
resolve_oracle_group() {
    local user="${ORACLE_USER:-oracle}"
    local grp="${OINSTALL:-oinstall}"

    # If the configured OINSTALL group exists, use it
    if getent group "$grp" >/dev/null 2>&1; then
        echo "$grp"
        return 0
    fi

    # Fall back to oracle's primary group if oracle exists
    if id "$user" >/dev/null 2>&1; then
        id -gn "$user"
        return 0
    fi

    # Last resort: return empty and let chown use default group
    echo ""
    return 0
}

ensure_at_service() {
    if ! systemctl is-active atd &>/dev/null; then
        run_cmd "systemctl enable --now atd || true"
    fi
}

# ------------------------------------------------------------
# HTML REPORT HELPERS + ATTACHMENTS
# ------------------------------------------------------------
HTML_ROWS=""
ATTACH_FILES=()

reset_html_report() {
    HTML_ROWS=""
    ATTACH_FILES=()
}

add_html_row() {
    local label="$1"
    local status="$2"
    local details="$3"
    local color="#ffffff"
    case "$status" in
        PASS) color="#d4edda" ;;
        FAIL) color="#f8d7da" ;;
        WARN) color="#fff3cd" ;;
        INFO) color="#d1ecf1" ;;
    esac
    # Escalate phase status: FAIL > WARN > PASS/INFO
    case "$status" in
        FAIL) PHASE_STATUS="FAIL" ;;
        WARN) [[ "$PHASE_STATUS" != "FAIL" ]] && PHASE_STATUS="WARN" ;;
    esac
    HTML_ROWS+="
    <tr style=\"background-color:${color};\">
        <td style=\"padding:4px 8px;\"><b>${label}</b></td>
        <td style=\"padding:4px 8px; white-space:nowrap;\">${status}</td>
        <td style=\"padding:4px 8px;\">${details}</td>
    </tr>"
    log "[CHECK] ${label}|${status}|${details}"
}

# Like add_html_row but does NOT emit a [CHECK] log line — used inside notification-only
# sub-reports (e.g. send_db_open_notification) so those rows do not appear in the main
# phase report tab in the UI.
_html_row() {
    local label="$1"
    local status="$2"
    local details="$3"
    local color="#ffffff"
    case "$status" in
        PASS) color="#d4edda" ;;
        FAIL) color="#f8d7da" ;;
        WARN) color="#fff3cd" ;;
        INFO) color="#d1ecf1" ;;
    esac
    HTML_ROWS+="
    <tr style=\"background-color:${color};\">
        <td style=\"padding:4px 8px;\"><b>${label}</b></td>
        <td style=\"padding:4px 8px; white-space:nowrap;\">${status}</td>
        <td style=\"padding:4px 8px;\">${details}</td>
    </tr>"
}

# Insert a full-width section header row to visually separate blocks in the report
add_html_section() {
    local title="$1"
    HTML_ROWS+="
    <tr>
        <td colspan=\"3\" style=\"padding:6px 10px; background-color:#003366; color:#ffffff; font-weight:bold; font-size:13px; letter-spacing:0.5px;\">&#9654; ${title}</td>
    </tr>"
    log "[SECTION] ${title}"
}

add_attachment() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    ATTACH_FILES+=("$f")
}

# Wrap a plain-text log file in a minimal HTML page and attach the .html version.
# For crs_stat logs, uses format_crs_stat_html() for a proper table; all others get <pre>.
add_html_attachment() {
    local src="$1"
    local title="${2:-$(basename "$src")}"
    [[ -f "$src" ]] || return 0
    local html_file="${src%.log}.html"
    local is_crs_stat=false
    [[ "$(basename "$src")" == crs_stat_* ]] && is_crs_stat=true
    {
        printf '<!DOCTYPE html><html><head><meta charset="UTF-8"><title>%s</title>\n' "$title"
        printf '<style>body{font-family:Arial,sans-serif;font-size:12px;background:#0d1117;color:#e0e0e0;padding:16px;margin:0}'
        printf 'h3{color:#94a3b8;font-size:13px;margin:0 0 12px}'
        printf 'pre{white-space:pre-wrap;word-break:break-all;font-family:monospace;font-size:11px;'
        printf 'background:#1e293b;padding:12px;border-radius:4px;border:1px solid #334155}</style></head><body>\n'
        printf '<h3>%s &mdash; %s &mdash; %s</h3>\n' "$title" "$(hostname -s)" "$(date '+%F %T')"
        if $is_crs_stat; then
            format_crs_stat_html "$src"
        else
            printf '<pre>'
            escape_html < "$src"
            printf '</pre>'
        fi
        printf '\n</body></html>\n'
    } > "$html_file"
    ATTACH_FILES+=("$html_file")
}
send_html_report() {
    local subject="$1"
    local heading="$2"
    local now
    now=$(date '+%F %T')

    # Max size per attachment in bytes (2MB default)
    local MAX_ATTACH_BYTES="${MAX_ATTACH_BYTES:-2097152}"

    local html_body
    html_body="<html>
<head>
  <meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\" />
  <title>${subject}</title>
</head>
<body style=\"font-family: Arial, sans-serif; font-size: 12px;\">
  <h2 style=\"color:#003366;\">${heading}</h2>
  <p><b>Host:</b> ${HOST}<br/>
     <b>Time:</b> ${now}</p>
  <table border=\"1\" cellspacing=\"0\" cellpadding=\"0\" style=\"border-collapse:collapse; font-size:12px;\">
    <thead style=\"background-color:#343a40; color:#ffffff;\">
      <tr>
        <th style=\"padding:4px 8px;\">Check</th>
        <th style=\"padding:4px 8px;\">Status</th>
        <th style=\"padding:4px 8px;\">Details</th>
      </tr>
    </thead>
    <tbody>
      ${HTML_ROWS}
    </tbody>
  </table>
  <p style=\"margin-top:12px; color:#666666; font-size:11px;\">
    This report was generated by the Oracle GI + DB Out-of-Place Patch & Upgrade Orchestrator.
  </p>
</body>
</html>"

    local text_body
    text_body=$(printf '%s\n' "$html_body" | sed 's/<[^>]*>//g' | sed 's/[[:space:]]\+/ /g')

    if [[ "$DRYRUN" == true ]]; then
        log "[DRYRUN] Would send email: $subject"
        log "[DRYRUN] Body (HTML):"
        printf '%s\n' "$html_body" | tee -a "$LOG_FILE"
        if (( ${#ATTACH_FILES[@]} > 0 )); then
            log "[DRYRUN] Attachments:"
            printf '  %s\n' "${ATTACH_FILES[@]}" | tee -a "$LOG_FILE"
        fi
        return 0
    fi

    if command -v sendmail >/dev/null 2>&1; then
        local boundary="====OOP_ORCH_MULTIPART$$.$RANDOM===="
        {
            echo "From: $MAIL_FROM"
            echo "To: $MAIL_TO"
            echo "Subject: $subject"
            echo "MIME-Version: 1.0"
            if (( ${#ATTACH_FILES[@]} > 0 )); then
                echo "Content-Type: multipart/mixed; boundary=\"${boundary}\""
                echo
                echo "--${boundary}"
                echo "Content-Type: text/html; charset=UTF-8"
                echo "Content-Transfer-Encoding: 8bit"
                echo
                echo "$html_body"
                for f in "${ATTACH_FILES[@]}"; do
                    [[ -f "$f" ]] || continue
                    local fname fsize
                    fname=$(basename "$f")
                    fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
                    local ctype="text/plain"
                    [[ "$fname" == *.html ]] && ctype="text/html"
                    echo
                    echo "--${boundary}"
                    echo "Content-Type: ${ctype}; charset=UTF-8; name=\"${fname}\""
                    echo "Content-Transfer-Encoding: 8bit"
                    echo "Content-Disposition: attachment; filename=\"${fname}\""
                    echo
                    if (( fsize > MAX_ATTACH_BYTES )); then
                        echo "=== FILE TRUNCATED (original size: ${fsize} bytes, limit: ${MAX_ATTACH_BYTES} bytes) ==="
                        echo "=== Showing first and last portions. Full log on server: $f ==="
                        echo ""
                        head -c $(( MAX_ATTACH_BYTES / 2 )) "$f"
                        echo ""
                        echo ""
                        echo "=== ... TRUNCATED ... ==="
                        echo ""
                        tail -c $(( MAX_ATTACH_BYTES / 2 )) "$f"
                    else
                        cat "$f"
                    fi
                done
                echo
                echo "--${boundary}--"
            else
                echo "Content-Type: text/html; charset=UTF-8"
                echo "Content-Transfer-Encoding: 8bit"
                echo
                echo "$html_body"
            fi
        } | sendmail -t
        if (( ${#ATTACH_FILES[@]} > 0 )); then
            log "HTML report (with ${#ATTACH_FILES[@]} attachment(s)) emailed to $MAIL_TO: $subject"
        else
            log "HTML report emailed to $MAIL_TO: $subject"
        fi
        return 0
    fi

    if (( ${#ATTACH_FILES[@]} > 0 )); then
        local cmd=(mailx -r "$MAIL_FROM" -s "$subject")
        for f in "${ATTACH_FILES[@]}"; do
            [[ -f "$f" ]] && cmd+=( -a "$f" )
        done
        cmd+=( "$MAIL_TO" )
        printf '%b\n' "$text_body" | "${cmd[@]}"
    else
        printf '%b\n' "$text_body" | mailx -r "$MAIL_FROM" -s "$subject" "$MAIL_TO"
    fi

    # Emit full HTML to the log stream so the UI can store and display it
    # Strip all newlines from b64 — the fallback `base64` (BSD/old GNU) wraps at 76 chars,
    # which would split the log line and break the [HTML_REPORT] parser on the backend.
    local _b64
    _b64=$(printf '%s' "$html_body" | base64 -w0 2>/dev/null || printf '%s' "$html_body" | base64 2>/dev/null || true)
    _b64=$(printf '%s' "$_b64" | tr -d '\n\r')
    if [[ -n "$_b64" ]]; then
        log "[HTML_REPORT] ${subject}|${_b64}"
    fi
}

# Emit a file directly into the UI Reports tab as an [HTML_REPORT] log line.
# .html files are sent as-is; .log/.txt files are wrapped in a dark-themed <pre> block.
emit_file_as_html_report() {
    local file="$1"
    local subject="$2"
    [[ -f "$file" ]] || return 0
    local content
    if [[ "$file" == *.html ]]; then
        content=$(cat "$file")
    else
        local title
        title=$(basename "$file")
        local escaped
        escaped=$(cat "$file" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
        content="<!DOCTYPE html><html><head><meta charset=\"UTF-8\"><title>${title}</title>
<style>body{font-family:Arial,sans-serif;font-size:12px;background:#0d1117;color:#e0e0e0;padding:16px;margin:0}
h3{color:#94a3b8;font-size:13px;margin:0 0 12px}
pre{white-space:pre-wrap;word-break:break-all;font-family:monospace;font-size:11px;
background:#1e293b;padding:12px;border-radius:4px;border:1px solid #334155}</style></head>
<body><h3>${subject} &mdash; ${HOST} &mdash; $(date '+%F %T')</h3><pre>${escaped}</pre></body></html>"
    fi
    local _b64
    _b64=$(printf '%s' "$content" | base64 -w0 2>/dev/null || printf '%s' "$content" | base64 2>/dev/null || true)
    _b64=$(printf '%s' "$_b64" | tr -d '\n\r')
    [[ -n "$_b64" ]] && log "[HTML_REPORT] ${subject}|${_b64}"
}

send_phase_html_report() {
    local phase_name="$1"
    local subject="$2"
    local status="$3"
    local heading="${phase_name} Report (${status})"
    send_html_report "$subject" "$heading"
}

send_db_open_notification() {
    local phase="$1"
    local db="$2"
    local home="$3"
    local role="$4"
    local mode="$5"

    local saved_rows="$HTML_ROWS"
    local saved_attachments=( "${ATTACH_FILES[@]}" )

    HTML_ROWS=""
    ATTACH_FILES=()

    _html_row "Database" "INFO" "$db"
    _html_row "Role" "INFO" "$role"
    _html_row "Open mode" "INFO" "$mode"
    _html_row "Oracle home" "INFO" "$home"

    if [[ "$role" == "PRIMARY" ]]; then
        local pdbs pdb_html=""
        pdbs=$(list_open_pdbs "$db" "$home" || echo "")
        if [[ -n "$pdbs" ]]; then
            while IFS= read -r p; do
                [[ -z "$p" ]] && continue
                pdb_html+="  - ${p}<br/>"
            done <<< "$pdbs"
            _html_row "Open PDBs" "INFO" "$pdb_html"
        else
            _html_row "Open PDBs" "INFO" \
                "No open PDBs detected or instance is non-CDB / not accessible at time of notification."
        fi
    fi

    # Listener status — on GI systems the listener is owned by CRS; check via GI home.
    # On DB_ONLY_MODE the listener lives in the DB home passed as $home.
    local _lsnr_home="$home"
    if [[ "${DB_ONLY_MODE:-false}" != true && -n "${OLD_GI_HOME:-}" && -x "$OLD_GI_HOME/bin/lsnrctl" ]]; then
        _lsnr_home="$OLD_GI_HOME"
    fi
    if [[ -x "$_lsnr_home/bin/lsnrctl" ]]; then
        local _lsnr_out _lsnr_rc=0 _lsnr_wait=0
        # Services register a few seconds after the listener process starts.
        # Retry up to 30s so the notification reflects actual service state.
        while true; do
            _lsnr_out=$(sudo -u "${GRID_USER:-$ORACLE_USER}" bash -c "
                export ORACLE_HOME=\"$_lsnr_home\"
                export PATH=\"$_lsnr_home/bin:\$PATH\"
                \"$_lsnr_home/bin/lsnrctl\" status 2>&1
            " 2>/dev/null) || _lsnr_rc=$?
            if echo "$_lsnr_out" | grep -qi "status READY"; then
                break  # At least one service registered
            fi
            if (( _lsnr_wait >= 30 )); then
                break  # Give up waiting
            fi
            sleep 5
            (( _lsnr_wait += 5 ))
        done
        if echo "$_lsnr_out" | grep -qi "The command completed successfully"; then
            local _lsnr_svc
            _lsnr_svc=$(echo "$_lsnr_out" | grep -i "^Service" | grep -v "has 0" | head -5 | tr '\n' ' ')
            _html_row "Listener" "INFO" "Listener UP from ${_lsnr_home}. Services: ${_lsnr_svc:-The listener supports no services}"
        else
            _html_row "Listener" "WARN" \
                "Listener (${_lsnr_home}) did not confirm READY (RC=${_lsnr_rc}). Check: lsnrctl status"
        fi
    fi

    send_html_report "DB OPEN (${phase}) - ${db} - ${HOST}" "Database Open Notification (${phase})"

    HTML_ROWS="$saved_rows"
    ATTACH_FILES=( "${saved_attachments[@]}" )
}

# ------------------------------------------------------------
# ORATAB HELPERS
# ------------------------------------------------------------
escape_html() {
    sed 's/&/\&/g; s/</\</g; s/>/\>/g'
}

format_oratab_html() {
    local primary_home="$1"
    if [[ ! -f "$ORATAB_FILE" ]]; then
        echo "$ORATAB_FILE not found."
        return
    fi
    local html=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^# ]]; then
            continue
        fi
        local sid home flag rest
        IFS=: read -r sid home flag rest <<<"$line"
        local display="${sid}:${home}:${flag}"
        local esc
        esc=$(printf '%s\n' "$display" | escape_html)
        if [[ -n "$primary_home" && "$home" == "$primary_home" ]]; then
            html+="<b style=\"color:#155724;\">${esc} (current)</b><br/>"
        else
            html+="${esc}<br/>"
        fi
    done < "$ORATAB_FILE"
    echo "$html"
}

format_crs_stat_html() {
    local log_file="$1"
    [[ ! -f "$log_file" ]] && echo "(log not found: $log_file)" && return
    local html=""
    html+="<table style='border-collapse:collapse;font-size:12px;width:100%;font-family:monospace'>"
    html+="<thead><tr>"
    html+="<th style='background:#1a3a2a;color:#aee8c0;padding:5px 10px;text-align:left;border:1px solid #2d6a4f'>Resource</th>"
    html+="<th style='background:#1a3a2a;color:#aee8c0;padding:5px 10px;text-align:left;border:1px solid #2d6a4f'>Target</th>"
    html+="<th style='background:#1a3a2a;color:#aee8c0;padding:5px 10px;text-align:left;border:1px solid #2d6a4f'>State</th>"
    html+="<th style='background:#1a3a2a;color:#aee8c0;padding:5px 10px;text-align:left;border:1px solid #2d6a4f'>Server</th>"
    html+="<th style='background:#1a3a2a;color:#aee8c0;padding:5px 10px;text-align:left;border:1px solid #2d6a4f'>Details</th>"
    html+="</tr></thead><tbody>"
    local current_resource="" current_section="" row_idx=0
    while IFS= read -r line; do
        # Section headers
        if [[ "$line" =~ ^"Local Resources" ]]; then
            html+="<tr><td colspan='5' style='background:#0d2418;color:#6fcf97;padding:4px 10px;font-weight:bold;border:1px solid #2d6a4f'>▶ Local Resources</td></tr>"
            current_section="local"; continue
        fi
        if [[ "$line" =~ ^"Cluster Resources" ]]; then
            html+="<tr><td colspan='5' style='background:#0d2418;color:#6fcf97;padding:4px 10px;font-weight:bold;border:1px solid #2d6a4f'>▶ Cluster Resources</td></tr>"
            current_section="cluster"; continue
        fi
        # Skip separator lines
        [[ "$line" =~ ^-+ ]] && continue
        [[ "$line" =~ ^"Name" ]] && continue
        [[ -z "${line// }" ]] && continue
        # Resource name line (starts without leading spaces)
        if [[ "$line" =~ ^[^[:space:]] ]]; then
            current_resource=$(echo "$line" | awk '{print $1}')
            # If the line also has status columns on same line (local resources)
            local rest
            rest="${line#$current_resource}"
            if [[ "$rest" =~ ([A-Z]+)[[:space:]]+([A-Z]+)[[:space:]]+([^[:space:]].*) ]]; then
                local tgt="${BASH_REMATCH[1]}" st="${BASH_REMATCH[2]}" srv_det="${BASH_REMATCH[3]}"
                local srv det
                srv=$(echo "$srv_det" | awk '{print $1}')
                det=$(echo "$srv_det" | cut -d' ' -f2-)
                local state_color="#c3e6cb"
                [[ "$st" == "OFFLINE" ]] && state_color="#f5c6cb"
                [[ "$st" == "ONLINE"  ]] && state_color="#c3e6cb"
                local row_bg; (( row_idx % 2 == 0 )) && row_bg="#0f2d1e" || row_bg="#122a1c"
                local esc_res esc_det
                esc_res=$(printf '%s' "$current_resource" | escape_html)
                esc_det=$(printf '%s' "$det" | escape_html)
                html+="<tr style='background:${row_bg}'>"
                html+="<td style='padding:4px 10px;border:1px solid #2d6a4f;color:#e0ffe0'>${esc_res}</td>"
                html+="<td style='padding:4px 10px;border:1px solid #2d6a4f;color:#aaa'>${tgt}</td>"
                html+="<td style='padding:4px 10px;border:1px solid #2d6a4f;font-weight:bold;color:${state_color}'>${st}</td>"
                html+="<td style='padding:4px 10px;border:1px solid #2d6a4f;color:#ccc'>${srv}</td>"
                html+="<td style='padding:4px 10px;border:1px solid #2d6a4f;color:#aaa'>${esc_det}</td>"
                html+="</tr>"
                (( row_idx++ )) || true
                current_resource=""
            fi
        # Numbered instance line (cluster resources): "      1        ONLINE  ONLINE  server  details"
        elif [[ "$line" =~ ^[[:space:]]+([0-9]+)[[:space:]]+([A-Z]+)[[:space:]]+([A-Z]+)[[:space:]]*(.*) ]]; then
            local inst="${BASH_REMATCH[1]}" tgt="${BASH_REMATCH[2]}" st="${BASH_REMATCH[3]}" rest="${BASH_REMATCH[4]}"
            local srv det
            srv=$(echo "$rest" | awk '{print $1}')
            det=$(echo "$rest" | cut -d' ' -f2-)
            [[ -z "$srv" ]] && srv="—"
            local state_color="#c3e6cb"
            [[ "$st" == "OFFLINE" ]] && state_color="#f5c6cb"
            local row_bg; (( row_idx % 2 == 0 )) && row_bg="#0f2d1e" || row_bg="#122a1c"
            local esc_res esc_det
            esc_res=$(printf '%s' "${current_resource}" | escape_html)
            esc_det=$(printf '%s' "$det" | escape_html)
            html+="<tr style='background:${row_bg}'>"
            html+="<td style='padding:4px 10px;border:1px solid #2d6a4f;color:#e0ffe0'>${esc_res}</td>"
            html+="<td style='padding:4px 10px;border:1px solid #2d6a4f;color:#aaa'>${tgt}</td>"
            html+="<td style='padding:4px 10px;border:1px solid #2d6a4f;font-weight:bold;color:${state_color}'>${st}</td>"
            html+="<td style='padding:4px 10px;border:1px solid #2d6a4f;color:#ccc'>${srv}</td>"
            html+="<td style='padding:4px 10px;border:1px solid #2d6a4f;color:#aaa'>${esc_det}</td>"
            html+="</tr>"
            (( row_idx++ )) || true
        # Continuation line (wrapped State details column)
        elif [[ -n "$current_resource" && "$line" =~ ^[[:space:]] ]]; then
            local cont
            cont=$(echo "$line" | xargs)
            [[ -n "$cont" ]] && html+="<tr style='background:#0a1f12'><td colspan='4'></td><td style='padding:2px 10px;border:1px solid #2d6a4f;color:#888;font-size:11px'>${cont}</td></tr>"
        fi
    done < "$log_file"
    html+="</tbody></table>"
    echo "$html"
}

backup_oratab() {
    if [[ ! -f "$ORATAB_FILE" ]]; then
        log "WARN: $ORATAB_FILE not found; nothing to back up."
        return
    fi
    local ts
    ts=$(date +%F_%H%M%S)
    local backup="${LOG_DIR}/oratab.bak.${HOSTNAME}.${ts}"
    run_cmd "cp -p \"$ORATAB_FILE\" \"$backup\""
    log "Backed up $ORATAB_FILE to $backup"
}

capture_gi_oratab_state() {
    GI_MGMTDB_SID=""
    if [[ ! -f "$ORATAB_FILE" ]]; then
        log "INFO: $ORATAB_FILE not found; cannot capture GI oratab state."
        return
    fi
    local gi_line=""
    local mgmt_line=""
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        IFS=: read -r sid home flag rest <<<"$line"
        [[ "$home" != "$OLD_GI_HOME" ]] && continue
        [[ -z "$gi_line" ]] && gi_line="$line"
        if [[ "$sid" =~ MGMTDB ]]; then
            mgmt_line="$line"
        fi
    done < "$ORATAB_FILE"
    if [[ -n "$gi_line" ]]; then
        echo "$gi_line" > "$GI_ORATAB_SNAPSHOT"
        log "Captured GI oratab entry for GI home: $gi_line"
    else
        log "INFO: No oratab entry found with home $OLD_GI_HOME"
    fi
    if [[ -n "$mgmt_line" ]]; then
        IFS=: read -r sid _ <<<"$mgmt_line"
        GI_MGMTDB_SID="$sid"
        echo "$GI_MGMTDB_SID" > "$GI_MGMTDB_SID_FILE"
        log "Captured MGMTDB SID for datapatch: $GI_MGMTDB_SID"
    else
        log "INFO: No MGMTDB entry found in oratab for GI home – GI datapatch may be skipped."
    fi
}

load_gi_mgmtdb_sid() {
    if [[ -n "$GI_MGMTDB_SID" ]]; then
        echo "$GI_MGMTDB_SID"
        return
    fi
    if [[ -f "$GI_MGMTDB_SID_FILE" ]]; then
        GI_MGMTDB_SID="$(<"$GI_MGMTDB_SID_FILE")"
        echo "$GI_MGMTDB_SID"
        return
    fi
    echo ""
}

get_home_from_oratab_for_sid() {
    local sid="$1"
    if [[ ! -f "$ORATAB_FILE" ]]; then
        echo ""
        return
    fi
    local line
    line=$(awk -F: -v s="$sid" 'NF>=2 && $1==s {print; exit}' "$ORATAB_FILE")
    if [[ -z "$line" ]]; then
        echo ""
        return
    fi
    IFS=: read -r _ home _ <<<"$line"
    echo "$home"
}

update_oratab_gi_home() {
    local target_home="$1"
    if [[ "$GI_CLUSTER_MODE" != "CRS" && "$GI_CLUSTER_MODE" != "HAS" ]]; then
        log "INFO: GI mode is $GI_CLUSTER_MODE; not modifying oratab for GI."
        return
    fi
    if [[ ! -f "$ORATAB_FILE" ]]; then
        log "WARN: $ORATAB_FILE not found; cannot update GI entry."
        return
    fi
    backup_oratab
    local sid=""
    local flag="N"
    if [[ -f "$GI_ORATAB_SNAPSHOT" ]]; then
        IFS=: read -r sid _ flag <<<"$(<"$GI_ORATAB_SNAPSHOT")"
    fi
    if [[ -z "$sid" ]]; then
        log "WARN: No saved GI SID; oratab GI entry not updated."
        return
    fi
    local tmp="${LOG_DIR}/oratab.tmp.$$"
    : > "$tmp"
    local found=false
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            echo "$line" >> "$tmp"
            continue
        fi
        if [[ "$line" =~ ^# ]]; then
            echo "$line" >> "$tmp"
            continue
        fi
        IFS=: read -r s home f rest <<<"$line"
        if [[ "$s" == "$sid" ]]; then
            echo "${sid}:${target_home}:${f}" >> "$tmp"
            found=true
        else
            echo "$line" >> "$tmp"
        fi
    done < "$ORATAB_FILE"
    if [[ "$found" != true ]]; then
        echo "${sid}:${target_home}:${flag}" >> "$tmp"
    fi
    if ! run_cmd "sudo cp -p \"$tmp\" \"$ORATAB_FILE\""; then
        log "WARN: Failed to overwrite $ORATAB_FILE from $tmp; update GI entry manually."
        add_html_row "/etc/oratab update (GI)" "FAIL" \
            "Could not overwrite $ORATAB_FILE for GI SID $sid; update manually."
    else
        log "Updated GI entry in $ORATAB_FILE to use $target_home for SID $sid"
        add_html_row "/etc/oratab update (GI)" "PASS" \
            "Updated GI entry for SID $sid to home $target_home."
    fi
    rm -f "$tmp"
}

update_oratab_db_after_switch() {
    if [[ ! -f "$ORATAB_FILE" ]]; then
        log "WARN: $ORATAB_FILE not found; cannot update DB entries."
        return
    fi
    backup_oratab
    local old_norm="${OLD_DB_HOME%/}"
    local new_norm="${NEW_DB_HOME%/}"
    local tmp="${LOG_DIR}/oratab.tmp.$$"
    local matched=0
    : > "$tmp"
    while IFS= read -r line; do
        if [[ -z "$line" || "$line" =~ ^# ]]; then
            echo "$line" >> "$tmp"
            continue
        fi
        local sid home flag
        IFS=: read -r sid home flag _ <<<"$line"
        home="${home%/}"
        if [[ "$home" == "$old_norm" ]]; then
            echo "# OOP-SWITCH: ${sid}:${OLD_DB_HOME%/}:${flag}" >> "$tmp"
            echo "${sid}:${new_norm}:${flag}" >> "$tmp"
            matched=$((matched + 1))
        else
            echo "$line" >> "$tmp"
        fi
    done < "$ORATAB_FILE"
    if [[ $matched -eq 0 ]]; then
        add_html_row "/etc/oratab update (DB switch)" "WARN" \
            "No oratab entries matched OLD_DB_HOME=${OLD_DB_HOME} — oratab not modified."
        rm -f "$tmp"
        return
    fi
    if ! run_cmd "sudo cp -p \"$tmp\" \"$ORATAB_FILE\""; then
        add_html_row "/etc/oratab update (DB switch)" "FAIL" \
            "Could not overwrite $ORATAB_FILE for DB switch; update manually."
    else
        log "Updated $ORATAB_FILE for DB switch: OLD_DB_HOME -> NEW_DB_HOME ($matched entries)"
        add_html_row "/etc/oratab update (DB switch)" "PASS" \
            "Updated $matched oratab entry(ies): ${OLD_DB_HOME} → ${NEW_DB_HOME}."
    fi
    rm -f "$tmp"
}

update_oratab_db_after_rollback() {
    if [[ ! -f "$ORATAB_FILE" ]]; then
        log "WARN: $ORATAB_FILE not found; cannot update DB entries."
        return
    fi
    backup_oratab
    local old_norm="${OLD_DB_HOME%/}"
    local new_norm="${NEW_DB_HOME%/}"
    local tmp="${LOG_DIR}/oratab.tmp.$$"
    local matched=0
    : > "$tmp"
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            echo "$line" >> "$tmp"
            continue
        fi
        # Restore OOP-SWITCH comments: "# OOP-SWITCH: sid:old_home:flag"
        if [[ "$line" =~ ^#\ OOP-SWITCH:\ (.+) ]]; then
            local inner="${BASH_REMATCH[1]}"
            local sid home flag
            IFS=: read -r sid home flag _ <<<"$inner"
            home="${home%/}"
            if [[ "$home" == "$old_norm" ]]; then
                echo "${sid}:${old_norm}:${flag}" >> "$tmp"
                matched=$((matched + 1))
            else
                echo "$line" >> "$tmp"
            fi
            continue
        fi
        if [[ "$line" =~ ^# ]]; then
            echo "$line" >> "$tmp"
            continue
        fi
        # Comment out any active NEW_DB_HOME entries (defensive — handles repeated runs)
        local sid home flag
        IFS=: read -r sid home flag _ <<<"$line"
        home="${home%/}"
        if [[ "$home" == "$new_norm" ]]; then
            echo "# OOP-ROLLBACK-REMOVED: $line" >> "$tmp"
            matched=$((matched + 1))
        else
            echo "$line" >> "$tmp"
        fi
    done < "$ORATAB_FILE"
    if [[ $matched -eq 0 ]]; then
        add_html_row "/etc/oratab update (DB rollback)" "WARN" \
            "No oratab entries matched for rollback (OLD=${OLD_DB_HOME}, NEW=${NEW_DB_HOME}) — oratab not modified."
        rm -f "$tmp"
        return
    fi
    if ! run_cmd "sudo cp -p \"$tmp\" \"$ORATAB_FILE\""; then
        add_html_row "/etc/oratab update (DB rollback)" "FAIL" \
            "Could not overwrite $ORATAB_FILE for DB rollback; update manually."
    else
        log "Updated $ORATAB_FILE for DB rollback: NEW_DB_HOME -> OLD_DB_HOME ($matched entries)"
        add_html_row "/etc/oratab update (DB rollback)" "PASS" \
            "Restored $matched oratab entry(ies): ${NEW_DB_HOME} → ${OLD_DB_HOME}."
    fi
    rm -f "$tmp"
}

# Idempotent oratab normalizer — removes ALL active entries for $sid and writes
# exactly one: sid:target_home:N. Also strips accumulated OOP comment tags for
# the same SID to prevent noise from repeated switch/rollback cycles.
normalize_oratab_for_sid() {
    local sid="$1"
    local target_home="${2%/}"
    if [[ ! -f "$ORATAB_FILE" ]]; then
        log "WARN: $ORATAB_FILE not found; cannot update."
        return
    fi
    backup_oratab
    local tmp="${LOG_DIR}/oratab.tmp.$$"
    : > "$tmp"
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            echo "$line" >> "$tmp"; continue
        fi
        if [[ "$line" =~ ^# ]]; then
            # Drop accumulated OOP comment lines for this SID to prevent runaway accumulation
            if [[ "$line" =~ OOP-(SWITCH|ROLLBACK-REMOVED).*${sid}: ]]; then
                continue
            fi
            echo "$line" >> "$tmp"; continue
        fi
        local _sid _home _flag
        IFS=: read -r _sid _home _flag _ <<<"$line"
        # Case-insensitive removal: pmon SID is lowercase, DB_UNIQUE_NAME may be
        # uppercase (from v$database). AutoUpgrade may also write uppercase entries.
        if [[ "${_sid,,}" == "${sid,,}" ]]; then
            continue  # Remove all existing active entries for this SID (any case)
        fi
        echo "$line" >> "$tmp"
    done < "$ORATAB_FILE"
    echo "${sid}:${target_home}:N" >> "$tmp"
    if ! sudo cp -p "$tmp" "$ORATAB_FILE" 2>/dev/null; then
        if ! run_cmd "sudo cp -p \"$tmp\" \"$ORATAB_FILE\""; then
            add_html_row "/etc/oratab" "FAIL" "Could not update $ORATAB_FILE; set ${sid}:${target_home}:N manually."
            rm -f "$tmp"; return
        fi
    fi
    add_html_row "/etc/oratab" "PASS" "${sid} → ${target_home} (single active entry written)."
    rm -f "$tmp"
}

# Stop listener from $1 home, copy missing network/admin files, start from $2 home.
# Used for DB-only hosts where the listener is managed from the DB home (no GI/srvctl).
manage_db_only_listener() {
    local from_home="${1%/}"
    local to_home="${2%/}"

    # Copy missing network/admin files so the listener in the new home can start
    if [[ -d "$from_home/network/admin" && "$from_home" != "$to_home" ]]; then
        sudo -u "$ORACLE_USER" bash -c "
            mkdir -p \"$to_home/network/admin\"
            for f in listener.ora tnsnames.ora sqlnet.ora; do
                src=\"$from_home/network/admin/\$f\"
                dst=\"$to_home/network/admin/\$f\"
                [[ -f \"\$src\" && ! -f \"\$dst\" ]] && cp -p \"\$src\" \"\$dst\" && echo \"Copied \$f\"
            done
        " 2>&1 | while IFS= read -r _l; do [[ -n "$_l" ]] && log "network/admin copy: $_l"; done || true
        add_html_row "Listener network/admin" "INFO" "Missing files copied from $from_home/network/admin to $to_home/network/admin."
    fi

    # Stop listener from the OLD home (best-effort; may already be down)
    if [[ -x "$from_home/bin/lsnrctl" ]]; then
        sudo -u "$ORACLE_USER" bash -c "
            export ORACLE_HOME=\"$from_home\"
            export PATH=\"$from_home/bin:\$PATH\"
            \"$from_home/bin/lsnrctl\" stop 2>&1 | tail -3
        " 2>&1 | while IFS= read -r _l; do log "lsnrctl stop: $_l"; done || true
        add_html_row "Listener stop" "INFO" "Stopped listener from $from_home (may have already been down)."
    fi

    # Start listener from the NEW home
    if [[ -x "$to_home/bin/lsnrctl" ]]; then
        local lsnr_out lsnr_rc=0
        lsnr_out=$(sudo -u "$ORACLE_USER" bash -c "
            export ORACLE_HOME=\"$to_home\"
            export PATH=\"$to_home/bin:\$PATH\"
            \"$to_home/bin/lsnrctl\" start 2>&1
        ") || lsnr_rc=$?
        if echo "$lsnr_out" | grep -qi "The command completed successfully"; then
            add_html_row "Listener start" "PASS" "Listener started from $to_home."
        else
            add_html_row "Listener start" "WARN" \
                "lsnrctl start RC=${lsnr_rc}. Last output: $(echo "$lsnr_out" | grep -v '^[[:space:]]*$' | tail -3 | tr '\n' ' '). May need manual start."
        fi
    else
        add_html_row "Listener start" "WARN" "lsnrctl not found at $to_home/bin — start listener manually."
    fi
}

ensure_asm_oratab_entry_for_gi_home() {
    local gi_home="$1"
    if [[ ! -f "$ORATAB_FILE" ]]; then
        log "WARN: $ORATAB_FILE not found; cannot ensure ASM oratab entry."
        add_html_row "/etc/oratab ASM entry" "WARN" \
            "Could not ensure ASM entry: $ORATAB_FILE not found."
        return
    fi
    if awk -F: -v h="$gi_home" '$2==h && $1 ~ /^\+ASM/ {found=1} END{exit(!found)}' "$ORATAB_FILE"; then
        log "INFO: ASM oratab entry for home $gi_home already present."
        add_html_row "/etc/oratab ASM entry" "INFO" \
            "ASM entry already present in $ORATAB_FILE for home $gi_home."
        return
    fi
    local asm_sid="+ASM1"
    if grep -q '^+ASM1:' "$ORATAB_FILE" 2>/dev/null; then
        asm_sid="+ASM"
    fi
    backup_oratab
    local tmp="${LOG_DIR}/oratab.tmp.$$"
    cp -p "$ORATAB_FILE" "$tmp"
    echo "${asm_sid}:${gi_home}:N" >> "$tmp"
    if ! run_cmd "sudo cp -p \"$tmp\" \"$ORATAB_FILE\""; then
        log "WARN: Failed to append ASM entry ($asm_sid:$gi_home:N) to $ORATAB_FILE"
        add_html_row "/etc/oratab ASM entry" "FAIL" \
            "Could not append ASM entry ${asm_sid}:${gi_home}:N to $ORATAB_FILE; update manually."
    else
        log "Added ASM oratab entry: ${asm_sid}:${gi_home}:N"
        add_html_row "/etc/oratab ASM entry" "PASS" \
            "Added ASM entry: <code>${asm_sid}:${gi_home}:N</code> to $ORATAB_FILE."
    fi
    rm -f "$tmp"
}
# ------------------------------------------------------------
# EMBEDDED RESPONSE FILE WRITERS (19c)
# ------------------------------------------------------------
write_db_rsp_if_embedded() {
    if [[ "${EMBED_RSP:-false}" != true ]]; then
        return
    fi
    compute_db_cluster_nodes

    # Base part of the RSP without CLUSTER_NODES
    cat > "$DB_RSP" <<EOF
oracle.install.responseFileVersion=/oracle/install/rspfmt_dbinstall_response_schema_v19.0.0
oracle.install.option=INSTALL_DB_SWONLY
UNIX_GROUP_NAME=${OINSTALL}
INVENTORY_LOCATION=/app/oraInventory
ORACLE_BASE=/app/oracle
oracle.install.db.InstallEdition=EE
oracle.install.db.OSDBA_GROUP=${OINSTALL}
oracle.install.db.OSOPER_GROUP=${OINSTALL}
oracle.install.db.OSBACKUPDBA_GROUP=${OINSTALL}
oracle.install.db.OSDGDBA_GROUP=${OINSTALL}
oracle.install.db.OSKMDBA_GROUP=${OINSTALL}
oracle.install.db.OSRACDBA_GROUP=${OINSTALL}
oracle.install.db.rootconfig.executeRootScript=true
oracle.install.db.rootconfig.configMethod=SUDO
oracle.install.db.rootconfig.sudoPath=/usr/bin/sudo
oracle.install.db.rootconfig.sudoUserName=${ORACLE_USER}
EOF

    # Only emit CLUSTER_NODES for true RAC environments
    if [[ -n "${DB_CLUSTER_NODES:-}" ]]; then
        echo "oracle.install.db.CLUSTER_NODES=${DB_CLUSTER_NODES}" >> "$DB_RSP"
    fi

    chown "${ORACLE_USER}:${OINSTALL}" "$DB_RSP" 2>/dev/null || true
    chmod 600 "$DB_RSP" 2>/dev/null || true
}
write_gi_rsp_if_embedded() {
    if [[ "${EMBED_RSP:-false}" != true ]]; then
        return
    fi

    # Derive OSOPER from old home if present (as per our previous discussion)
    if [[ -z "${OLD_GI_OSOPER_GROUP:-}" && -d "$OLD_GI_HOME" ]]; then
        OLD_GI_OSOPER_GROUP=$(get_old_gi_osoper_group)
    fi
    local rsp_osoper="${OLD_GI_OSOPER_GROUP}"

    # Auto-build network interface list unless overridden
    local net_if_list
    net_if_list=$(build_gi_network_interface_list)

    cat > "$GI_RSP" <<EOF
oracle.install.responseFileVersion=/oracle/install/rspfmt_crsinstall_response_schema_v19.0.0
INVENTORY_LOCATION=/app/oraInventory
oracle.install.option=CRS_SWONLY
ORACLE_BASE=/app/oracle
oracle.install.asm.OSDBA=${OINSTALL}
oracle.install.asm.OSOPER=${rsp_osoper}
oracle.install.asm.OSASM=${OINSTALL}
oracle.install.crs.config.scanType=LOCAL_SCAN
oracle.install.crs.config.gpnp.scanName=${GI_SCAN_NAME}
oracle.install.crs.config.gpnp.scanPort=${GI_SCAN_PORT}
oracle.install.crs.config.ClusterConfiguration=STANDALONE
oracle.install.crs.config.clusterName=${GI_CLUSTER_NAME}
oracle.install.crs.config.clusterNodes=${GI_CLUSTER_NODES}
oracle.install.crs.config.networkInterfaceList=${net_if_list}
oracle.install.crs.configureGIMR=false
oracle.install.asm.configureGIMRDataDG=false
oracle.install.asm.SYSASMPassword=Updatepass!321
oracle.install.crs.rootconfig.executeRootScript=true
oracle.install.crs.rootconfig.configMethod=SUDO
oracle.install.crs.rootconfig.sudoPath=/usr/bin/sudo
oracle.install.crs.rootconfig.sudoUserName=${GRID_USER}
EOF
    chown "${GRID_USER}:${OINSTALL}" "$GI_RSP" 2>/dev/null || true
    chmod 600 "$GI_RSP" 2>/dev/null || true
}

# ------------------------------------------------------------
# GI networkInterfaceList auto-detector
# ------------------------------------------------------------
build_gi_network_interface_list() {
    # If user set an override, honour it
    if [[ -n "${GI_NETWORK_IF_LIST:-}" ]]; then
        echo "${GI_NETWORK_IF_LIST}"
        return
    fi

    local pub_if="" pub_net=""
    local priv_if="" priv_net=""

    # Collect interface info into a temp file (portable, no process substitution)
    local tmp_if
    tmp_if=$(mktemp /tmp/gi_iflist.XXXXXX)

    # ip -o -4 addr output example:
    # 2: ens18    inet 172.17.36.51/24 brd 172.17.36.255 scope global ens18
    # We reduce it to: idx ifname fam addr
    ip -o -4 addr show 2>/dev/null \
        | awk '{print $1" "$2" "$3" "$4}' > "$tmp_if" 2>/dev/null || true

    # IMPORTANT: set IFS explicitly so global IFS ($'\n\t') doesn't break us
    while IFS=' ' read -r idx ifname fam addr _; do
        # Skip loopback
        [[ "$ifname" == "lo" ]] && continue
        [[ "$fam" != "inet" ]] && continue
        [[ -z "${addr:-}" ]] && continue

        local ip cidr net
        ip=${addr%/*}
        cidr=${addr#*/}

        # Derive network from IP/CIDR; fall back to /24-style mask if ipcalc not present
        if command -v ipcalc >/dev/null 2>&1; then
            net=$(ipcalc -n "${ip}/${cidr}" 2>/dev/null \
                  | awk -F= '/^NETWORK=/{print $2}' || true)
        else
            # Very dumb fallback: assume /24
            net="$(echo "$ip" | awk -F. '{printf "%s.%s.%s.0",$1,$2,$3}')"
        fi

        # classify by name or network – adjust to your env
        #   ens18 / 172.17.*.* -> public (type 1)
        #   ens19 / 172.18.*.* -> private (type 5)
        if [[ -z "$pub_if" ]] && [[ "$ifname" == "ens18" || $net == 172.17.*.0 ]]; then
            pub_if="$ifname"
            pub_net="$net"
        elif [[ -z "$priv_if" ]] && [[ "$ifname" == "ens19" || $net == 172.18.*.0 ]]; then
            priv_if="$ifname"
            priv_net="$net"
        fi

    done < "$tmp_if"

    rm -f "$tmp_if" 2>/dev/null || true

    local list=""
    if [[ -n "$pub_if" && -n "$pub_net" ]]; then
        list+="${pub_if}:${pub_net}:1"
    fi
    if [[ -n "$priv_if" && -n "$priv_net" ]]; then
        [[ -n "$list" ]] && list+=","
        list+="${priv_if}:${priv_net}:5"
    fi

    echo "$list"
}
# ------------------------------------------------------------
# NEW: sudo path detector for 23ai GI rsp
# ------------------------------------------------------------
detect_sudo_path() {
    if [[ -x /usr/bin/sudo ]]; then
        echo "/usr/bin/sudo"
    elif command -v sudo >/dev/null 2>&1; then
        command -v sudo
    else
        echo ""
    fi
}
# ------------------------------------------------------------
# NEW: 23ai GI RESPONSE FILE WRITERS (install + upgrade, MINIMAL)
# ------------------------------------------------------------
detect_gi_cluster_mode() {
    local crsctl_bin=""
    if [[ -x "$OLD_GI_HOME/bin/crsctl" ]]; then
        crsctl_bin="$OLD_GI_HOME/bin/crsctl"
    elif command -v crsctl >/dev/null 2>&1; then
        crsctl_bin="$(command -v crsctl)"
    else
        echo "UNKNOWN"
        return
    fi

    # Prefer "cluster mode status"  very reliable on RAC
    local mode_out
    mode_out=$("$crsctl_bin" get cluster mode status 2>/dev/null || true)
    local rc=$?
    if (( rc == 0 )) && [[ "$mode_out" == *"Cluster is running in"* ]]; then
        echo "CRS"
        return
    fi

    # Fallback to "cluster type"
    local type_out type_line
    type_out=$("$crsctl_bin" get cluster type 2>&1 || true)
    type_line=$(echo "$type_out" | awk 'NF == 1 && ($1 == "CLUSTER" || $1 == "STANDALONE") {print $1; exit}')
    if [[ "$type_line" == "CLUSTER" ]]; then
        echo "CRS"
        return
    elif [[ "$type_line" == "STANDALONE" ]]; then
        echo "HAS"
        return
    fi

    # Fallback to olsnodes
    if command -v olsnodes >/dev/null 2>&1; then
        local nodes
        nodes=$(olsnodes 2>/dev/null || echo "")
        if [[ -n "$nodes" ]]; then
            echo "CRS"
            return
        fi
    fi

    # Last resort
    echo "HAS"
}
# ------------------------------------------------------------
# GI OSOPER GROUP FROM OLD HOME (config.c)
# ------------------------------------------------------------
get_old_gi_osoper_group() {
    local cfg="${OLD_GI_HOME}/rdbms/lib/config.c"
    if [[ ! -f "$cfg" ]]; then
        echo ""
        return
    fi
    # Example line: #define SS_OPER_GRP ""
    # or:          #define SS_OPER_GRP "oinstall"
    local val
    val=$(awk '/#define[[:space:]]+SS_OPER_GRP/ {print $3; exit}' "$cfg" 2>/dev/null | tr -d '"')
    echo "$val"
}
# Shared base content for both install and upgrade RSPs
build_gi_23ai_rsp_base() {
    GI_CLUSTER_MODE=$(detect_gi_cluster_mode)
    local mode="$GI_CLUSTER_MODE"

    local clusterUsageValue="GENERAL_PURPOSE"
    [[ "$mode" == "CRS" ]] && clusterUsageValue="RAC"

    local scan_name="${GI_SCAN_NAME:-$(hostname -s)-scan}"
    local scan_port="${GI_SCAN_PORT:-1521}"
    local cluster_name="${GI_CLUSTER_NAME:-$(hostname -s)-cluster}"

    local clusterNodes=""
    if [[ "$mode" == "CRS" ]] && command -v olsnodes >/dev/null 2>&1; then
        clusterNodes=$(olsnodes 2>/dev/null | paste -sd "," -)
    else
        clusterNodes="$(hostname -f):"
    fi

    local sudoPath
    sudoPath=$(detect_sudo_path)

    local execRoot="true"
    local cfgMethod="SUDO"
    local rspSudoPath="$sudoPath"
    local rspSudoUser="$GRID_USER"

    if [[ "${GI_USE_SUDO_FOR_ROOT:-true}" != true ]]; then
        execRoot="false"
        cfgMethod="SUDO"
        rspSudoPath=""
        rspSudoUser=""
    fi

    # Derive OS groups for 23/26ai GI from old home where possible
    local osdba_grp="${OINSTALL}"
    local osasm_grp="${OINSTALL}"
    local osoper_grp=""

    # Populate OLD_GI_OSOPER_GROUP once if not set
    if [[ -z "${OLD_GI_OSOPER_GROUP:-}" && -d "$OLD_GI_HOME" ]]; then
        OLD_GI_OSOPER_GROUP=$(get_old_gi_osoper_group)
    fi
    osoper_grp="${OLD_GI_OSOPER_GROUP}"

    # If there is no old GI home (fresh install case), you can choose your default:
    # - leave osoper_grp empty (no OSOPER), or
    # - set it to OINSTALL if you prefer.
    if [[ ! -d "$OLD_GI_HOME" && -z "$osoper_grp" ]]; then
        osoper_grp=""   # change to "${OINSTALL}" if you want OSOPER by default on brand-new clusters
    fi

    cat <<EOF
INVENTORY_LOCATION=/app/oraInventory
ORACLE_BASE=/app/oracle
clusterUsage=${clusterUsageValue}
OSDBA=${osdba_grp}
OSOPER=${osoper_grp}
OSASM=${osasm_grp}
scanType=LOCAL_SCAN
scanName=${scan_name}
scanPort=${scan_port}
configureAsExtendedCluster=false
clusterName=${cluster_name}
configureGNS=false
configureDHCPAssignedVIPs=false
gnsSubDomain=
gnsVIPAddress=
sites=
clusterNodes=${clusterNodes}
networkInterfaceList=
storageOption=FLEX_ASM_STORAGE
votingFilesLocations=
ocrLocations=
clientDataFile=
useIPMI=false
bmcBinpath=
bmcUsername=
bmcPassword=
sysasmPassword=
diskGroupName=DATA
redundancy=EXTERNAL
auSize=4
failureGroups=
disksWithFailureGroupNames=
diskList=
quorumFailureGroupNames=
diskString=/dev/oracleasm/*
asmsnmpPassword=
ignoreDownNodes=false
configureBackupDG=true
backupDGName=FRA
backupDGRedundancy=EXTERNAL
backupDGAUSize=4
backupDGFailureGroups=
backupDGDisksWithFailureGroupNames=
backupDGDiskList=
backupDGQuorumFailureGroups=
managementOption=NONE
omsHost=
omsPort=0
emAdminUser=
emAdminPassword=
executeRootScript=${execRoot}
configMethod=${cfgMethod}
sudoPath=${rspSudoPath}
sudoUserName=${rspSudoUser}
batchInfo=
nodesToDelete=
enableAutoFixup=false
EOF
}

# Install: CRS_SWONLY
write_gi_23ai_rsp() {
    cat > "$GI_UPGRADE_RSP" <<EOF
oracle.install.responseFileVersion=/oracle/install/rspfmt_crsinstall_response_schema_v23.0.0
installOption=CRS_SWONLY
$(build_gi_23ai_rsp_base)
EOF
    chown "${GRID_USER}:${OINSTALL}" "$GI_UPGRADE_RSP" 2>/dev/null || true
    chmod 600 "$GI_UPGRADE_RSP" 2>/dev/null || true
}

# Upgrade: UPGRADE (same base content)
write_gi_23ai_upgrade_rsp() {
    cat > "$GI_UPGRADE_RSP_UPGRADE" <<EOF
oracle.install.responseFileVersion=/oracle/install/rspfmt_crsinstall_response_schema_v23.0.0
installOption=UPGRADE
$(build_gi_23ai_rsp_base)
EOF
    chown "${GRID_USER}:${OINSTALL}" "$GI_UPGRADE_RSP_UPGRADE" 2>/dev/null || true
    chmod 600 "$GI_UPGRADE_RSP_UPGRADE" 2>/dev/null || true
}
# ------------------------------------------------------------
# ENV / PRECHECK HELPERS
# ------------------------------------------------------------
check_at_service_html() {
    local status details
    if ! command -v at >/dev/null 2>&1; then
        status="FAIL"
        details="at(1) command not found. Scheduling via at is not available."
    else
        if systemctl is-active atd &>/dev/null; then
            status="PASS"
            details="at(1) installed and atd service is active."
        else
            status="WARN"
            details="at(1) installed but atd service is NOT active. Scheduling may fail until atd is started."
        fi
    fi
    add_html_row "at / atd availability" "$status" "$details"
}
check_space_html() {
    local mount="$1"
    local minimum_gb="$2"
    if ! df -BG "$mount" &>/dev/null; then
        add_html_row "Filesystem space on $mount" "WARN" "Filesystem $mount not found."
        return
    fi
    local free
    free=$(df -BG "$mount" | awk 'NR==2{gsub("G","",$4);print $4}')
    if (( free >= minimum_gb )); then
        add_html_row "Filesystem space on $mount" "PASS" "${free} GB free (>= ${minimum_gb} GB required)"
    else
        add_html_row "Filesystem space on $mount" "FAIL" "${free} GB free (< ${minimum_gb} GB required)"
    fi
}
check_mount_if_present_html() {
    local mount="$1"
    local minimum_gb="$2"

    if [[ ! -d "$mount" ]]; then
        # For cluster precheck we don't warn on missing generic mounts
        add_html_row "Filesystem space on $mount" "INFO" \
            "Mount point $mount not present on this node; skipping space check."
        return 0
    fi

    if ! df -BG "$mount" &>/dev/null; then
        add_html_row "Filesystem space on $mount" "WARN" \
            "Could not determine filesystem for $mount"
        return 0
    fi

    local free
    free=$(df -BG "$mount" | awk 'NR==2{gsub("G","",$4);print $4}')
    if (( free >= minimum_gb )); then
        add_html_row "Filesystem space on $mount" "PASS" \
            "${free} GB free (>= ${minimum_gb} GB required)"
    else
        add_html_row "Filesystem space on $mount" "FAIL" \
            "${free} GB free (< ${minimum_gb} GB required)"
    fi
}
check_oracle_sudo_nopass_html() {
    local status details
    local current_user
    current_user="$(id -un)"

    # Debug trace so we can see what this check actually did
    log "DEBUG: check_oracle_sudo_nopass_html: current_user=$current_user, ORACLE_USER=$ORACLE_USER"

    if [[ "$current_user" != "$ORACLE_USER" ]]; then
        status="WARN"
        details="Script running as '$current_user', not '$ORACLE_USER'. Cannot reliably confirm NOPASSWD for '$ORACLE_USER'."
    else
        # Try non-interactive sudo; if this fails, password would be required
        if sudo -n true 2>/dev/null; then
            log "DEBUG: check_oracle_sudo_nopass_html: sudo -n true succeeded for user '$current_user'"
            status="PASS"
            details="User '$ORACLE_USER' can run sudo without a password (NOPASSWD likely configured)."
        else
            log "DEBUG: check_oracle_sudo_nopass_html: sudo -n true FAILED for user '$current_user'"
            status="FAIL"
            details="User '$ORACLE_USER' cannot run sudo without a password (NOPASSWD not configured or sudo not permitted).<br/><br/>\
<b>Prerequisites:</b><br/>\
- The oracle OS user must be able to execute sudo commands as root<br/>\
  without being prompted for a password. This is required for GI<br/>\
  upgrade steps that invoke root scripts automatically.<br/><br/>\
Example entry in <code>/etc/sudoers</code>:<br/>\
<code>oracle ALL=(ALL) NOPASSWD:ALL</code>"
        fi
    fi

    add_html_row "oracle sudo without password" "$status" "$details"
}
detect_cluster_type_html() {
    local mode status details
    mode=$(detect_gi_cluster_mode)
    GI_CLUSTER_MODE="$mode"
    case "$mode" in
        CRS)
            status="INFO"
            details="Cluster type: CRS/RAC as per GI cluster mode detection."
            ;;
        HAS)
            status="INFO"
            details="Cluster type: Oracle Restart (single-instance) as per GI cluster mode detection."
            ;;
        *)
            if ! command -v crsctl >/dev/null 2>&1 && ! command -v olsnodes >/dev/null 2>&1; then
                status="INFO"
                details="No GI clusterware detected on this host; treating as standalone / non-GI."
            else
                status="WARN"
                details="Unable to determine cluster type: GI tools present but did not return expected data."
            fi
            ;;
    esac
    add_html_row "Cluster type" "$status" "$details"
}
compute_db_cluster_nodes() {
    if [[ -n "${DB_CLUSTER_NODES:-}" ]]; then
        return
    fi
    local mode
    mode=$(detect_gi_cluster_mode)
    GI_CLUSTER_MODE="$mode"
    if [[ "$mode" == "CRS" ]]; then
        if command -v olsnodes >/dev/null 2>&1; then
            DB_CLUSTER_NODES=$(olsnodes 2>/dev/null | paste -sd "," -)
        else
            DB_CLUSTER_NODES="$HOSTNAME"
        fi
    else
        DB_CLUSTER_NODES=""
    fi
}
assert_precheck_homes_safe() {
    # GI precheck vs real GI homes — skip when PRECHECK_GI_HOME is empty (no GI on this VM)
    if [[ -n "${PRECHECK_GI_HOME:-}" ]]; then
        if [[ "$PRECHECK_GI_HOME" == "$OLD_GI_HOME" || "$PRECHECK_GI_HOME" == "$NEW_GI_HOME" ]]; then
            die "PRECHECK_GI_HOME ($PRECHECK_GI_HOME) overlaps with a real GI home; fix config before running."
        fi
    fi

    # GI upgrade precheck vs real GI homes — only meaningful when GI_UPGRADE_NEW_HOME is set
    if [[ -n "${GI_UPGRADE_NEW_HOME:-}" ]]; then
        local gi_upgrade_pre_home="${GI_UPGRADE_NEW_HOME}-precheck"
        if [[ "$gi_upgrade_pre_home" == "$OLD_GI_HOME" || "$gi_upgrade_pre_home" == "$GI_UPGRADE_NEW_HOME" ]]; then
            die "GI upgrade precheck home ($gi_upgrade_pre_home) overlaps with a real GI home; fix config before running."
        fi
    fi

    # DB precheck vs real DB homes — skip when PRECHECK_DB_HOME is empty (no NEW_DB_HOME configured)
    if [[ -n "${PRECHECK_DB_HOME:-}" ]]; then
        if [[ "$PRECHECK_DB_HOME" == "$OLD_DB_HOME" || "$PRECHECK_DB_HOME" == "$NEW_DB_HOME" ]]; then
            die "PRECHECK_DB_HOME ($PRECHECK_DB_HOME) overlaps with a real DB home; fix config before running."
        fi
    fi
}
# ------------------------------------------------------------
# OPATCH HELPERS
# ------------------------------------------------------------
required_opatch_version() {
    # NOTE: called inside $() — write diagnostic messages only to log file (not stdout)
    # to avoid polluting the captured version string.
    if [[ ! -f "$RU_README" ]]; then
        { echo "$(date '+%F %T') - WARN: RU README not found at $RU_README — cannot determine required OPatch version." >> "$LOG_FILE"; } 2>/dev/null
        echo ""
        return 0
    fi
    local req=""
    req=$(grep -i "OPatch utility version" "$RU_README" 2>/dev/null | head -n1 | \
          grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
    if [[ -z "$req" ]]; then
        req=$(grep -i "Required OPatch Version" "$RU_README" 2>/dev/null | head -n1 | \
              grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
    fi
    if [[ -z "$req" ]]; then
        { echo "$(date '+%F %T') - WARN: Could not parse required OPatch version from $RU_README" >> "$LOG_FILE"; } 2>/dev/null
        echo ""
        return 0
    fi
    { echo "$(date '+%F %T') - INFO: Parsed required OPatch version from README: $req" >> "$LOG_FILE"; } 2>/dev/null
    echo "$req"
}
current_opatch_version() {
    if [[ -x "$1/OPatch/opatch" ]]; then
        ORACLE_HOME="$1" PATH="$1/OPatch:$1/bin:$PATH" \
            "$1/OPatch/opatch" version 2>/dev/null | awk '/OPatch Version/{print $NF}' || echo "0"
    else
        echo "0"
    fi
}
compare_versions() {
    [[ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" == "$2" ]]
}
update_opatch() {
    local home="$1"
    local zip=""
    if [[ -n "${OPATCH_ZIP:-}" && -f "$OPATCH_ZIP" ]]; then
        zip="$OPATCH_ZIP"
    else
        shopt -s nullglob
        local matches=( "${OPATCH_ZIP_DIR}"/${OPATCH_ZIP_PATTERN} )
        shopt -u nullglob
        if (( ${#matches[@]} == 0 )); then
            die "OPatch ZIP missing: expected ${OPATCH_ZIP} or ${OPATCH_ZIP_DIR}/${OPATCH_ZIP_PATTERN}"
        fi
        zip="${matches[0]}"
        log "Discovered OPatch ZIP: $zip"
    fi
    run_cmd "unzip -oq \"$zip\" -d \"$home\""
    run_cmd_allow_fail "chown -R ${ORACLE_USER}:${OINSTALL} \"$home/OPatch\""
}
get_patch_level() {
    local home="$1"
    if [[ ! -x "$home/OPatch/opatch" ]]; then
        echo "OPatch not found in $home ? cannot determine patch level."
        return 0
    fi

    local output rc
    output=$(ORACLE_HOME="$home" PATH="$home/OPatch:$home/bin:$PATH" \
             "$home/OPatch/opatch" lspatches 2>&1)
    rc=$?

    if (( rc != 0 )); then
        # Special-case: inventory load failed (RC=28)
        if (( rc == 28 )); then
            is_db_home_attached "$home"
            case $? in
                0)
                    # Attached but lspatches still failed for some other reason
                    echo "opatch lspatches failed for $home (RC=28) even though home appears attached in central inventory.<br/>Raw output:<br/>$(printf '%s\n' "$output" | sed 's/$/<br\/>/')"
                    ;;
                1)
                    # Not attached
                    echo "Oracle home $home is not attached to central inventory (opatch lspatches RC=28).<br/>\
Attach this home before patching/reporting patch level, e.g.:<br/>\
<code>$home/oui/bin/runInstaller -silent -attachHome ORACLE_HOME=$home ORACLE_HOME_NAME=&lt;name&gt;</code><br/>\
Raw opatch output:<br/>$(printf '%s\n' "$output" | sed 's/$/<br\/>/')"
                    ;;
                *)
                    # Inventory unreadable
                    echo "opatch lspatches failed for $home with RC=28 and central inventory could not be read.<br/>\
Check /etc/oraInst.loc and inventory.xml, then re-run opatch.<br/>\
Raw opatch output:<br/>$(printf '%s\n' "$output" | sed 's/$/<br\/>/')"
                    ;;
            esac
        else
            # Generic failure
            echo "opatch lspatches failed for $home (RC=$rc). Raw output:<br/>$(printf '%s\n' "$output" | sed 's/$/<br\/>/')"
        fi
        return 0
    fi

    # Success path: strip the "OPatch succeeded." footer and HTML-format
    output=$(printf '%s\n' "$output" | sed '/^OPatch succeeded\./d')
    if [[ -z "$output" ]]; then
        echo "No patches reported by opatch lspatches (likely base release only)."
    else
        output=$(printf '%s\n' "$output" | sed 's/$/<br\/>/')
        echo "$output"
    fi
}
apply_ojvm_on_db_install_if_enabled() {
    if [[ "${APPLY_OJVM_ON_DB_INSTALL:-false}" != true ]]; then
        add_html_row "OJVM patch (DB install)" "INFO" \
            "APPLY_OJVM_ON_DB_INSTALL=false ? OJVM not applied via opatch."
        return 0
    fi

    if [[ -z "${OJVM_PATCH_DIR:-}" || ! -d "$OJVM_PATCH_DIR" ]]; then
        add_html_row "OJVM patch (DB install)" "WARN" \
            "APPLY_OJVM_ON_DB_INSTALL=true but OJVM_PATCH_DIR ($OJVM_PATCH_DIR) not found ? OJVM not applied."
        return 0
    fi

    local ojvm_log="${LOG_DIR}/db_ojvm_install_$(date +%F_%H%M%S).log"
    add_attachment "$ojvm_log"

    if [[ "$DRYRUN" == true ]]; then
        log "[DRYRUN] Would apply OJVM patch from $OJVM_PATCH_DIR to $NEW_DB_HOME"
        add_html_row "OJVM patch (DB install)" "INFO" \
            "DRYRUN ? would apply OJVM from $OJVM_PATCH_DIR to $NEW_DB_HOME (log: $ojvm_log)"
        return 0
    fi

    log "Applying OJVM patch from $OJVM_PATCH_DIR to $NEW_DB_HOME (log: $ojvm_log)"

    run_cmd_allow_fail "sudo -u \"$ORACLE_USER\" bash -c 'cd \"$OJVM_PATCH_DIR\" && \
        ORACLE_HOME=\"$NEW_DB_HOME\" PATH=\"$NEW_DB_HOME/OPatch:$NEW_DB_HOME/bin:\$PATH\" \
        \"$NEW_DB_HOME/OPatch/opatch\" apply -silent -oh \"$NEW_DB_HOME\" -local' &> \"$ojvm_log\""

    if grep -qi 'OPatch succeeded.' "$ojvm_log" 2>/dev/null; then
        add_html_row "OJVM patch (DB install)" "PASS" \
            "OJVM patch applied to $NEW_DB_HOME. See $ojvm_log"
    else
        add_html_row "OJVM patch (DB install)" "WARN" \
            "OJVM patch may not have applied cleanly to $NEW_DB_HOME. Review $ojvm_log"
    fi
}
# ------------------------------------------------------------
# CVU CONFIG
# ------------------------------------------------------------
ensure_cvu_config_ol7() {
    local home="$1"
    local cv_file="${home}/cv/admin/cvu_config"
    if [[ -f "$cv_file" ]]; then
        run_cmd_allow_fail "cp -p \"$cv_file\" \"${cv_file}.bak_$(date +%s)\""
        run_cmd_allow_fail \
            "sed -i 's|^#*CV_ASSUME_DISTID=.*|CV_ASSUME_DISTID=OL7|' \"$cv_file\""
        add_html_row "Update CV_ASSUME_DISTID" "PASS" \
            "Attempted to set CV_ASSUME_DISTID=OL7 in ${cv_file} (best-effort)."
    else
        add_html_row "Update CV_ASSUME_DISTID" "WARN" \
            "File ${cv_file} not present yet in ${home}"
    fi
}
# ------------------------------------------------------------
# SRVCTL INITIALISATION + DB-ONLY MODE AUTO-DETECTION
# ------------------------------------------------------------
DB_ONLY_MODE=false

init_srvctl() {
    SRVCTL_BIN=""

    # Try GI homes first — these are the real srvctl
    if [[ -x "$OLD_GI_HOME/bin/srvctl" ]]; then
        SRVCTL_BIN="$OLD_GI_HOME/bin/srvctl"
    elif [[ -x "$NEW_GI_HOME/bin/srvctl" ]]; then
        SRVCTL_BIN="$NEW_GI_HOME/bin/srvctl"
    fi

    # If found in GI home, verify it actually works
    if [[ -n "$SRVCTL_BIN" ]]; then
        if "$SRVCTL_BIN" config database >/dev/null 2>&1; then
            DB_ONLY_MODE=false
            return 0
        else
            log "WARN: srvctl found at $SRVCTL_BIN but 'srvctl config database' failed — CRS/HAS may not be running."
            SRVCTL_BIN=""
        fi
    fi

    # Check for running ASM — definitive proof of GI
    if ps -eo args 2>/dev/null | grep -q '[p]mon_+ASM'; then
        DB_ONLY_MODE=false
        log "WARN: ASM detected but srvctl not functional. RAC operations may fail."
        return 0
    fi

    # Check for running CRS/HAS
    local has_gi=false
    if [[ -d "$OLD_GI_HOME" && -x "$OLD_GI_HOME/bin/crsctl" ]]; then
        if "$OLD_GI_HOME/bin/crsctl" check crs >/dev/null 2>&1 || \
           "$OLD_GI_HOME/bin/crsctl" check has >/dev/null 2>&1; then
            has_gi=true
        fi
    fi

    if [[ "$has_gi" == true ]]; then
        DB_ONLY_MODE=false
        log "WARN: CRS/HAS detected but srvctl not available."
    else
        DB_ONLY_MODE=true
        log "INFO: DB_ONLY_MODE auto-detected (no GI, no ASM, no functional srvctl). DB switch/rollback will use SQL*Plus."
    fi
}
# ------------------------------------------------------------
# COMMON PRECHECKS (text) + CVU
# ------------------------------------------------------------
check_space() {
    local fs="$1" min="$2"
    local free
    free=$(df -BG "$fs" | awk 'NR==2{gsub("G","",$4);print $4}')
    if (( free >= min )); then
        add_report_step "Space check $fs" "PASS" "${free}GB free (>=${min}GB)"
    else
        add_report_step "Space check $fs" "FAIL" "${free}GB free (<${min}GB)"
    fi
}
check_gi_cvu_preinstall() {
    local home="$1"
    local mode="$2"
    local cvulog="${LOG_DIR}/gi_cvu_${mode}_$(date +%F_%H%M%S).log"
    if [[ "$mode" == "CRS" ]]; then
        if [[ -x "$home/runcluvfy.sh" ]]; then
            run_cmd "\"$home/runcluvfy.sh\" stage -pre crsinst -n $(hostname -s) > \"$cvulog\" 2>&1 || true"
            add_html_attachment "$cvulog" "GI CVU Precheck (CRS)"
            log_file_content "$cvulog" "GI: CVU precheck CRS"
            if grep -qi "FAILED" "$cvulog" 2>/dev/null; then
                add_html_row "GI CVU precheck (CRS)" "FAIL" \
                    "runcluvfy.sh stage -pre crsinst reported failures. See $cvulog"
            else
                add_html_row "GI CVU precheck (CRS)" "PASS" \
                    "runcluvfy.sh stage -pre crsinst completed. See $cvulog"
            fi
        else
            add_html_row "GI CVU precheck (CRS)" "WARN" \
                "runcluvfy.sh not found in $home; CRS CVU pre-crsinst skipped."
        fi
    elif [[ "$mode" == "HAS" ]]; then
        if [[ -x "$home/bin/cluvfy" ]]; then
            run_cmd "\"$home/bin/cluvfy\" stage -pre hacfg -verbose > \"$cvulog\" 2>&1 || true"
            add_html_attachment "$cvulog" "GI CVU Precheck (HAS)"
            log_file_content "$cvulog" "GI: CVU precheck HAS"
            if grep -qi "FAILED" "$cvulog" 2>/dev/null; then
                add_html_row "GI CVU precheck (HAS)" "FAIL" \
                    "cluvfy stage -pre hacfg reported failures. See $cvulog"
            else
                add_html_row "GI CVU precheck (HAS)" "PASS" \
                    "cluvfy stage -pre hacfg completed. See $cvulog"
            fi
        else
            add_html_row "GI CVU precheck (HAS)" "WARN" \
                "cluvfy not found in $home/bin; HAS CVU pre-hacfg skipped."
        fi
    else
        add_html_row "GI CVU precheck" "INFO" \
            "GI cluster mode is UNKNOWN; skipping automated GI CVU precheck."
    fi
}
# ------------------------------------------------------------
# GI PATCH INVENTORY
# ------------------------------------------------------------
collect_lspatches() {
    local old_home="$1"
    local new_home="$2"
    local label="$3"
    if [[ -x "$old_home/OPatch/opatch" ]]; then
        local old_out="${LOG_DIR}/lspatches_old_${label}_$(date +%F_%H%M%S).log"
        run_cmd "sudo -u ${GRID_USER} ORACLE_HOME=\"$old_home\" PATH=\"$old_home/OPatch:$old_home/bin:\$PATH\" \"$old_home/OPatch/opatch\" lspatches > \"$old_out\" 2>&1 || true"
        add_report_step "lspatches OLD_GI_HOME ($label)" "INFO" "$old_out"
    else
        add_report_step "lspatches OLD_GI_HOME ($label)" "WARN" "opatch not found in $old_home"
    fi
    if [[ -x "$new_home/OPatch/opatch" ]]; then
        local new_out="${LOG_DIR}/lspatches_new_${label}_$(date +%F_%H%M%S).log"
        run_cmd "sudo -u ${GRID_USER} ORACLE_HOME=\"$new_home\" PATH=\"$new_home/OPatch:$new_home/bin:\$PATH\" \"$new_home/OPatch/opatch\" lspatches > \"$new_out\" 2>&1 || true"
        add_report_step "lspatches NEW_GI_HOME ($label)" "INFO" "$new_out"
    else
        add_report_step "lspatches NEW_GI_HOME ($label)" "WARN" "opatch not found in $new_home"
    fi
}
# ------------------------------------------------------------
# DB FILES + DB DISCOVERY
# ------------------------------------------------------------
DB_FILES=()
DB_UNIQUES=()
DB_UNIQUE_NAME=""
discover_db_files() {
    DB_FILES=()
    for f in \
        "$OLD_DB_HOME/network/admin/tnsnames.ora" \
        "$OLD_DB_HOME/network/admin/sqlnet.ora" \
        "$OLD_DB_HOME/network/admin/listener.ora" \
        "$OLD_DB_HOME/dbs"/spfile*.ora \
		"$OLD_DB_HOME/dbs"/orapw* \
        "$OLD_DB_HOME/dbs"/init*.ora
    do
        [[ -f "$f" ]] && DB_FILES+=("$f")
    done
    if [[ ${#DB_FILES[@]} > 0 ]]; then
        add_report_step "DB files discovered" "INFO" "$(printf "%s," "${DB_FILES[@]}")"
    else
        add_report_step "DB files discovered" "INFO" "No DB home files discovered under $OLD_DB_HOME."
    fi
}
copy_db_files() {
    for f in "${DB_FILES[@]}"; do
        # Preserve the subdirectory structure (dbs/, network/admin/)
        local relpath="${f#$OLD_DB_HOME/}"
        local dest="$NEW_DB_HOME/$relpath"
        local dest_dir
        dest_dir=$(dirname "$dest")
        if [[ -d "$dest_dir" && ! -f "$dest" ]]; then
            run_cmd_allow_fail "cp -p \"$f\" \"$dest\""
        fi
    done
}
discover_databases() {
    DB_UNIQUES=()

    # ----------------------------------------------------------
    # Path 1: srvctl present -> use srvctl config
    # ----------------------------------------------------------
    local srvctl_dbs=()
    if [[ -n "$SRVCTL_BIN" ]]; then
        local gi_home_for_srvctl
        gi_home_for_srvctl="$(cd "$(dirname "$SRVCTL_BIN")/.." && pwd 2>/dev/null || echo "")"
        log "INFO: discover_databases: using SRVCTL_BIN=$SRVCTL_BIN with ORACLE_HOME=$gi_home_for_srvctl"

        local srvctl_out
        srvctl_out=$(ORACLE_HOME="$gi_home_for_srvctl" "$SRVCTL_BIN" config 2>&1 || true)

        log "INFO: discover_databases: srvctl config output:"
        while IFS= read -r line; do
            log "INFO:   $line"
        done <<< "$srvctl_out"

        local srvctl_db_lines
        srvctl_db_lines="$(printf '%s\n' "$srvctl_out" | awk -F': *' '/^[[:space:]]*Database unique name:/ {print $2}' || true)"

        while IFS= read -r db; do
            db=$(echo "$db" | xargs)
            [[ -z "$db" ]] && continue
            srvctl_dbs+=( "$db" )
        done <<< "$srvctl_db_lines"

        if [[ ${#srvctl_dbs[@]} -eq 0 ]]; then
            while IFS= read -r db; do
                db=$(echo "$db" | xargs)
                [[ -z "$db" ]] && continue
                case "$db" in
                    PRC*|PRCR-*|Usage:*|"ORACLE_HOME environment variable is not set")
                        continue
                        ;;
                esac
                srvctl_dbs+=( "$db" )
            done <<< "$srvctl_out"
        fi

        if [[ ${#srvctl_dbs[@]} -eq 0 ]]; then
            log "INFO: discover_databases: no DBs from srvctl; will rely on PMON discovery."
        fi
    fi

    if [[ ${#srvctl_dbs[@]} -gt 0 ]]; then
        DB_UNIQUES=( "${srvctl_dbs[@]}" )
    fi

    # ----------------------------------------------------------
    # Path 2: PMON-based discovery -> add anything not in srvctl
    # ----------------------------------------------------------
    DB_NAME_TO_SID_MAP=""
    local pmon
    pmon=$(ps -eo args | awk -F'pmon_' '/pmon_/ {print $2}' | sed 's/ .*$//' | sort -u || true)

    if [[ -n "$pmon" ]]; then
        while read -r sid; do
            [[ -z "$sid" || "$sid" == +ASM* ]] && continue

            # Skip if srvctl already has exactly this name
            local already=false
            if [[ ${#DB_UNIQUES[@]} -gt 0 ]]; then
                local existing
                for existing in "${DB_UNIQUES[@]}"; do
                    if [[ "$existing" == "$sid" ]]; then
                        already=true
                        break
                    fi
                done
            fi
            if [[ "$already" == true ]]; then
                continue
            fi

            # Determine ORACLE_HOME from PMON PID
            local sid_home
            sid_home=$(get_home_from_pmon_sid "$sid")

            if [[ -z "$sid_home" || ! -x "$sid_home/bin/sqlplus" ]]; then
                log "INFO: discover_databases: could not determine valid ORACLE_HOME for non-srvctl SID '$sid' (home='$sid_home'); treating SID as non-srvctl DB."
                DB_UNIQUES+=( "$sid" )
                DB_NAME_TO_SID_MAP+="${DB_NAME_TO_SID_MAP:+ }${sid}=${sid}"
                continue
            fi

        local db_name raw
        raw=$(
            sudo -u "$ORACLE_USER" bash -c "
                ORACLE_HOME=\"$sid_home\"
                ORACLE_SID=\"$sid\"
                PATH=\"$sid_home/bin:\$PATH\"
                \"$sid_home/bin/sqlplus\" -s / as sysdba 2>&1 <<'EOF'
set heading off feedback off pages 0 verify off echo off termout off
whenever sqlerror exit 1
select name from v\$database;
exit
EOF
                "
        ) || true

        # Strip CRs and blank lines, then drop obvious SQL*Plus noise and errors
        db_name=$(
            printf '%s\n' "$raw" \
            | tr -d '\r' \
            | sed '/^[[:space:]]*$/d' \
            | grep -Ev '^(SQL\*Plus|Copyright|(Connected to)|(Disconnected from)|ERROR:|ORA-|SP2-|SP-)[[:space:]]' \
            | sed -n '1p' \
            | xargs
        )

        # If we still don't have a sane name, fall back to SID
        # and DO NOT let error banners like "Error 6 initializing SQL*Plus" through.
        if [[ -z "$db_name" ]]; then
            local first_line="${raw%%$'\n'*}"
            log "INFO: discover_databases: sqlplus lookup for non-srvctl SID '$sid' (home '$sid_home') did not return a valid DB name (first_line='${first_line}'); treating SID '$sid' as DB name."
            DB_UNIQUES+=( "$sid" )
            DB_NAME_TO_SID_MAP+="${DB_NAME_TO_SID_MAP:+ }${sid}=${sid}"
            continue
        fi

        log "INFO: discover_databases: PMON SID '$sid' (home '$sid_home') -> DB name '$db_name'"

            already=false
            if [[ ${#DB_UNIQUES[@]} -gt 0 ]]; then
                local existing2
                for existing2 in "${DB_UNIQUES[@]}"; do
                    if [[ "$existing2" == "$db_name" ]]; then
                        already=true
                        break
                    fi
                done
            fi
            if [[ "$already" != true ]]; then
                DB_UNIQUES+=( "$db_name" )
            fi
            DB_NAME_TO_SID_MAP+="${DB_NAME_TO_SID_MAP:+ }${db_name}=${sid}"
        done <<< "$pmon"
    else
        log "INFO: discover_databases: no PMON processes found."
    fi

    # ----------------------------------------------------------
    # Filter out ASM/junk + dedupe case-insensitively
    # ----------------------------------------------------------
    if [[ ${#DB_UNIQUES[@]} -gt 0 ]]; then
        local filtered=()
        local seen_lc=()
        local db db_lc
        for db in "${DB_UNIQUES[@]}"; do
            if [[ "$db" == +ASM* ]]; then
                continue
            fi
            if [[ "$db" =~ [[:space:]] || "$db" == '`' || "$db" == "/" ]]; then
                log "INFO: Skipping non-DB string from discovery: '$db'"
                continue
            fi
            db_lc=$(echo "$db" | tr '[:upper:]' '[:lower:]')
            local seen already=false
            for seen in "${seen_lc[@]}"; do
                if [[ "$seen" == "$db_lc" ]]; then
                    already=true
                    break
                fi
            done
            if [[ "$already" == true ]]; then
                log "INFO: discover_databases: skipping duplicate DB name '$db' (case-insensitive match)."
                continue
            fi
            seen_lc+=( "$db_lc" )
            filtered+=( "$db" )
        done
        DB_UNIQUES=( "${filtered[@]}" )
    fi

    log "INFO: discover_databases: final DB_UNIQUES=(${DB_UNIQUES[*]})"
}
get_db_type() {
    local db="$1"
    local t=""
    if [[ -n "$SRVCTL_BIN" ]]; then
        # srvctl needs ORACLE_HOME pointing at the GI home to resolve its libraries
        t=$(ORACLE_HOME="${OLD_GI_HOME:-}" "$SRVCTL_BIN" config database -d "$db" 2>/dev/null \
            | awk -F: '/^Type/{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' || true)
    fi
    # Fallback: if srvctl unavailable or returned empty, check cluster_database parameter
    # via sqlplus on the SID that maps to this db name.
    if [[ -z "$t" ]]; then
        local _sid _home _cdb
        _sid=$(get_db_sid "$db")
        _home=$(get_db_home "$db")
        if [[ -n "$_sid" && -n "$_home" && -x "$_home/bin/sqlplus" ]]; then
            _cdb=$(sudo -u "${ORACLE_USER:-oracle}" bash -c "
                export ORACLE_HOME=\"$_home\"
                export ORACLE_SID=\"$_sid\"
                export PATH=\"$_home/bin:\$PATH\"
                export LD_LIBRARY_PATH=\"$_home/lib:\${LD_LIBRARY_PATH:-}\"
                \"$_home/bin/sqlplus\" -s / as sysdba 2>/dev/null <<'EOF'
set heading off feedback off pages 0 verify off echo off termout off
select value from v\$parameter where name='cluster_database';
exit
EOF
            " 2>/dev/null) || true
            _cdb=$(printf '%s\n' "$_cdb" | grep -Ei '^true$|^false$' | head -1 | tr '[:lower:]' '[:upper:]')
            if [[ "$_cdb" == "TRUE" ]]; then
                t="RAC ONE NODE"
            fi
        fi
    fi
    echo "$t"
}
get_db_home() {
    local db="$1"
    local sid home

    # 1) Prefer DB->SID mapping discovered earlier
    #    (DB_NAME_TO_SID_MAP built by discover_databases)
    sid="$(get_sid_for_db_name "$db")"

    # 2) First try to derive home from PMON SID via /proc
    home="$(get_home_from_pmon_sid "$sid")"

    # 3) Fallback: derive ORACLE_HOME from /etc/oratab (if SID is in oratab)
    if [[ -z "$home" && -f "$ORATAB_FILE" ]]; then
        home=$(awk -F: -v s="$sid" 'NF>=2 && $1==s {print $2; exit}' "$ORATAB_FILE")
    fi

    echo "$home"
}
get_db_sid() {
    local db="$1"
    local sid=""
    if [[ -n "$SRVCTL_BIN" ]]; then
        sid=$("$SRVCTL_BIN" status database -d "$db" 2>/dev/null | \
              awk '/Instance/ {print $2; exit}' || true)
    fi
    if [[ -z "$sid" ]]; then
        # Case-insensitive match: Oracle SIDs on Linux are lowercase in pmon
        # but DB_UNIQUE_NAME from v$database is uppercase. Compare via tolower().
        # Also handle RAC instance suffix: unique_name=sretest → SID=sretest_1
        local db_lower db_no_underscore
        db_lower=$(echo "$db" | tr '[:upper:]' '[:lower:]')
        db_no_underscore="${db_lower//_/}"
        sid=$(ps -eo args | awk -F'pmon_' '/pmon_/ {print $2}' | sed 's/ .*$//' | \
              awk -v d="$db_lower" -v d2="$db_no_underscore" '
                    { l=tolower($0) }
                    l == d  { print $0; exit }
                    l == d2 { print $0; exit }
                    # RAC instance suffix: sretest_1, sretest_2 etc.
                    (index(l, d "_") == 1 && substr(l, length(d)+2) ~ /^[0-9]+$/) { print $0; exit }
              ' || true)
    fi
    echo "$sid"
}
get_sid_for_db_name() {
    local db_name="$1"
    local pair name sid

    for pair in $DB_NAME_TO_SID_MAP; do
        name="${pair%%=*}"
        sid="${pair#*=}"
        if [[ "$name" == "$db_name" ]]; then
            echo "$sid"
            return 0
        fi
    done

    # Fallback: if not in map, assume SID = name
    echo "$db_name"
}

cluster_get_sids_for_db_name() {
    local db_name="$1"
    local pair name sid guessed
    local found=()
    local p_sids=""

    for pair in $DB_NAME_TO_SID_MAP; do
        name="${pair%%=*}"
        sid="${pair#*=}"
        if [[ "$name" == "$db_name" && -n "$sid" ]]; then
            if ! printf '%s
' "${found[@]}" | grep -Fxq "$sid" 2>/dev/null; then
                found+=("$sid")
            fi
        fi
    done

    p_sids=$(cluster_local_pmon_sids)

    if echo "$p_sids" | grep -qx "$db_name" 2>/dev/null; then
        if ! printf '%s
' "${found[@]}" | grep -Fxq "$db_name" 2>/dev/null; then
            found+=("$db_name")
        fi
    fi

    if [[ "$db_name" =~ ^(.+)_([0-9]+)$ ]]; then
        guessed="$db_name"
    else
        guessed="${db_name}_1"
    fi
    if echo "$p_sids" | grep -qx "$guessed" 2>/dev/null; then
        if ! printf '%s
' "${found[@]}" | grep -Fxq "$guessed" 2>/dev/null; then
            found+=("$guessed")
        fi
    fi

    if (( ${#found[@]} == 0 )); then
        echo "$db_name"
    else
        printf '%s
' "${found[@]}"
    fi
}
get_db_open_mode() {
    local db="$1" home="$2"
    local sid
    sid=$(get_db_sid "$db")
    if [[ -z "$sid" ]]; then
        echo "UNKNOWN (no running instance)"
        return 0
    fi

    # Derive ORACLE_HOME if not passed or invalid
    if [[ -z "$home" || ! -x "$home/bin/sqlplus" ]]; then
        home=$(get_db_home "$db")
    fi
    if [[ -z "$home" || ! -x "$home/bin/sqlplus" ]]; then
        echo "UNKNOWN (invalid ORACLE_HOME: ${home:-unset})"
        return 0
    fi

    local out line mode="UNKNOWN"

    # Always run as ORACLE_USER (oracle), not root
    out=$(
        sudo -u "$ORACLE_USER" bash -c "
            ORACLE_HOME=\"$home\"
            ORACLE_SID=\"$sid\"
            PATH=\"$home/bin:\$PATH\"
            \"$home/bin/sqlplus\" -s / as sysdba 2>&1 <<'EOF'
set heading off feedback off pages 0 verify off echo off termout off
whenever sqlerror exit 1
select open_mode from v\$database;
exit
EOF
        "
    ) || true

    # Parse output: skip SQL*Plus banners and obvious errors
    while IFS= read -r line; do
        line=$(echo "$line" | tr -d $'\r' | xargs)
        [[ -z "$line" ]] && continue

        case "$line" in
            SQL\*Plus*|Connected\ to*|Disconnected\ from*|ERROR:*|ORA-*|SP2-* )
                continue
                ;;
        esac

        case "$line" in
            "READ WRITE"|"MOUNTED"|"READ ONLY"|"MIGRATE"|"MOUNTED (STANDBY)")
                mode="$line"
                break
                ;;
            *)
                if [[ "$line" =~ ^[A-Z_]+( [A-Z_]+)*$ ]]; then
                    mode="$line"
                    break
                fi
                ;;
        esac
    done <<< "$out"

    if [[ "$mode" == "UNKNOWN" ]]; then
        # Log first line and full output to help debug env issues
        local first_line="${out%%$'\n'*}"
        log "INFO: get_db_open_mode: unable to derive open_mode for db='$db', sid='$sid', home='$home'. First line: '$first_line'"
        log "INFO: get_db_open_mode: full sqlplus output for db='$db', sid='$sid':"
        while IFS= read -r line; do
            log "INFO:   $line"
        done <<< "$out"
        echo "UNKNOWN (SQL*Plus error)"
    else
        echo "$mode"
    fi
}
get_db_role_and_mode() {
    local db="$1" home="$2"
    local sid
    sid=$(get_db_sid "$db")
    if [[ -z "$sid" ]]; then
        echo "UNKNOWN|UNKNOWN (no running instance)"
        return 0
    fi

    if [[ -z "$home" || ! -x "$home/bin/sqlplus" ]]; then
        home=$(get_db_home "$db")
    fi
    if [[ -z "$home" || ! -x "$home/bin/sqlplus" ]]; then
        echo "UNKNOWN|UNKNOWN (invalid ORACLE_HOME)"
        return 0
    fi

    local out=""
    out=$(
        sudo -u "$ORACLE_USER" bash -c "
            export ORACLE_HOME=\"$home\"
            export ORACLE_SID=\"$sid\"
            export PATH=\"$home/bin:\$PATH\"
            export LD_LIBRARY_PATH=\"$home/lib:\${LD_LIBRARY_PATH:-}\"
            \"$home/bin/sqlplus\" -s / as sysdba 2>&1 <<'SQEOF'
set heading off feedback off pages 0 verify off echo off termout off
select database_role || '|' || open_mode from v\$database;
exit
SQEOF
        "
    ) || true

    out=$(printf '%s\n' "$out" | tr -d '\r' | grep -v '^SQL\*Plus\|^Connected\|^ERROR:\|^ORA-\|^SP2-' | sed '/^[[:space:]]*$/d' | sed -n '1p')
    [[ -z "$out" ]] && out="UNKNOWN|UNKNOWN"
    echo "$out"
}
wait_for_db_ready_state() {
    local db="$1" home="$2"
    local sid=""
    local timeout=600
    local interval=15
    local elapsed=0

    log "Waiting for instance SID for $db to appear (up to ${timeout}s total)..."
    while (( elapsed < timeout )); do
        sid=$(get_db_sid "$db")
        if [[ -n "$sid" ]]; then
            log "Detected running instance for $db: SID='$sid'"
            break
        fi
        sleep "$interval"
        elapsed=$(( elapsed + interval ))
    done

    if [[ -z "$sid" ]]; then
        log "WARN: No running instance found for $db within ${timeout}s; cannot wait for usable state."
        return 1
    fi

    if [[ -z "$home" || ! -x "$home/bin/sqlplus" ]]; then
        home=$(get_db_home "$db")
    fi
    if [[ -z "$home" || ! -x "$home/bin/sqlplus" ]]; then
        log "WARN: wait_for_db_ready_state: invalid ORACLE_HOME '${home:-unset}' for $db (SID $sid)."
        return 1
    fi

    log "Waiting for $db (SID $sid) to reach target state (PRIMARY=READ WRITE, STANDBY=MOUNTED/READ ONLY) with remaining timeout ~$((timeout - elapsed))s..."
    while (( elapsed < timeout )); do
        local rm="" role="" mode=""

        rm=$(
            sudo -u "$ORACLE_USER" bash -c "
                export ORACLE_HOME=\"$home\"
                export ORACLE_SID=\"$sid\"
                export PATH=\"$home/bin:\$PATH\"
                export LD_LIBRARY_PATH=\"$home/lib:\${LD_LIBRARY_PATH:-}\"
                \"$home/bin/sqlplus\" -s / as sysdba 2>&1 <<'SQEOF'
set heading off feedback off pages 0 verify off echo off termout off
select database_role || '|' || open_mode from v\$database;
exit
SQEOF
            "
        ) || true

        rm=$(printf '%s\n' "$rm" | tr -d '\r' | sed '/^[[:space:]]*$/d' | grep -v '^SQL\*Plus\|^Connected\|^ERROR:\|^ORA-\|^SP2-' | sed -n '1p')

        if [[ -n "$rm" ]]; then
            role=${rm%%|*}
            mode=${rm#*|}
            role=$(echo "$role" | xargs)
            mode=$(echo "$mode" | xargs)
        else
            role="UNKNOWN"
            mode="UNKNOWN"
        fi

        log "Current role/mode for $db (SID $sid): role='${role}', open_mode='${mode}'"

        if [[ "$role" == "PRIMARY" && "$mode" == "READ WRITE" ]]; then
            DB_LAST_ROLE="$role"
            DB_LAST_MODE="$mode"
            log "Database $db is PRIMARY and OPEN READ WRITE."
            return 0
        fi

        if [[ "$role" == "PHYSICAL STANDBY" ]] && { [[ "$mode" == "MOUNTED" ]] || [[ "$mode" == "READ ONLY" ]]; }; then
            DB_LAST_ROLE="$role"
            DB_LAST_MODE="$mode"
            log "Database $db is PHYSICAL STANDBY and in acceptable mode '$mode'."
            return 0
        fi

        if [[ "$role" == "LOGICAL STANDBY" && "$mode" == "READ ONLY" ]]; then
            DB_LAST_ROLE="$role"
            DB_LAST_MODE="$mode"
            log "Database $db is LOGICAL STANDBY and OPEN READ ONLY."
            return 0
        fi

        sleep "$interval"
        elapsed=$(( elapsed + interval ))
    done

    log "WARN: Timed out waiting for $db (SID $sid) to reach PRIMARY/READ WRITE or STANDBY/MOUNTED/READ ONLY state."
    return 1
}

wait_for_db_open_readwrite() {
    wait_for_db_ready_state "$@"
}
list_open_pdbs() {
    local db="$1"
    local home="$2"
    local sid

    sid=$(get_db_sid "$db")
    [[ -z "$sid" ]] && { echo ""; return 0; }

    if [[ -z "$home" || ! -x "$home/bin/sqlplus" ]]; then
        home=$(get_db_home "$db")
    fi
    [[ -z "$home" || ! -x "$home/bin/sqlplus" ]] && { echo ""; return 0; }

    local pdbs=""
    pdbs=$(
        sudo -u "$ORACLE_USER" bash -c "
            export ORACLE_HOME=\"$home\"
            export ORACLE_SID=\"$sid\"
            export PATH=\"$home/bin:\$PATH\"
            export LD_LIBRARY_PATH=\"$home/lib:\${LD_LIBRARY_PATH:-}\"
            \"$home/bin/sqlplus\" -s / as sysdba 2>&1 <<'SQEOF'
set heading off feedback off pages 0 verify off echo off termout off
whenever sqlerror exit 1
select name || ' (' || open_mode || ')' from v\$pdbs order by 1;
exit
SQEOF
        "
    ) || true

    pdbs=$(printf '%s\n' "$pdbs" | tr -d '\r' | \
           grep -v '^SQL\*Plus\|^Connected\|^ERROR:\|^ORA-\|^SP2-' | \
           sed '/^[[:space:]]*$/d')

    echo "$pdbs"
}
prompt_for_db_unique() {
    discover_databases
    if [[ ${#DB_UNIQUES[@]} -eq 0 ]]; then
        echo "No databases discovered via srvctl or PMON."
        read -rp "Enter DB UNIQUE NAME manually: " DB_UNIQUE_NAME
        return
    fi
    echo "Discovered databases on this host:"
    local i=1
    for db in "${DB_UNIQUES[@]}"; do
        local t
        t=$(get_db_type "$db")
        if [[ -z "$t" ]]; then
            local gi_mode
            gi_mode=$(detect_gi_cluster_mode)
            if [[ "$gi_mode" == "HAS" ]]; then
                t="SINGLE INSTANCE"
            fi
        fi
        echo "  $i) $db (Type: ${t:-UNKNOWN})"
        ((i++))
    done
    echo "  m) Manual entry"
    while true; do
        read -rp "Select database [1-${#DB_UNIQUES[@]} or m]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#DB_UNIQUES[@]} )); then
            DB_UNIQUE_NAME="${DB_UNIQUES[choice-1]}"
            log "Selected DB UNIQUE NAME: $DB_UNIQUE_NAME"
            break
        elif [[ "$choice" =~ ^[mM]$ ]]; then
            read -rp "Enter DB UNIQUE NAME: " DB_UNIQUE_NAME
            log "Manual DB UNIQUE NAME entered: $DB_UNIQUE_NAME"
            break
        else
            echo "Invalid selection."
        fi
    done
}
get_home_from_pmon_sid() {
    local sid="$1"
    local home=""
    local pids

    pids=$(pgrep -f "pmon_${sid}" || true)
    if [[ -n "$pids" ]]; then
        while read -r pid; do
            [[ -z "$pid" ]] && continue
            if [[ -L "/proc/$pid/exe" ]]; then
                home=$(readlink -f "/proc/$pid/exe" 2>/dev/null | sed 's|/bin/oracle$||')
                [[ -n "$home" ]] && break
            fi
        done <<< "$pids"
    fi

    echo "$home"
}

get_node_role() {
    if [[ -f /etc/oracle-node-role ]]; then
        tr '[:lower:]' '[:upper:]' < /etc/oracle-node-role | xargs
    else
        echo "UNKNOWN"
    fi
}
# Ensure Insight shutdown/startup scripts are in /etc/patching with correct names/permissions.
# It will try to FIND them anywhere under common script roots if missing.
ensure_insight_scripts_present_html() {
    local ok=true

    # Expected target locations
    local target_home="/etc/patching"
    local target_shutdown="${target_home}/shutdown.sh"
    local target_startup="${target_home}/startup.sh"

    # Ensure /home/oracle exists
    if [[ ! -d "$target_home" ]]; then
        mkdir -p "$target_home" 2>/dev/null || true
        chown "${ORACLE_USER:-oracle}:${OINSTALL:-oinstall}" "$target_home" 2>/dev/null || true
    fi

    # Common search roots – adjust to match where your scripts typically live
    local SEARCH_ROOTS=(
        /home/oracle
        /home/devadmin
        /staging
        /staging/scripts
        /opt
        /usr/local
    )

    # Helper: find first match by name under SEARCH_ROOTS
    _find_script_by_name() {
        local name="$1"
        local root
        for root in "${SEARCH_ROOTS[@]}"; do
            [[ -d "$root" ]] || continue
            local found
            found=$(find "$root" -maxdepth 5 -type f -name "$name" 2>/dev/null | head -n1 || true)
            if [[ -n "$found" ]]; then
                echo "$found"
                return 0
            fi
        done
        echo ""
        return 1
    }

    # ---------- Shutdown script ----------
    if [[ -x "$target_shutdown" ]]; then
        add_html_row "Insight shutdown script" "PASS" \
            "$target_shutdown is present and executable."
    else
        local cand
        cand=$(_find_script_by_name "shutdown.sh")
        if [[ -n "$cand" ]]; then
            mkdir -p "$target_home"
            cp -p "$cand" "$target_shutdown" 2>/dev/null || cp "$cand" "$target_shutdown"
            chown "${ORACLE_USER:-oracle}:${OINSTALL:-oinstall}" "$target_shutdown" 2>/dev/null || true
            chmod 750 "$target_shutdown" 2>/dev/null || chmod +x "$target_shutdown" 2>/dev/null || true

            if [[ -x "$target_shutdown" ]]; then
                add_html_row "Insight shutdown script" "PASS" \
                    "Found at <code>$cand</code> and copied to <code>$target_shutdown</code> (now executable)."
            else
                ok=false
                add_html_row "Insight shutdown script" "FAIL" \
                    "Found at <code>$cand</code> and copied to <code>$target_shutdown</code>, but target is not executable.<br/>\
Fix with:<br/><code>chown ${ORACLE_USER:-oracle}:${OINSTALL:-oinstall} $target_shutdown && chmod 750 $target_shutdown</code>"
            fi
        else
            ok=false
            add_html_row "Insight shutdown script" "FAIL" \
                "Could not find <code>insight_shutdown-osgidb.sh</code> under any search root.<br/>\
Expected at <code>$target_shutdown</code>.<br/>\
Copy your shutdown script there and make it executable."
        fi
    fi

    # ---------- Startup script ----------
    if [[ -x "$target_startup" ]]; then
        add_html_row "Insight startup script" "PASS" \
            "$target_startup is present and executable."
    else
        local cand2
        cand2=$(_find_script_by_name "startup.sh")
        if [[ -n "$cand2" ]]; then
            mkdir -p "$target_home"
            cp -p "$cand2" "$target_startup" 2>/dev/null || cp "$cand2" "$target_startup"
            chown "${ORACLE_USER:-oracle}:${OINSTALL:-oinstall}" "$target_startup" 2>/dev/null || true
            chmod 750 "$target_startup" 2>/dev/null || chmod +x "$target_startup" 2>/dev/null || true

            if [[ -x "$target_startup" ]]; then
                add_html_row "Insight startup script" "PASS" \
                    "Found at <code>$cand2</code> and copied to <code>$target_startup</code> (now executable)."
            else
                ok=false
                add_html_row "Insight startup script" "FAIL" \
                    "Found at <code>$cand2</code> and copied to <code>$target_startup</code>, but target is not executable.<br/>\
Fix with:<br/><code>chown ${ORACLE_USER:-oracle}:${OINSTALL:-oinstall} $target_startup && chmod 750 $target_startup</code>"
            fi
        else
            ok=false
            add_html_row "Insight startup script" "FAIL" \
                "Could not find <code>insight_startup-osgidb.sh</code> under any search root.<br/>\
Expected at <code>$target_startup</code>.<br/>\
Copy your startup script there and make it executable."
        fi
    fi

    $ok && return 0 || return 1
}
# ------------------------------------------------------------
# SOFTWARE STAGING FOR PRECHECKS (GI + DB)
# ------------------------------------------------------------
stage_gi_software_for_precheck() {
    local home="$1"
    if [[ -x "$home/gridSetup.sh" ]]; then
        return 0
    fi
    if [[ ! -f "$GI_BASE_ZIP" ]]; then
        add_html_row "GI precheck software staging" "WARN" \
            "GI_BASE_ZIP ($GI_BASE_ZIP) not found; cannot stage GI software into $home for executePrereqs."
        return 1
    fi
    add_html_row "GI precheck software staging" "INFO" \
        "Staging GI software from $GI_BASE_ZIP into $home for prechecks only (no actual install)."
    run_cmd "sudo mkdir -p \"$home\""
    run_cmd "sudo chown -R ${GRID_USER}:${OINSTALL} \"$home\""
    run_cmd "unzip -oq \"$GI_BASE_ZIP\" -d \"$home\""
    return 0
}
stage_db_software_for_precheck() {
    local home="$1"
    if [[ -x "$home/runInstaller" ]]; then
        return 0
    fi
    if [[ ! -f "$DB_BASE_ZIP" ]]; then
        add_html_row "DB precheck software staging" "WARN" \
            "DB_BASE_ZIP ($DB_BASE_ZIP) not found; cannot stage DB software into $home for executePrereqs."
        return 1
    fi
    add_html_row "DB precheck software staging" "INFO" \
        "Staging DB software from $DB_BASE_ZIP into $home for prechecks only (no actual install)."
    run_cmd "mkdir -p \"$home\""
    run_cmd "chown -R ${ORACLE_USER}:${OINSTALL} \"$home\""
    run_cmd "unzip -oq \"$DB_BASE_ZIP\" -d \"$home\""
    return 0
}
check_new_db_home_already_registered_html() {
    # If the NEW_DB_HOME directory does not exist at all, there's nothing to check.
    if [[ ! -d "$NEW_DB_HOME" ]]; then
        add_html_row "DB NEW_DB_HOME inventory status" "INFO" \
            "NEW_DB_HOME ($NEW_DB_HOME) does not exist yet on disk; no central inventory registration to check."
        return 0
    fi

    # Basic sanity: look for an Oracle home marker
    if [[ ! -x "$NEW_DB_HOME/bin/sqlplus" && ! -f "$NEW_DB_HOME/inventory/ContentsXML/comps.xml" ]]; then
        add_html_row "DB NEW_DB_HOME inventory status" "WARN" \
            "NEW_DB_HOME ($NEW_DB_HOME) exists but does not look like a valid Oracle home (sqlplus not found).<br/>\
            Please verify manually whether this path is safe to use as a new 19c home."
        return 0
    fi

    # Try to see if this home is already in the central inventory
    local inv_file="/etc/oraInst.loc"
    if [[ ! -f "$inv_file" ]]; then
        add_html_row "DB NEW_DB_HOME inventory status" "WARN" \
            "Central inventory locator $inv_file not found.<br/>\
            Cannot reliably check whether NEW_DB_HOME ($NEW_DB_HOME) is already registered.<br/>\
            If this home was previously used, manually confirm via runInstaller -silent -attachHome or detachHome as needed."
        return 0
    fi

    local central_inv
    central_inv=$(awk -F= '/inventory_loc/ {gsub(/[[:space:]]*/, "", $2); print $2}' "$inv_file")
    if [[ -z "$central_inv" || ! -d "$central_inv" ]]; then
        add_html_row "DB NEW_DB_HOME inventory status" "WARN" \
            "Central inventory path extracted from $inv_file is empty or invalid: '$central_inv'.<br/>\
            Cannot reliably check whether NEW_DB_HOME ($NEW_DB_HOME) is already registered."
        return 0
    fi

    local comps_xml="$central_inv/ContentsXML/comps.xml"
    if [[ ! -f "$comps_xml" ]]; then
        add_html_row "DB NEW_DB_HOME inventory status" "WARN" \
            "Central inventory components file $comps_xml not found.<br/>\
            Cannot reliably check whether NEW_DB_HOME ($NEW_DB_HOME) is already registered."
        return 0
    fi

    # Normalize path for matching
    local escaped_home
    escaped_home=$(printf '%s\n' "$NEW_DB_HOME" | sed 's/[.[\*^$(){}?+|/\\]/\\&/g')

    # Before reporting inventory status: check if any DB instance is actively running
    # from NEW_DB_HOME. If so, this is a HARD BLOCK — db_install must not proceed.
    local _inv_running_sids=()
    local _inv_sid
    while IFS= read -r _inv_sid; do
        local _inv_home
        _inv_home=$(get_home_from_pmon_sid "$_inv_sid" 2>/dev/null || true)
        [[ "$_inv_home" == "$NEW_DB_HOME" ]] && _inv_running_sids+=("$_inv_sid")
    done < <(ps -eo args 2>/dev/null | grep -oP '(?<=ora_pmon_)[A-Za-z0-9_]+' | grep -v '^\+' | grep -v 'MGMTDB' | sort -u)

    if (( ${#_inv_running_sids[@]} > 0 )); then
        add_html_row "DB NEW_DB_HOME inventory status" "FAIL" \
            "HARD BLOCK: Database instance(s) <b>${_inv_running_sids[*]}</b> are currently RUNNING from <code>$NEW_DB_HOME</code>.<br/>\
            This is your <b>current active DB home</b> — running db_install here would corrupt a live Oracle home.<br/>\
            <b>Action</b>: Run <code>db_rollback</code> first to return the database to <code>$OLD_DB_HOME</code>, then retry db_install."
        return 1
    fi

    if grep -qi "$escaped_home" "$comps_xml" 2>/dev/null; then
        # This is the precheck equivalent of INS-32826
        add_html_row "DB NEW_DB_HOME inventory status" "WARN" \
            "The software home <code>$NEW_DB_HOME</code> appears to already be registered in the central inventory.<br/>\
            This condition will typically trigger Oracle installer error <code>INS-32826</code>:<br/>\
            <code>The software home ($NEW_DB_HOME) is already registered in the central inventory. Refer to patch readme instructions on how to apply.</code><br/>\
            Action:<br/>\
            - Confirm whether this is an existing/previously-patched DB home that should not be reused as NEW_DB_HOME, or<br/>\
            - If you intend to reuse it, follow the relevant patch README for attachHome/detachHome steps before running db_install again."
    else
        add_html_row "DB NEW_DB_HOME inventory status" "INFO" \
            "NEW_DB_HOME ($NEW_DB_HOME) exists on disk and does not appear as a registered Oracle home in the central inventory.<br/>\
            No INS-32826 conflict expected from central inventory for this path."
    fi
}
stage_db_ojvm_oneoffs_for_install() {
    if [[ "${APPLY_OJVM_DURING_DB_INSTALL:-false}" != true ]]; then
        return 0
    fi
    if [[ -z "${OJVM_ZIP_DIR:-}" || ! -d "$OJVM_ZIP_DIR" ]]; then
        add_html_row "DB OJVM staging" "WARN" \
            "APPLY_OJVM_DURING_DB_INSTALL=true but OJVM_ZIP_DIR ($OJVM_ZIP_DIR) not found ? OJVM will not be applied by runInstaller."
        return 1
    fi
    mkdir -p "$OJVM_ONEOFF_DIR"
    shopt -s nullglob
    local zips=( "$OJVM_ZIP_DIR"/${OJVM_ZIP_PATTERN} )
    shopt -u nullglob
    if (( ${#zips[@]} == 0 )); then
        add_html_row "DB OJVM staging" "WARN" \
            "No OJVM zip(s) matching pattern '$OJVM_ZIP_PATTERN' found in $OJVM_ZIP_DIR ? OJVM will not be applied by runInstaller."
        return 1
    fi
    local zip="${zips[0]}"
    add_html_row "DB OJVM staging" "INFO" \
        "Staging DB OJVM from $zip into $OJVM_ONEOFF_DIR (for runInstaller -applyOneOffs)."
    run_cmd "unzip -oq \"$zip\" -d \"$OJVM_ONEOFF_DIR\""
    local patch_dir=""
    shopt -s nullglob
    local inner=( "$OJVM_ONEOFF_DIR"/* )
    shopt -u nullglob
    for d in "${inner[@]}"; do
        if [[ -d "$d" ]]; then
            patch_dir="$d"
            break
        fi
    done
    if [[ -n "$patch_dir" ]]; then
        OJVM_ONEOFF_DIR="$patch_dir"
        add_html_row "DB OJVM staging" "INFO" \
            "Using OJVM one-off directory $OJVM_ONEOFF_DIR for -applyOneOffs."
    else
        add_html_row "DB OJVM staging" "WARN" \
            "No inner patch directory found under $OJVM_ONEOFF_DIR; -applyOneOffs may fail."
    fi
    OJVM_PATCH_DIR="$OJVM_ONEOFF_DIR"
}
# ------------------------------------------------------------
# GI & DB INVENTORY / ATTACHMENT CHECK
# ------------------------------------------------------------
is_gi_home_attached() {
    local home="$1"
    local inv_root inv_file
    if [[ -f /etc/oraInst.loc ]]; then
        inv_root=$(awk -F= '/inventory_loc/ {gsub(/[[:space:]]*/, "", $2); print $2}' /etc/oraInst.loc)
    fi
    inv_file="${inv_root}/ContentsXML/inventory.xml"
    if [[ -z "$inv_root" || ! -f "$inv_file" ]]; then
        return 2
    fi
    if grep -q "LOC=\"${home}\"" "$inv_file" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

is_db_home_attached() {
    local home="$1"
    local inv_root inv_file
    if [[ -f /etc/oraInst.loc ]]; then
        inv_root=$(awk -F= '/inventory_loc/ {gsub(/[[:space:]]*/, "", $2); print $2}' /etc/oraInst.loc)
    fi
    inv_file="${inv_root}/ContentsXML/inventory.xml"
    if [[ -z "$inv_root" || ! -f "$inv_file" ]]; then
        return 2     # inventory not readable
    fi
    if grep -q "LOC=\"${home}\"" "$inv_file" 2>/dev/null; then
        return 0     # attached
    else
        return 1     # not attached
    fi
}
# ------------------------------------------------------------
# NEW: GENERIC OS OPERATIONS (PATCH + REBOOT)
# ------------------------------------------------------------
OS_PATCH_SCRIPT="${OS_PATCH_SCRIPT:-/usr/local/sbin/os_patch.sh}"
OS_PRECHECK_LOG="${LOG_DIR}/os_precheck_$(date +%F_%H%M%S).log"
OS_PATCH_LOG="${LOG_DIR}/os_patch_$(date +%F_%H%M%S).log"

os_precheck_html() {
    local phase_log_dir
    phase_log_dir="$(current_phase_log_dir)"
    local uname_log="${phase_log_dir}/uname_$(date +%F_%H%M%S).log"
    local rpm_log="${phase_log_dir}/rpm_kernel_$(date +%F_%H%M%S).log"
    local yum_log="${phase_log_dir}/yum_check_update_$(date +%F_%H%M%S).log"

    {
        echo "==== uname -a ===="
        uname -a 2>&1
        echo
        echo "==== /etc/os-release ===="
        cat /etc/os-release 2>&1 || true
    } > "$uname_log"
    add_attachment "$uname_log"
    log_file_content "$uname_log" "OS: uname + release"

    {
        echo "==== RPM kernel packages ===="
        rpm -qa | grep -Ei 'kernel(|-core|-uek)' | sort || true
    } > "$rpm_log"
    add_attachment "$rpm_log"
    log_file_content "$rpm_log" "OS: kernel RPMs"

    if command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
        {
            echo "==== Pending updates (summary) ===="
            if command -v yum >/dev/null 2>&1; then
                yum check-update || true
            else
                dnf check-update || true
            fi
        } > "$yum_log"
        add_attachment "$yum_log"
        log_file_content "$yum_log" "OS: pending yum/dnf updates"
        add_html_row "OS precheck - packages" "INFO" "Captured OS/kernel package snapshot. See attachments:<br/>$(basename "$uname_log"), $(basename "$rpm_log"), $(basename "$yum_log")"
    else
        add_html_row "OS precheck - packages" "WARN" "yum/dnf not found; OS package precheck limited to kernel rpm list. See $(basename "$rpm_log")."
    fi
}

os_patch_html() {
    local mgr=""
    local phase_log_dir pkg_log
    phase_log_dir="$(current_phase_log_dir)"
    pkg_log="${phase_log_dir}/os_patch_$(date +%F_%H%M%S).log"
    local patch_timeout="${OS_PATCH_TIMEOUT:-7200}"

    if command -v dnf >/dev/null 2>&1; then
        mgr="dnf"
    elif command -v yum >/dev/null 2>&1; then
        mgr="yum"
    elif command -v apt-get >/dev/null 2>&1; then
        mgr="apt-get"
    else
        add_html_row "OS patch" "WARN" "No supported package manager found (dnf/yum/apt-get). OS patch not applied."
        return 0
    fi

    add_html_row "OS patch - tool" "INFO" "Using <code>${mgr}</code> with timeout ${patch_timeout}s. Log: $(basename "$pkg_log")"

    if [[ "$DRYRUN" == true ]]; then
        log "[DRYRUN] Would perform OS patch using $mgr"
        return 0
    fi

    local rc=0
    if [[ "$mgr" == "apt-get" ]]; then
        timeout "$patch_timeout" bash -c 'echo "=== apt-get update ==="; apt-get update; echo; echo "=== apt-get -y dist-upgrade ==="; apt-get -y dist-upgrade' &> "$pkg_log" || rc=$?
    else
        timeout "$patch_timeout" bash -c 'echo "=== '"$mgr"' -y update ==="; '"$mgr"' -y update' &> "$pkg_log" || rc=$?
    fi

    add_attachment "$pkg_log"
    if [[ $rc -eq 0 ]]; then
        add_html_row "OS patch" "PASS" "OS packages updated successfully via ${mgr}. See $(basename "$pkg_log")."
    else
        add_html_row "OS patch" "WARN" "OS package update via ${mgr} returned non-zero exit code ($rc). Review $(basename "$pkg_log")."
    fi
}


#os_reboot_html() {
#    add_html_row "OS reboot" "INFO" \
#        "Reboot requested by orchestrator. This host will reboot in 1 minute using <code>shutdown -r +1</code> (root) to allow emails and scheduling jobs to be queued."
#
#    if [[ "$DRYRUN" == true ]]; then
#        log "[DRYRUN] Would reboot via shutdown -r +1 (skipped)."
#        add_html_row "OS reboot (dry-run)" "INFO" \
#            "DRYRUN – reboot skipped."
#        return 0
#    fi
#
#    log "Initiating reboot via: sudo shutdown -r +1"
#    sudo /sbin/shutdowno -r +1 || sudo shutdowno -r +1 || shutdown -r +1
#}
# ------------------------------------------------------------
# GI PRECHECK: GI / Clusterware discovery
# ------------------------------------------------------------
gi_discovery_html() {
    local gi_home="$1"
    log "Running GI discovery for GRID_HOME=$gi_home"

    add_html_row "--- GI ENVIRONMENT ---" "INFO" "Grid Infrastructure discovery"
    add_html_row "GRID_HOME (OLD)" "INFO" "$gi_home"
    add_html_row "NEW_GI_HOME"     "INFO" "$NEW_GI_HOME"

    # ORACLE_BASE for grid user
    local oracle_base=""
    if [[ -x "$gi_home/bin/orabase" ]]; then
        oracle_base=$(ORACLE_HOME="$gi_home" "$gi_home/bin/orabase" 2>/dev/null || true)
    fi
    if [[ -n "$oracle_base" ]]; then
        add_html_row "ORACLE_BASE" "INFO" "$oracle_base"
    else
        add_html_row "ORACLE_BASE" "WARN" "Could not determine ORACLE_BASE from $gi_home/bin/orabase"
    fi

    # GI patch level
    local gi_patch
    gi_patch=$(get_patch_level "$gi_home" 2>/dev/null || echo "<unable to query>")
    add_html_row "GI Current Patch Level" "INFO" "$gi_patch"

    # CRS active version
    add_html_row "--- CLUSTER / CRS ---" "INFO" "Cluster identification"
    local crs_version=""
    if [[ -x "$gi_home/bin/crsctl" ]]; then
        crs_version=$(ORACLE_HOME="$gi_home" "$gi_home/bin/crsctl" query crs activeversion 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
        if [[ -n "$crs_version" ]]; then
            add_html_row "CRS Active Version" "INFO" "$crs_version"
        else
            add_html_row "CRS Active Version" "WARN" "crsctl query crs activeversion returned no version — CRS may not be running."
        fi
    else
        add_html_row "CRS Active Version" "WARN" "crsctl not found in $gi_home/bin"
    fi

    # Cluster name
    local cluster_name=""
    if [[ -x "$gi_home/bin/cemutlo" ]]; then
        cluster_name=$("$gi_home/bin/cemutlo" -n 2>/dev/null || true)
    fi
    if [[ -z "$cluster_name" ]] && [[ -x "$gi_home/bin/olsnodes" ]]; then
        cluster_name=$(ORACLE_HOME="$gi_home" "$gi_home/bin/olsnodes" -c 2>/dev/null | head -1 || true)
    fi
    if [[ -z "$cluster_name" ]] && [[ -x "$gi_home/bin/crsctl" ]]; then
        cluster_name=$(ORACLE_HOME="$gi_home" "$gi_home/bin/crsctl" get cluster name 2>/dev/null | awk -F: '{print $NF}' | tr -d ' ' | head -1 || true)
    fi
    if [[ -n "$cluster_name" ]]; then
        add_html_row "Cluster Name" "INFO" "$cluster_name"
    else
        add_html_row "Cluster Name" "INFO" "Standalone / non-clustered (HAS mode or no cluster name detected)"
        cluster_name="standalone"
    fi

    # Node list
    add_html_row "--- CLUSTER NODES ---" "INFO" "olsnodes output"
    local node_list=""
    local -a nodes=()
    if [[ -x "$gi_home/bin/olsnodes" ]]; then
        node_list=$(ORACLE_HOME="$gi_home" "$gi_home/bin/olsnodes" -n 2>/dev/null || true)
        if [[ -n "$node_list" ]]; then
            while IFS= read -r node_line; do
                [[ -z "$node_line" ]] && continue
                local node_num node_name
                node_name=$(echo "$node_line" | awk '{print $1}')
                node_num=$(echo "$node_line" | awk '{print $2}')
                nodes+=("$node_name")
                add_html_row "Node ${node_num:-}" "INFO" "$node_name"
            done <<< "$node_list"
        else
            add_html_row "Cluster Nodes" "INFO" "olsnodes returned no output — likely standalone (HAS)."
            nodes=("$HOSTNAME")
        fi
    else
        add_html_row "Cluster Nodes" "WARN" "olsnodes not found in $gi_home/bin — cannot enumerate cluster nodes."
        nodes=("$HOSTNAME")
    fi

    # ASM instance
    add_html_row "--- ASM ---" "INFO" "ASM instance information"
    local asm_sid=""
    asm_sid=$(ps -eo args 2>/dev/null | awk -Fpmon_ '/pmon_\+ASM/{print $2}' | sed 's/ .*//' | head -1 || true)
    if [[ -z "$asm_sid" ]]; then
        asm_sid=$(ps -eo args 2>/dev/null | grep 'pmon_+ASM' | awk '{print $NF}' | sed 's/.*pmon_//' | head -1 || true)
    fi

    if [[ -n "$asm_sid" ]]; then
        local asm_sqlplus="$gi_home/bin/sqlplus"
        if [[ -x "$asm_sqlplus" ]]; then
            local asm_output
            asm_output=$(ORACLE_SID="$asm_sid" ORACLE_HOME="$gi_home" \
                PATH="$gi_home/bin:$PATH" \
                "$asm_sqlplus" -S / as sysasm 2>/dev/null <<'ASMEOF'
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF TRIMOUT ON TRIMSPOOL ON
WHENEVER SQLERROR CONTINUE
SELECT 'ASM_INSTANCE='||instance_name FROM v$instance;
SELECT 'ASM_STATUS='||status FROM v$instance;
SELECT 'ASM_VERSION='||version FROM v$instance;
SELECT 'ASM_DG='||name||':'||state||':'||type FROM v$asm_diskgroup ORDER BY name;
EXIT
ASMEOF
            ) || true

            if [[ -n "$asm_output" ]]; then
                local asm_instance asm_status asm_version
                while IFS= read -r rawline; do
                    local trimmed
                    trimmed=$(printf '%s' "$rawline" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                    [[ -z "$trimmed" ]] && continue
                    local key="${trimmed%%=*}"
                    local val="${trimmed#*=}"
                    case "$key" in
                        ASM_INSTANCE) asm_instance="$val" ;;
                        ASM_STATUS)   asm_status="$val"   ;;
                        ASM_VERSION)  asm_version="$val"  ;;
                        ASM_DG)
                            local dg_name dg_state dg_type
                            IFS=: read -r dg_name dg_state dg_type <<< "$val"
                            local dg_st="PASS"
                            [[ "${dg_state:-}" != "MOUNTED" ]] && dg_st="WARN"
                            add_html_row "ASM Diskgroup $dg_name" "$dg_st" "$dg_type — $dg_state"
                            ;;
                    esac
                done <<< "$asm_output"
                add_html_row "ASM Instance" "PASS" "${asm_instance:-$asm_sid} (${asm_version:-?}) — status: ${asm_status:-?}"
            else
                add_html_row "ASM Instance" "INFO" "$asm_sid running (sysasm query returned no output)"
            fi
        else
            add_html_row "ASM Instance" "INFO" "$asm_sid running (sqlplus not available in $gi_home)"
        fi
    else
        add_html_row "ASM Instance" "INFO" "No ASM instance detected (standalone filesystem or ASM not running)"
    fi

    # ---- Build node JSON array ----
    local nodes_json="["
    for n in "${nodes[@]}"; do
        nodes_json+="\"${n}\","
    done
    nodes_json="${nodes_json%,}]"
    [[ "$nodes_json" == "[" ]] && nodes_json="[]"

    # ---- Write GI discovery JSON ----
    local gi_json_file="${GI_LOG_DIR}/gi_discovery.json"
    cat > "$gi_json_file" <<GIJSON
{
  "type": "gi_discovery",
  "hostname": "$HOSTNAME",
  "grid_home": "$gi_home",
  "new_gi_home": "$NEW_GI_HOME",
  "oracle_base": "${oracle_base:-}",
  "crs_active_version": "${crs_version:-}",
  "gi_patch_level": "${gi_patch:-}",
  "cluster_name": "${cluster_name:-}",
  "cluster_mode": "$GI_CLUSTER_MODE",
  "nodes": $nodes_json,
  "asm_sid": "${asm_sid:-}",
  "generated_at": "$(date '+%F %T')"
}
GIJSON
    add_html_row "GI Discovery JSON" "INFO" "Written to $gi_json_file"
    log "GI Discovery JSON written to $gi_json_file"

    # Emit for backend storage
    local gi_json_content
    gi_json_content=$(cat "$gi_json_file")
    log "[DISCOVERY_JSON] ${gi_json_content}"
}

# ------------------------------------------------------------
# GI PRECHECK: OCR + Voting disk backup validation
# ------------------------------------------------------------
gi_backup_validation_html() {
    local gi_home="$1"
    add_html_row "--- BACKUP VALIDATION ---" "INFO" "OCR and Voting Disk status"

    # OCR check
    if [[ -x "$gi_home/bin/ocrcheck" ]]; then
        local ocr_out
        ocr_out=$(ORACLE_HOME="$gi_home" "$gi_home/bin/ocrcheck" 2>&1 || true)
        if echo "$ocr_out" | grep -qi "Device/File.*integrity check succeeded\|successful"; then
            local ocr_devices
            ocr_devices=$(echo "$ocr_out" | grep -i "Device\|File Name" | head -5 | tr '\n' ' ')
            add_html_row "OCR Integrity" "PASS" "ocrcheck passed. ${ocr_devices}"
        elif echo "$ocr_out" | grep -qi "FAILED\|error"; then
            add_html_row "OCR Integrity" "FAIL" "ocrcheck reported failures: $(echo "$ocr_out" | head -5)"
        else
            add_html_row "OCR Integrity" "INFO" "ocrcheck output: $(echo "$ocr_out" | head -5)"
        fi
    else
        add_html_row "OCR Integrity" "INFO" "ocrcheck not found in $gi_home/bin (may be standalone / no GI)"
    fi

    # OCR backup location
    if [[ -x "$gi_home/bin/ocrconfig" ]]; then
        local ocr_backup
        ocr_backup=$(ORACLE_HOME="$gi_home" "$gi_home/bin/ocrconfig" -showbackup 2>/dev/null | head -10 || true)
        if [[ -n "$ocr_backup" ]]; then
            add_html_row "OCR Backup Status" "INFO" "$(echo "$ocr_backup" | head -5 | tr '\n' ' ')"
        else
            add_html_row "OCR Backup Status" "WARN" "ocrconfig -showbackup returned no output"
        fi
    fi

    # Voting disk
    if [[ -x "$gi_home/bin/crsctl" ]]; then
        local vd_out
        vd_out=$(ORACLE_HOME="$gi_home" "$gi_home/bin/crsctl" query css votedisk 2>/dev/null || true)
        if echo "$vd_out" | grep -q "ONLINE"; then
            local vd_count
            vd_count=$(echo "$vd_out" | grep -c "ONLINE" || true)
            add_html_row "Voting Disks" "PASS" "$vd_count voting disk(s) ONLINE. $(echo "$vd_out" | grep ONLINE | head -3 | tr '\n' ' ')"
        elif [[ -n "$vd_out" ]]; then
            add_html_row "Voting Disks" "WARN" "$(echo "$vd_out" | head -5 | tr '\n' ' ')"
        else
            add_html_row "Voting Disks" "INFO" "crsctl query css votedisk returned no output (standalone / HAS mode expected)"
        fi
    else
        add_html_row "Voting Disks" "INFO" "crsctl not found in $gi_home/bin (no GI / standalone)"
    fi
}

# ------------------------------------------------------------
# GI PRECHECK (19c patching)  -- also acts as common GI health
# ------------------------------------------------------------
gi_precheck() {

    # Ensure GI log dirs exist and are writable before any logging
    ensure_phase_log_dirs gi

    reset_report
    reset_html_report

    LOG_FILE="${GI_LOG_DIR}/gi_precheck_$(date +%F_%H%M%S).log"
    add_attachment "$LOG_FILE"
    log "GI PRECHECK"

    assert_precheck_homes_safe

    write_gi_rsp_if_embedded

    # Basic OS / scheduler
    check_at_service_html

    # Validate required software is staged
    validate_staged_software_html gi || true



    # Space checks for GI + DB homes
    local gi_fs db_fs
    gi_fs=$(df -P "$OLD_GI_HOME" 2>/dev/null | awk 'NR==2{print $6}' || true)
    db_fs=$(df -P "$OLD_DB_HOME" 2>/dev/null | awk 'NR==2{print $6}' || true)

    if [[ -n "$gi_fs" ]]; then
        check_space_html "$gi_fs" 20
    else
        add_html_row "Filesystem space for OLD_GI_HOME" "WARN" \
            "Could not determine filesystem for $OLD_GI_HOME"
    fi
    if [[ -n "$db_fs" ]]; then
        check_space_html "$db_fs" 30
    else
        add_html_row "Filesystem space for OLD_DB_HOME" "WARN" \
            "Could not determine filesystem for $OLD_DB_HOME"
    fi

    # sudo / cluster type
    check_oracle_sudo_nopass_html
    detect_cluster_type_html
    GI_CLUSTER_MODE=$(detect_gi_cluster_mode)
    add_html_row "GI cluster mode (automation)" "INFO" "$GI_CLUSTER_MODE"

    # /etc/oratab snapshot + GI state
    capture_gi_oratab_state
    local oratab_html
    oratab_html=$(format_oratab_html "$OLD_GI_HOME")
    add_html_row "/etc/oratab entries" "INFO" "$oratab_html"

    # ------------------------------------------------------------
    # Capture old GI patch level (save to file + attach)
    # ------------------------------------------------------------
    local gi_patch
    gi_patch=$(get_patch_level "$OLD_GI_HOME" || echo "")
    add_html_row "GI patch level (OLD_GI_HOME)" "INFO" "$gi_patch"

    if [[ -n "$gi_patch" ]]; then
        echo "$gi_patch" > "${GI_LOG_DIR}/gi_old_patchlevel.html"
    else
        echo "Patch level unknown for OLD_GI_HOME ($OLD_GI_HOME)" \
            > "${GI_LOG_DIR}/gi_old_patchlevel.html"
    fi
    add_attachment "${GI_LOG_DIR}/gi_old_patchlevel.html"

    # NEW_GI_HOME inventory / attachment
    if [[ ! -d "$NEW_GI_HOME" ]]; then
        add_html_row "GI NEW_GI_HOME inventory" "INFO" \
            "NEW_GI_HOME ($NEW_GI_HOME) does not exist yet; GI Install will create and attach it."
    else
        is_gi_home_attached "$NEW_GI_HOME"
        case $? in
            0)
                add_html_row "GI NEW_GI_HOME inventory" "INFO" \
                    "NEW_GI_HOME ($NEW_GI_HOME) is present in central inventory (attached)."
                ;;
            1)
                add_html_row "GI NEW_GI_HOME inventory" "WARN" \
                    "NEW_GI_HOME ($NEW_GI_HOME) exists but does NOT appear in central inventory; attachHome may be required before or during GI switch."
                ;;
            *)
                add_html_row "GI NEW_GI_HOME inventory" "WARN" \
                    "Could not read central inventory (oraInst.loc / inventory.xml); cannot confirm whether $NEW_GI_HOME is attached."
                ;;
        esac
    fi

    # OPatch requirement vs current
    local req_opatch cur_opatch
    req_opatch=$(required_opatch_version)
    cur_opatch=$(current_opatch_version "$OLD_GI_HOME")
    if [[ -z "$req_opatch" ]]; then
        add_html_row "OPatch version (GI home)" "WARN" \
            "Could not parse required OPatch version from $RU_README; current GI OPatch is ${cur_opatch:-unknown}."
    else
        if [[ -z "$cur_opatch" || "$cur_opatch" == "0" ]]; then
            add_html_row "OPatch version (GI home)" "INFO" \
                "Required: $req_opatch (per $RU_README), current GI OPatch in $OLD_GI_HOME is unknown. OPatch will be updated during install using $OPATCH_ZIP (if configured)."
        else
            if compare_versions "$cur_opatch" "$req_opatch"; then
                add_html_row "OPatch version (GI home)" "INFO" \
                    "Current GI OPatch: $cur_opatch; required: $req_opatch (per $RU_README)."
            else
                add_html_row "OPatch version (GI home)" "WARN" \
                    "Current GI OPatch: $cur_opatch, lower than required: $req_opatch (per $RU_README). OPatch will be updated during GI install using $OPATCH_ZIP."
            fi
        fi
    fi

    # CRS/HAS status snapshot
    local crs_log="${GI_LOG_DIR}/crs_stat_$(date +%F_%H%M%S).log"
    if [[ -x "$OLD_GI_HOME/bin/crsctl" ]]; then
        if [[ "$GI_CLUSTER_MODE" == "HAS" ]]; then
            run_cmd "\"$OLD_GI_HOME/bin/crsctl\" check has > \"$crs_log\" 2>&1 || true"
            add_html_row "HAS status" "INFO" \
                "<pre style='margin:0;font-size:12px'>$(cat "$crs_log" 2>/dev/null | escape_html)</pre>"
        else
            run_cmd "\"$OLD_GI_HOME/bin/crsctl\" stat res -t > \"$crs_log\" 2>&1 || true"
            add_html_row "CRS resource status" "INFO" \
                "$(format_crs_stat_html "$crs_log")"
        fi
        add_html_attachment "$crs_log" "CRS Resource Status"
        log_file_content "$crs_log" "GI: CRS/HAS resource status"
    else
        add_html_row "CRS/HAS status" "WARN" \
            "crsctl not found in OLD_GI_HOME; cannot report CRS/HAS resources."
    fi

    # GI CVU precheck (HAS/CRS)
    check_gi_cvu_preinstall "$OLD_GI_HOME" "$GI_CLUSTER_MODE"

    # 19c executePrereqs from a temporary precheck home
    local gi_prereq_log="${GI_LOG_DIR}/gi_executePrereqs_$(date +%F_%H%M%S).log"
    local gi_prereq_home="$PRECHECK_GI_HOME"

    if stage_gi_software_for_precheck "$gi_prereq_home"; then
        if [[ -x "$gi_prereq_home/gridSetup.sh" ]]; then

            # Marker so we can attach OUI logs created during this executePrereqs run
            local oui_marker="${GI_LOG_DIR}/.marker_gi_executePrereqs_$(date +%F_%H%M%S)"
            : > "$oui_marker"

            run_cmd "sudo -u \"$GRID_USER\" \"$gi_prereq_home/gridSetup.sh\" -silent -executePrereqs -responseFile \"$GI_RSP\" > \"$gi_prereq_log\" 2>&1 || true"
            add_attachment "$gi_prereq_log"

            # Attach detailed OUI logs (GridSetupActions / prereq logs) created after the marker
            attach_latest_oui_logs_since_marker "$oui_marker" "GI executePrereqs" 8
            rm -f "$oui_marker" 2>/dev/null || true

            if grep -qi "failed" "$gi_prereq_log" 2>/dev/null; then
                add_html_row "GI executePrereqs" "FAIL" \
                    "gridSetup.sh -executePrereqs reported failures (precheck home: $gi_prereq_home). See $gi_prereq_log"
            else
                add_html_row "GI executePrereqs" "PASS" \
                    "gridSetup.sh -executePrereqs completed (precheck home: $gi_prereq_home). See $gi_prereq_log"
            fi
        else
            add_html_row "GI executePrereqs" "WARN" \
                "gridSetup.sh not found in $gi_prereq_home even after staging; -executePrereqs skipped."
        fi
    else
        add_html_row "GI executePrereqs" "WARN" \
            "Could not stage GI software into $gi_prereq_home; -executePrereqs skipped."
    fi

    # Cleanup of temporary GI precheck home
    if [[ -d "$PRECHECK_GI_HOME" ]]; then
        add_html_row "GI precheck software cleanup" "INFO" \
            "Removing precheck GI home $PRECHECK_GI_HOME to free space."
        safe_rm_rf "$PRECHECK_GI_HOME" true
    fi

    # Marker that GI precheck completed
    run_cmd "touch $PRECHECK_MARKER"
    add_html_row "GI precheck marker" "INFO" "Created marker file: $PRECHECK_MARKER"

    # ------------------------------------------------------------
    # GI Discovery + Backup Validation
    # ------------------------------------------------------------
    gi_discovery_html "$OLD_GI_HOME"
    gi_backup_validation_html "$OLD_GI_HOME"

    send_html_report "GI Precheck Report - $HOST" "GI Precheck Report"
}
# ------------------------------------------------------------
# GI INSTALL (19c patching)
# ------------------------------------------------------------
gi_install() {
    reset_report
    reset_html_report

    # Ensure GI log dir exists and is writable
    ensure_phase_log_dirs gi

    LOG_FILE="${GI_LOG_DIR}/gi_install_$(date +%F_%H%M%S).log"
    log "GI INSTALL"
    write_gi_rsp_if_embedded

    # HARD BLOCK: refuse to install into a GI home that is currently hosting CRS/HAS/ASM.
    # This is belt-and-suspenders — gi_precheck should catch it first, but someone could
    # skip precheck entirely.
    if [[ -d "$NEW_GI_HOME" ]]; then
        local _gi_live=false
        if [[ -x "$NEW_GI_HOME/bin/crsctl" ]]; then
            if "$NEW_GI_HOME/bin/crsctl" check crs >/dev/null 2>&1 || \
               "$NEW_GI_HOME/bin/crsctl" check has >/dev/null 2>&1; then
                _gi_live=true
            fi
        fi
        [[ "$NEW_GI_HOME" == "$OLD_GI_HOME" ]] && _gi_live=true
        if [[ "$_gi_live" == true ]]; then
            local _why="CRS/HAS is active from $NEW_GI_HOME"
            [[ "$NEW_GI_HOME" == "$OLD_GI_HOME" ]] && _why="NEW_GI_HOME equals OLD_GI_HOME ($OLD_GI_HOME)"
            add_html_row "GI Install Safety Check" "FAIL" \
                "HARD BLOCK: $_why. Unzipping base media into a live GI home will corrupt ASM, voting disks, and OCR. Run gi_rollback first to return CRS to $OLD_GI_HOME, then retry gi_install."
            send_html_report "GI Install BLOCKED - $HOST" "GI Install Report (BLOCKED)"
            die "HARD BLOCK: gi_install refused — $_why"
        fi
    fi

    add_html_row "GI RU directory" "INFO" "$RU_DIR"

    run_cmd "sudo mkdir -p \"$NEW_GI_HOME\""
    run_cmd "sudo chown -R ${GRID_USER}:${OINSTALL} \"$NEW_GI_HOME\""

    # Depot mode: agent pre-extracted the GI base tar directly into NEW_GI_HOME.
    if [[ -f "$NEW_GI_HOME/gridSetup.sh" ]]; then
        add_html_row "GI Base (depot mode)" "PASS" \
            "$NEW_GI_HOME already contains gridSetup.sh — pre-extracted from orchestrator depot. Skipping zip transfer and unzip."
        log "INFO: Depot mode — $NEW_GI_HOME already extracted, skipping unzip"
    elif [[ ! -f "$GI_BASE_ZIP" ]]; then
        add_html_row "GI Base ZIP" "FAIL" \
            "GI base ZIP missing: $GI_BASE_ZIP. Either upload the zip or run 'Extract to Depot' from the Patches UI and re-stage."
        die "GI Base ZIP missing: $GI_BASE_ZIP"
    else
        add_html_row "GI Base ZIP" "PASS" "$GI_BASE_ZIP"
        run_cmd "unzip -oq \"$GI_BASE_ZIP\" -d \"$NEW_GI_HOME\""
    fi

    update_opatch "$NEW_GI_HOME"
    add_html_row "OPatch in NEW_GI_HOME" "INFO" "OPatch updated under $NEW_GI_HOME (see logs)"

    ensure_cvu_config_ol7 "$NEW_GI_HOME"

    local grid_log="${GI_LOG_DIR}/gridSetup_$(date +%F_%H%M%S).log"
    add_attachment "$grid_log"

    if [[ "$DRYRUN" == true ]]; then
        log "[DRYRUN] Would run GI installer"
        log "[DRYRUN] Command: $NEW_GI_HOME/gridSetup.sh -silent -ignorePrereqFailure -responseFile $GI_RSP -applyRU $RU_DIR -waitForCompletion"
        add_html_row "GI Install (dry-run)" "INFO" "Installer would log to $grid_log"
        send_html_report "GI Install (Dry-run) - $HOST" "GI Install (Dry-run) Report"
        return 0
    fi

    # Marker so we can attach the OUI logs created during this run
    local oui_marker="${GI_LOG_DIR}/.marker_gi_install_$(date +%F_%H%M%S)"
    : > "$oui_marker"

    log "Starting GI Software Install. Installer log will be in ${grid_log}"
    sudo -u "$GRID_USER" bash -c "yes randn_pass | \
        \"$NEW_GI_HOME/gridSetup.sh\" \
            -silent -ignorePrereqFailure -responseFile \"$GI_RSP\" \
            -applyRU \"$RU_DIR\" \
            -waitForCompletion" \
        &> "$grid_log" &

    local installer_pid=$!
    local timeout_seconds=7200
    local poll_interval=10
    local elapsed=0
    local success=false
    local installer_rc=0
    local failure_reason="Unknown failure"

    log "Monitoring GI installer (PID=$installer_pid) with timeout ${timeout_seconds}s..."
    while (( elapsed < timeout_seconds )); do
        if [[ -f "$grid_log" ]]; then
            if grep -q "Successfully Setup Software" "$grid_log" 2>/dev/null; then
                success=true
                break
            fi
            if grep -qi "error" "$grid_log" 2>/dev/null; then
                failure_reason="Error string detected in installer log. See $grid_log"
                break
            fi
        fi

        if ! kill -0 "$installer_pid" 2>/dev/null; then
            wait "$installer_pid" || installer_rc=$?
            if (( installer_rc == 0 )); then
                success=true
                failure_reason="Installer RC=0 but success string not found. See $grid_log"
            else
                failure_reason="Installer exited with RC=${installer_rc}. See $grid_log"
            fi
            break
        fi

        sleep "$poll_interval"
        elapsed=$(( elapsed + poll_interval ))
    done

    if [[ "$success" != true && $elapsed -ge $timeout_seconds ]]; then
        failure_reason="Timeout after ${timeout_seconds}s waiting for GI installer. See $grid_log"
        if kill -0 "$installer_pid" 2>/dev/null; then
            kill "$installer_pid" 2>/dev/null || true
        fi
    fi

    # Attach central inventory / cfgtoollogs OUI logs for this install
    attach_latest_oui_logs_since_marker "$oui_marker" "GI Install" 10
    rm -f "$oui_marker" 2>/dev/null || true

    if [[ "$success" == true ]]; then
        if kill -0 "$installer_pid" 2>/dev/null; then
            wait "$installer_pid" || installer_rc=$?
        fi
        local status_msg="Successfully Setup Software"
        if grep -qi "warning(s)" "$grid_log" 2>/dev/null; then
            status_msg="Successfully Setup Software with warning(s)"
        fi
        add_html_row "GI Software Install" "PASS" "$status_msg. See installer log: $grid_log"
        run_cmd "touch $PRECHECK_MARKER"
        add_html_row "Precheck marker" "PASS" "Marker created: $PRECHECK_MARKER"
        send_html_report "GI Install Completed - $HOST" "GI Install Report"
        log "GI installer completed successfully."
        return 0
    fi

    add_html_row "GI Software Install" "FAIL" "$failure_reason. See installer log: $grid_log"
    send_html_report "GI Install FAILED - $HOST" "GI Install Report (FAILED)"
    log "GI installer failed: $failure_reason"
    die "$failure_reason"
}
# ------------------------------------------------------------
# GI DATAPATCH + ASM STATUS
# ------------------------------------------------------------
run_gi_datapatch_for_home() {
    local home="$1"
    local phase="$2"
    if [[ "$GI_CLUSTER_MODE" != "CRS" ]]; then
        add_html_row "GI datapatch ($phase)" "INFO" "GI mode $GI_CLUSTER_MODE ? skipping GI datapatch."
        return
    fi
    local sid
    sid=$(load_gi_mgmtdb_sid)
    if [[ -n "$sid" && "$sid" == +ASM* ]]; then
        if [[ -f "$ORATAB_FILE" ]]; then
            local mgmt_from_oratab
            mgmt_from_oratab=$(awk -F: -v h="$home" '$2==h && $1 ~ /MGMTDB/ {print $1; exit}' "$ORATAB_FILE")
            if [[ -n "$mgmt_from_oratab" ]]; then
                log "INFO: Correcting MGMTDB SID from '$sid' to '$mgmt_from_oratab' based on /etc/oratab."
                sid="$mgmt_from_oratab"
            else
                log "INFO: Saved MGMTDB SID '$sid' looks like ASM and no MGMTDB entry found ? skipping GI datapatch."
                add_html_row "GI datapatch ($phase)" "WARN" \
                    "No valid MGMTDB SID found (saved SID '$sid' looks like ASM); GI datapatch skipped."
                return
            fi
        else
            log "INFO: Saved MGMTDB SID '$sid' looks like ASM and /etc/oratab not found ? skipping GI datapatch."
            add_html_row "GI datapatch ($phase)" "WARN" \
                "No valid MGMTDB SID found (saved SID '$sid' looks like ASM); GI datapatch skipped."
            return
        fi
    fi
    if [[ -z "$sid" ]]; then
        add_html_row "GI datapatch ($phase)" "WARN" \
            "MGMTDB SID not known; skipping GI datapatch (no ASM OPEN READ WRITE checks performed)."
        return
    fi
    local timeout=120
    local interval=15
    local elapsed=0
    log "Waiting for MGMTDB SID $sid in home $home to be OPEN READ WRITE (timeout ${timeout}s)..."
    while (( elapsed < timeout )); do
        local mode
        mode=$(ORACLE_HOME="$home" ORACLE_SID="$sid" PATH="$home/bin:$PATH" \
            "$home/bin/sqlplus" -s / as sysdba 2>/dev/null <<EOF
set heading off feedback off pages 0 verify off echo off termout off
select open_mode from v\$database;
exit
EOF
)
        mode=$(echo "$mode" | tr -d '\r' | sed -n '1p')
        if [[ "$mode" == "READ WRITE" ]]; then
            log "MGMTDB $sid (home $home) is OPEN READ WRITE ? running datapatch."
            add_html_row "GI datapatch ($phase)" "PASS" \
                "MGMTDB ($sid) is OPEN READ WRITE ? running datapatch from $home."
            run_cmd "ORACLE_HOME=\"$home\" ORACLE_SID=\"$sid\" PATH=\"$home/bin:\$PATH\" \"$home/OPatch/datapatch\" -verbose"
            return
        fi
        log "MGMTDB $sid not yet READ WRITE (current: '$mode'). Waiting..."
        sleep "$interval"
        elapsed=$(( elapsed + interval ))
    done
    log "WARN: Timed out waiting for MGMTDB $sid to open READ WRITE ? GI datapatch skipped."
    add_html_row "GI datapatch ($phase)" "WARN" \
        "MGMTDB ($sid) did not reach OPEN READ WRITE within ${timeout}s ? datapatch skipped."
}
check_asm_running_html() {
    local home="$1"
    local logf="${LOG_DIR}/srvctl_status_asm_$(date +%F_%H%M%S).log"
    local pmon_log="${LOG_DIR}/pmon_snapshot_$(date +%F_%H%M%S).log"
    ps -eo user,pid,cmd | grep '[p]mon_' > "$pmon_log" 2>&1 || true
    add_html_attachment "$pmon_log" "PMON Snapshot"
    if [[ -z "$SRVCTL_BIN" ]]; then
        add_html_row "ASM status" "WARN" \
            "srvctl not available; cannot confirm ASM status from GI. PMON snapshot saved to $pmon_log"
        return
    fi
    local gi_home_for_srvctl
    gi_home_for_srvctl="$(cd "$(dirname "$SRVCTL_BIN")/.." && pwd 2>/dev/null || echo "")"
    if [[ -z "$gi_home_for_srvctl" || ! -d "$gi_home_for_srvctl" ]]; then
        gi_home_for_srvctl="$home"
    fi
    local timeout=300
    local interval=15
    local elapsed=0
    local asm_running=false
    log "Checking ASM status using SRVCTL_BIN=$SRVCTL_BIN with ORACLE_HOME=$gi_home_for_srvctl (timeout ${timeout}s)..."
    while (( elapsed < timeout )); do
        run_cmd "ORACLE_HOME=\"$gi_home_for_srvctl\" \"$SRVCTL_BIN\" status asm > \"$logf\" 2>&1 || true"
        if grep -qi "is running on" "$logf"; then
            asm_running=true
            break
        fi
        sleep "$interval"
        elapsed=$(( elapsed + interval ))
    done
    add_html_attachment "$logf" "SRVCTL Status ASM"
    if [[ "$asm_running" == true ]]; then
        add_html_row "ASM status" "PASS" \
            "ASM is running as per 'srvctl status asm' (waited ~${elapsed}s). See $logf. PMON snapshot: $pmon_log"
    else
        add_html_row "ASM status" "WARN" \
            "ASM was not reported as running by 'srvctl status asm' within ${timeout}s. See $logf. PMON snapshot: $pmon_log"
    fi
}
check_asm_spfile_status_html() {
    local home="$1"

    # Discover ASM SID(s) from PMON
    local asm_sids=()
    local p_asm
    p_asm=$(ps -eo args | awk -F'pmon_' '/pmon_/ {print $2}' \
            | sed 's/ .*$//' | grep '^+ASM' || true)
    if [[ -n "$p_asm" ]]; then
        while IFS= read -r s; do
            [[ -n "$s" ]] && asm_sids+=( "$s" )
        done <<< "$p_asm"
    fi
    [[ ${#asm_sids[@]} -eq 0 ]] && asm_sids+=( "+ASM1" "+ASM" )

    if [[ ! -x "$home/bin/sqlplus" ]]; then
        add_html_row "ASM SPFILE" "WARN" \
            "sqlplus not found in $home; cannot run 'show parameter spfile' as SYSASM."
        return
    fi

    local sid out val asm_ok=false
    for sid in "${asm_sids[@]}"; do
        out=$(
            ORACLE_HOME="$home" \
            ORACLE_SID="$sid" \
            PATH="$home/bin:$PATH" \
            "$home/bin/sqlplus" -s / as sysasm 2>/dev/null <<'EOF'
set heading off feedback off pages 0 verify off echo off termout off
column spfile_val format a200
select value spfile_val from v$parameter where name='spfile';
exit
EOF
        ) || true

        # Flatten any wrapping / multiple lines into a single path string
        val=$(echo "$out" | tr -d '\r' | sed '/^$/d' | paste -sd ' ' - | xargs)

        # Normalise for checks
        local val_lc
        val_lc=$(echo "$val" | tr 'A-Z' 'a-z')

        # Treat empty or "not available" as NO SPFILE
        if [[ -z "$val_lc" || "$val_lc" == "not available" ]]; then
            continue
        fi

        asm_ok=true
        add_html_row "ASM SPFILE" "PASS" \
            "ASM instance SID=${sid} is using SPFILE at:<br/><code>${val}</code>"
        break
    done

    if [[ "$asm_ok" != true ]]; then
        add_html_row "ASM SPFILE" "WARN" \
            "ASM appears to be running but <code>show parameter spfile</code> (v\$parameter.name='spfile') has no usable VALUE for tested SIDs: $(printf '%s ' "${asm_sids[@]}").<br/>\
Engineer should configure an ASM SPFILE before GI upgrade if currently using a pfile only.<br/><br/>\
Manual check:<br/>\
<code>ORACLE_HOME=${home}</code><br/>\
<code>ORACLE_SID=&lt;ASM_SID&gt;</code><br/>\
<code>sqlplus / as sysasm</code><br/>\
<code>show parameter spfile;</code>"
    fi
}
get_db_instances_for_local_node() {
    local db="$1"
    local local_host
    local_host=$(hostname -s | tr '[:upper:]' '[:lower:]')

    if [[ -z "$SRVCTL_BIN" ]]; then
        echo ""
        return
    fi

    local gi_home_for_srvctl
    gi_home_for_srvctl="$(cd "$(dirname "$SRVCTL_BIN")/.." && pwd 2>/dev/null || echo "")"
    if [[ -z "$gi_home_for_srvctl" || ! -d "$gi_home_for_srvctl" ]]; then
        echo ""
        return
    fi

    # Example:
    # Instance cdb1_1 is running on node racnode1
    # Instance cdb1_2 is running on node racnode2
    ORACLE_HOME="$gi_home_for_srvctl" "$SRVCTL_BIN" status database -d "$db" 2>/dev/null \
      | awk -v host="$local_host" '
            /Instance/ && /is running on node/ {
                inst=$2;
                node=$6;
                gsub(/[ \t\.\r\n]/, "", node);
                node = tolower(node);
                if (index(node, host) == 1) {
                    print inst;
                }
            }
        '
}
stop_all_dbs_for_gi_upgrade() {
    log "GI UPGRADE: stopping databases on this host for GI upgrade"

    # Array of tokens, e.g. ("testsre" "SID:cdbiacls01")
    GI_UPGRADE_STOPPED_DBS=()

    # Reuse cluster type determined during prechecks wherever possible
    local mode="${GI_CLUSTER_MODE:-UNKNOWN}"
    if [[ "$mode" == "UNKNOWN" || -z "$mode" ]]; then
        mode=$(detect_gi_cluster_mode)
        GI_CLUSTER_MODE="$mode"
    fi
    log "GI UPGRADE: using GI_CLUSTER_MODE='$GI_CLUSTER_MODE' when deciding stop strategy"

    # Use unified discovery (srvctl + PMON)
    discover_databases

    if [[ ${#DB_UNIQUES[@]} -eq 0 ]]; then
        log "INFO: stop_all_dbs_for_gi_upgrade: no databases discovered on this host."
        add_html_row "Stop DBs for GI upgrade" "INFO" \
            "No databases discovered via srvctl/PMON; nothing to stop for GI upgrade."
        return 0
    fi

    add_html_row "Stop DBs for GI upgrade" "INFO" \
        "Stopping databases before GI upgrade: $(printf '%s ' "${DB_UNIQUES[@]}")"

    local gi_home_for_srvctl=""
    if [[ -n "$SRVCTL_BIN" ]]; then
        gi_home_for_srvctl="$(cd "$(dirname "$SRVCTL_BIN")/.." && pwd 2>/dev/null || echo "")"
    fi

    local db
    for db in "${DB_UNIQUES[@]}"; do
        local used_srvctl=false

        # srvctl path: only database-level for HAS/Restart
        if [[ -n "$SRVCTL_BIN" && -n "$gi_home_for_srvctl" && -d "$gi_home_for_srvctl" ]]; then
            if "$SRVCTL_BIN" config database -d "$db" >/dev/null 2>&1; then
                log "GI UPGRADE: HAS/CRS + srvctl-managed DB '$db' -> srvctl stop database -d $db -o immediate"
                run_cmd "ORACLE_HOME=\"$gi_home_for_srvctl\" \"$SRVCTL_BIN\" stop database -d \"$db\" -o immediate || true"
                GI_UPGRADE_STOPPED_DBS+=( "$db" )
                used_srvctl=true
            fi
        fi

        if [[ "$used_srvctl" != true ]]; then
            # Fallback: stop by SID via SQL*Plus (db_name -> SID mapping if available)
            local sid
            sid="$(get_sid_for_db_name "$db")"
            log "GI UPGRADE: stopping DB instance with SID $sid via SQL*Plus for GI upgrade..."
            if [[ -x "$OLD_DB_HOME/bin/sqlplus" ]]; then
                run_cmd "ORACLE_HOME=\"$OLD_DB_HOME\" ORACLE_SID=\"$sid\" PATH=\"$OLD_DB_HOME/bin:$PATH\" \
                    \"$OLD_DB_HOME/bin/sqlplus\" -s / as sysdba <<'EOF'
whenever sqlerror exit 1
shutdown immediate;
exit
EOF
" || log "WARN: shutdown immediate failed for SID $sid (check manually)."
                GI_UPGRADE_STOPPED_DBS+=( "SID:${sid}" )
            else
                log "WARN: $OLD_DB_HOME/bin/sqlplus not found; cannot stop SID $sid automatically."
            fi
        fi
    done

    # Optional debug if you want to see exactly what was recorded
    # log "DEBUG: GI_UPGRADE_STOPPED_DBS after stop: $(printf '%s ' "${GI_UPGRADE_STOPPED_DBS[@]}")"
}
start_all_dbs_after_gi_upgrade() {
    # Nothing recorded as stopped? Nothing to do.
    if [[ ${#GI_UPGRADE_STOPPED_DBS[@]} -eq 0 ]]; then
        add_html_row "Start DBs after GI upgrade" "INFO" \
            "No DBs/instances were recorded as stopped for GI upgrade; nothing to start."
        return 0
    fi

    # ------------------------------------------------------------------
    # Check ASM is up before attempting to start DBs
    # ------------------------------------------------------------------
    local asm_ok=false
    if [[ -n "$SRVCTL_BIN" ]]; then
        local gi_home_for_srvctl asm_log
        gi_home_for_srvctl="$(cd "$(dirname "$SRVCTL_BIN")/.." && pwd 2>/dev/null || echo "")"
        asm_log="${LOG_DIR}/srvctl_status_asm_restart_$(date +%F_%H%M%S).log"
        if [[ -n "$gi_home_for_srvctl" && -d "$gi_home_for_srvctl" ]]; then
            run_cmd "ORACLE_HOME=\"$gi_home_for_srvctl\" \"$SRVCTL_BIN\" status asm > \"$asm_log\" 2>&1 || true"
            add_attachment "$asm_log"
            if grep -qi 'is running on' "$asm_log" 2>/dev/null; then
                asm_ok=true
                add_html_row "ASM status (pre-DB restart)" "INFO" \
                    "ASM reported as running by 'srvctl status asm'. See $asm_log"
            else
                add_html_row "ASM status (pre-DB restart)" "WARN" \
                    "ASM not reported as running by 'srvctl status asm'; DB restart skipped. See $asm_log"
            fi
        fi
    fi

    if [[ "$asm_ok" != true ]]; then
        log "GI UPGRADE: ASM not confirmed up; skipping DB restarts for safety."
        return 0
    fi

    # Log a nice stringified list for report/debug
    local stopped_str
    stopped_str=$(printf '%s ' "${GI_UPGRADE_STOPPED_DBS[@]}")
    log "GI UPGRADE: starting databases/instances that were stopped for GI upgrade: $stopped_str"

    # ------------------------------------------------------------------
    # Restart srvctl-managed DBs (database-level only for HAS/Restart)
    # ------------------------------------------------------------------
    local gi_home_for_srvctl=""
    if [[ -n "$SRVCTL_BIN" ]]; then
        gi_home_for_srvctl="$(cd "$(dirname "$SRVCTL_BIN")/.." && pwd 2>/dev/null || echo "")"
    fi

    local entry
    for entry in "${GI_UPGRADE_STOPPED_DBS[@]}"; do
        case "$entry" in
            SID:*)
                # Handled later via SQL*Plus
                ;;
            *)
                # Plain DB name stopped via srvctl stop database
                if [[ -n "$SRVCTL_BIN" && -n "$gi_home_for_srvctl" && -d "$gi_home_for_srvctl" ]]; then
                    log "GI UPGRADE: restarting database '$entry' via srvctl start database"
                    run_cmd "ORACLE_HOME=\"$gi_home_for_srvctl\" \"$SRVCTL_BIN\" start database -d \"$entry\" || true"
                fi
                ;;
        esac
    done

    # ------------------------------------------------------------------
    # Restart any pure SID stops we recorded via SQL*Plus
    # ------------------------------------------------------------------
    local sid
    for entry in "${GI_UPGRADE_STOPPED_DBS[@]}"; do
        case "$entry" in
            SID:*)
                sid="${entry#SID:}"
                log "GI UPGRADE: restarting instance SID '$sid' via SQL*Plus"
                if [[ -x "$OLD_DB_HOME/bin/sqlplus" ]]; then
                    run_cmd "ORACLE_HOME=\"$OLD_DB_HOME\" ORACLE_SID=\"$sid\" PATH=\"$OLD_DB_HOME/bin:$PATH\" \
                        \"$OLD_DB_HOME/bin/sqlplus\" -s / as sysdba <<'EOF'
whenever sqlerror exit 1
startup;
exit
EOF
" || log "WARN: startup failed for SID $sid (check manually)."
                else
                    log "WARN: $OLD_DB_HOME/bin/sqlplus not found; cannot start SID $sid automatically."
                fi
                ;;
        esac
    done

    add_html_row "Start DBs after GI upgrade" "INFO" \
        "Issued restart commands for: $stopped_str"
}
# ------------------------------------------------------------
# GI DATAPATCH + ASM STATUS
# ------------------------------------------------------------
run_gi_datapatch_for_home() {
    local home="$1"
    local phase="$2"

    if [[ "$GI_CLUSTER_MODE" != "CRS" ]]; then
        add_html_row "GI datapatch ($phase)" "INFO" "GI mode $GI_CLUSTER_MODE ? skipping GI datapatch."
        return
    fi

    local sid
    sid=$(load_gi_mgmtdb_sid)
    if [[ -n "$sid" && "$sid" == "+ASM" ]]; then
        if [[ -f "$ORATAB_FILE" ]]; then
            local mgmt_from_oratab
            mgmt_from_oratab=$(awk -F: -v h="$home" '$2==h && $1 ~ /MGMTDB/ {print $1; exit}' "$ORATAB_FILE")
            if [[ -n "$mgmt_from_oratab" ]]; then
                log "INFO: Correcting MGMTDB SID from '$sid' to '$mgmt_from_oratab' based on /etc/oratab."
                sid="$mgmt_from_oratab"
            else
                log "INFO: Saved MGMTDB SID '$sid' looks like ASM and no MGMTDB entry found ? skipping GI datapatch."
                add_html_row "GI datapatch ($phase)" "WARN" \
                    "No valid MGMTDB SID found (saved SID '$sid' looks like ASM); GI datapatch skipped."
                return
            fi
        else
            log "INFO: Saved MGMTDB SID '$sid' looks like ASM and /etc/oratab not found ? skipping GI datapatch."
            add_html_row "GI datapatch ($phase)" "WARN" \
                "No valid MGMTDB SID found (saved SID '$sid' looks like ASM); GI datapatch skipped."
            return
        fi
    fi

    if [[ -z "$sid" ]]; then
        add_html_row "GI datapatch ($phase)" "WARN" \
            "MGMTDB SID not known; skipping GI datapatch (no ASM OPEN READ WRITE checks performed)."
        return
    fi

    local timeout=120
    local interval=15
    local elapsed=0
    log "Waiting for MGMTDB SID $sid in home $home to be OPEN READ WRITE (timeout ${timeout}s)..."
    while (( elapsed < timeout )); do
        local mode
        mode=$(ORACLE_HOME="$home" ORACLE_SID="$sid" PATH="$home/bin:$PATH" \
            "$home/bin/sqlplus" -s / as sysdba 2>/dev/null <<EOF
set heading off feedback off pages 0 verify off echo off termout off
select open_mode from v\$database;
exit
EOF
)
        mode=$(echo "$mode" | tr -d '\r' | sed -n '1p')
        if [[ "$mode" == "READ WRITE" ]]; then
            log "MGMTDB $sid (home $home) is OPEN READ WRITE ? running datapatch."
            add_html_row "GI datapatch ($phase)" "PASS" \
                "MGMTDB ($sid) is OPEN READ WRITE ? running datapatch from $home."
            run_cmd "ORACLE_HOME=\"$home\" ORACLE_SID=\"$sid\" PATH=\"$home/bin:\$PATH\" \"$home/OPatch/datapatch\" -verbose"
            return
        fi
        log "MGMTDB $sid not yet READ WRITE (current: '$mode'). Waiting..."
        sleep "$interval"
        elapsed=$(( elapsed + interval ))
    done
    log "WARN: Timed out waiting for MGMTDB $sid to open READ WRITE ? GI datapatch skipped."
    add_html_row "GI datapatch ($phase)" "WARN" \
        "MGMTDB ($sid) did not reach OPEN READ WRITE within ${timeout}s ? datapatch skipped."
}
check_asm_running_html() {
    local home="$1"
    local logf="${LOG_DIR}/srvctl_status_asm_$(date +%F_%H%M%S).log"
    local pmon_log="${LOG_DIR}/pmon_snapshot_$(date +%F_%H%M%S).log"

    ps -eo user,pid,cmd | grep '[p]mon_' > "$pmon_log" 2>&1 || true
    add_html_attachment "$pmon_log" "PMON Snapshot"

    if [[ -z "$SRVCTL_BIN" ]]; then
        add_html_row "ASM status" "WARN" \
            "srvctl not available; cannot confirm ASM status from GI. PMON snapshot saved to $pmon_log"
        return
    fi

    local gi_home_for_srvctl
    gi_home_for_srvctl="$(cd "$(dirname "$SRVCTL_BIN")/.." && pwd 2>/dev/null || echo "")"
    [[ -z "$gi_home_for_srvctl" || ! -d "$gi_home_for_srvctl" ]] && gi_home_for_srvctl="$home"

    local timeout=300
    local interval=15
    local elapsed=0
    local asm_running=false

    log "Checking ASM status using SRVCTL_BIN=$SRVCTL_BIN with ORACLE_HOME=$gi_home_for_srvctl (timeout ${timeout}s)..."
    while (( elapsed < timeout )); do
        run_cmd "ORACLE_HOME=\"$gi_home_for_srvctl\" \"$SRVCTL_BIN\" status asm > \"$logf\" 2>&1 || true"
        if grep -qi "is running on" "$logf"; then
            asm_running=true
            break
        fi
        sleep "$interval"
        elapsed=$(( elapsed + interval ))
    done

    add_html_attachment "$logf" "SRVCTL Status ASM"

    if [[ "$asm_running" == true ]]; then
        add_html_row "ASM status" "PASS" \
            "ASM is running as per 'srvctl status asm' (waited ~${elapsed}s). See $logf. PMON snapshot: $pmon_log"
    else
        add_html_row "ASM status" "WARN" \
            "ASM was not reported as running by 'srvctl status asm' within ${timeout}s. See $logf. PMON snapshot: $pmon_log"
    fi
}
# ------------------------------------------------------------
# GI SWITCH / ROLLBACK (19c patching)
# ------------------------------------------------------------
phase_switch_home() {
    reset_report
    reset_html_report
    LOG_FILE="${GI_LOG_DIR}/gi_switch_$(date +%F_%H%M%S).log"
    log "GI SWITCH (19c OOP)"

    if [[ ! -f "$PRECHECK_MARKER" ]]; then
        add_html_row "GI Switch" "FAIL" \
            "Precheck marker missing ($PRECHECK_MARKER). Run GI Precheck + GI Install first."
        send_phase_html_report "GI Switch" "GI Switch FAILED (Precheck Missing) - $HOST" "FAIL"
        log "GI Switch aborted: precheck marker missing."
        return 0
    fi

    add_html_row "GI Switch" "INFO" "Cluster restart / CRS/HAS home switch"

    local mode="${GI_CLUSTER_MODE:-UNKNOWN}"
    [[ "$mode" == "UNKNOWN" ]] && mode=$(detect_gi_cluster_mode)
    GI_CLUSTER_MODE="$mode"
    add_html_row "GI cluster mode (runtime)" "INFO" "$GI_CLUSTER_MODE"

    collect_lspatches "$OLD_GI_HOME" "$NEW_GI_HOME" "Before_Switch"

    add_html_row "rootadd_rdbms.sh" "INFO" "Executing rootadd_rdbms.sh from NEW_GI_HOME"
    run_cmd "sudo ${NEW_GI_HOME}/rdbms/install/rootadd_rdbms.sh || true"

    if [[ "$mode" == "CRS" ]]; then
        add_html_row "GI Switch Mode" "INFO" \
            "CRS/RAC detected ? using gridSetup.sh -switchGridHome then root.sh (cluster/GI downtime)"

        add_html_row "GI Switch pre-step (permissions)" "INFO" \
            "Ensuring NEW_GI_HOME is owned by ${GRID_USER}:${OINSTALL} with 775 permissions before switchGridHome."
        run_cmd "sudo chown -R ${GRID_USER}:${OINSTALL} \"${NEW_GI_HOME}\""
        run_cmd "sudo chmod -R 775 \"${NEW_GI_HOME}\""

        if [[ "$DRYRUN" == true ]]; then
            add_html_row "GI Switch core" "INFO" \
                "DRYRUN ? would run: ORACLE_HOME=${NEW_GI_HOME}; gridSetup.sh -switchGridHome; then sudo ${NEW_GI_HOME}/root.sh"
        else
            local current_node
            current_node=$(hostname)
            run_cmd "ORACLE_HOME=\"${NEW_GI_HOME}\" \"${NEW_GI_HOME}/gridSetup.sh\" \
 -silent -switchGridHome \
 oracle.install.option=CRS_SWONLY \
 ORACLE_HOME=\"${NEW_GI_HOME}\" \
 oracle.install.crs.config.clusterNodes=\"${current_node}\" \
 oracle.install.crs.rootconfig.executeRootScript=false"
            run_cmd "sudo ${NEW_GI_HOME}/root.sh"
        fi
    elif [[ "$mode" == "HAS" ]]; then
        add_html_row "GI Switch Mode" "INFO" \
            "Oracle Restart (HAS) detected ? using roothas.sh -prepatch/-postpatch -dstcrshome ${NEW_GI_HOME} (GI downtime)"
        run_cmd "sudo ${NEW_GI_HOME}/crs/install/roothas.sh -prepatch -dstcrshome ${NEW_GI_HOME}"
        run_cmd "sudo ${NEW_GI_HOME}/crs/install/roothas.sh -postpatch -dstcrshome ${NEW_GI_HOME}"
    else
        add_html_row "GI Switch Mode" "FAIL" \
            "Unable to determine GI cluster mode (HAS/CRS); aborting switch to avoid incorrect procedure."
        send_phase_html_report "GI Switch" "GI Switch FAILED (Unknown cluster mode) - $HOST" "FAIL"
        log "GI Switch aborted: unknown cluster mode."
        return 0
    fi

    add_html_row "OUI update (NEW_GI_HOME)" "INFO" "Setting CRS=TRUE for NEW_GI_HOME"
    run_cmd "sudo -u oracle ${NEW_GI_HOME}/oui/bin/runInstaller -updateNodeList ORACLE_HOME=${NEW_GI_HOME} CRS=TRUE -silent"
    add_html_row "OUI update (OLD_GI_HOME)" "INFO" "Setting CRS=FALSE for OLD_GI_HOME"
    run_cmd "sudo -u oracle ${OLD_GI_HOME}/oui/bin/runInstaller -updateNodeList ORACLE_HOME=${OLD_GI_HOME} CRS=FALSE -silent"

    collect_lspatches "$OLD_GI_HOME" "$NEW_GI_HOME" "After_Switch"

    check_asm_running_html "$NEW_GI_HOME"

    if [[ "$DRYRUN" == false ]]; then
        run_gi_datapatch_for_home "$NEW_GI_HOME" "Switch"
        update_oratab_gi_home "$NEW_GI_HOME"
    else
        add_html_row "GI datapatch (Switch)" "INFO" "DRYRUN: GI datapatch not executed."
    fi

    local msg
    if [[ "$DRYRUN" == true ]]; then
        msg="DRYRUN: GI switch simulated. No changes applied."
    else
        msg="CRS/HAS home successfully switched to NEW_GI_HOME (${NEW_GI_HOME})."
    fi
    add_html_row "GI Switch Result" "PASS" "$msg"
    send_phase_html_report "GI Switch" "GI Switch Report - $HOST" "$PHASE_STATUS"

    # Snapshot homes at switch time so orchestrator can fade old rollback targets.
    if [[ "$DRYRUN" == false && -n "${NEW_GI_HOME:-}" && -n "${OLD_GI_HOME:-}" ]]; then
        echo "[DISCOVERY_JSON] {\"type\":\"home_switched\",\"old_gi_home\":\"${OLD_GI_HOME}\",\"new_gi_home\":\"${NEW_GI_HOME}\",\"old_db_home\":\"\",\"new_db_home\":\"\"}"
    fi
}
phase_rollback() {
    reset_report
    reset_html_report
    LOG_FILE="${GI_LOG_DIR}/gi_rollback_$(date +%F_%H%M%S).log"
    log "GI ROLLBACK (19c OOP)"

    # After a switch, OLD_GI_HOME is now the patched (active) home and ROLLBACK_GI_HOME
    # is the pre-switch home snapshotted at switch time. Swap them so the rollback uses
    # the correct homes: NEW_GI_HOME = currently active (to roll back FROM),
    # OLD_GI_HOME = pre-switch home (to roll back TO).
    if [[ -n "${ROLLBACK_GI_HOME:-}" && "$ROLLBACK_GI_HOME" != "$OLD_GI_HOME" ]]; then
        log "INFO: Using ROLLBACK_GI_HOME=${ROLLBACK_GI_HOME} as rollback target (OLD_GI_HOME was ${OLD_GI_HOME})"
        NEW_GI_HOME="${OLD_GI_HOME}"
        OLD_GI_HOME="${ROLLBACK_GI_HOME}"
    fi

    add_html_row "GI Rollback" "INFO" "Rolling back CRS/HAS home: NEW=${NEW_GI_HOME} → OLD=${OLD_GI_HOME}"

    local mode="${GI_CLUSTER_MODE:-UNKNOWN}"
    [[ "$mode" == "UNKNOWN" ]] && mode=$(detect_gi_cluster_mode)
    GI_CLUSTER_MODE="$mode"
    add_html_row "GI cluster mode (runtime)" "INFO" "$GI_CLUSTER_MODE"

    collect_lspatches "$OLD_GI_HOME" "$NEW_GI_HOME" "Before_Rollback"

    add_html_row "rootadd_rdbms.sh" "INFO" "Executing rootadd_rdbms.sh from NEW_GI_HOME (rollback prep)"
    run_cmd "sudo ${NEW_GI_HOME}/rdbms/install/rootadd_rdbms.sh || true"

    if [[ "$mode" == "CRS" ]]; then
        local configured_home=""
        if [[ -x "$NEW_GI_HOME/srvm/admin/getcrshome" ]]; then
            configured_home=$("$NEW_GI_HOME/srvm/admin/getcrshome" 2>/dev/null || true)
        elif [[ -x "$OLD_GI_HOME/srvm/admin/getcrshome" ]]; then
            configured_home=$("$OLD_GI_HOME/srvm/admin/getcrshome" 2>/dev/null || true)
        fi
        configured_home=$(echo "$configured_home" | tr -d '[:space:]')

        if [[ "$configured_home" == "$NEW_GI_HOME" ]]; then
            add_html_row "Rollback path (CRS)" "INFO" \
                "Configured GI home is NEW_GI_HOME ? using rootcrs.sh -prepatch/-postpatch -dstcrshome OLD_GI_HOME -rollback (GI downtime)"
            run_cmd "sudo ${NEW_GI_HOME}/crs/install/rootcrs.sh -prepatch -dstcrshome ${OLD_GI_HOME} -rollback"
            run_cmd "sudo ${NEW_GI_HOME}/crs/install/rootcrs.sh -postpatch -dstcrshome ${OLD_GI_HOME} -rollback"
        else
            add_html_row "Rollback path (CRS)" "INFO" \
                "Configured GI home is OLD_GI_HOME or unknown ? using rootcrs.sh -prepatch/-postpatch -rollback from OLD_GI_HOME (GI downtime)"
            run_cmd "sudo ${OLD_GI_HOME}/crs/install/rootcrs.sh -prepatch -rollback"
            run_cmd "sudo ${OLD_GI_HOME}/crs/install/rootcrs.sh -postpatch -rollback"
        fi

        add_html_row "OUI inventory update" "INFO" \
            "Restoring OLD_GI_HOME as active home (CRS=TRUE) and marking NEW_GI_HOME as CRS=FALSE in central inventory"
        run_cmd "sudo -u oracle ${NEW_GI_HOME}/oui/bin/runInstaller -updateNodeList ORACLE_HOME=${NEW_GI_HOME} CRS=FALSE -silent || true"
        run_cmd "sudo -u oracle ${OLD_GI_HOME}/oui/bin/runInstaller -updateNodeList ORACLE_HOME=${OLD_GI_HOME} CRS=TRUE -silent"

    elif [[ "$mode" == "HAS" ]]; then
        add_html_row "GI Rollback Mode" "INFO" \
            "Oracle Restart (HAS) detected ? rolling back using roothas.sh to OLD_GI_HOME (GI downtime)"
        run_cmd "sudo ${OLD_GI_HOME}/crs/install/roothas.sh -prepatch -dstcrshome ${OLD_GI_HOME}"
        run_cmd "sudo ${OLD_GI_HOME}/crs/install/roothas.sh -postpatch -dstcrshome ${OLD_GI_HOME}"

        add_html_row "OUI inventory update" "INFO" \
            "Restoring OLD_GI_HOME as active home (CRS=TRUE) and marking NEW_GI_HOME as CRS=FALSE in central inventory"
        run_cmd "sudo -u oracle ${OLD_GI_HOME}/oui/bin/runInstaller -updateNodeList ORACLE_HOME=${OLD_GI_HOME} CRS=TRUE -silent"
        run_cmd "sudo -u oracle ${NEW_GI_HOME}/oui/bin/runInstaller -updateNodeList ORACLE_HOME=${NEW_GI_HOME} CRS=FALSE -silent || true"

    else
        add_html_row "GI Rollback Mode" "FAIL" \
            "Unable to determine GI cluster mode (HAS/CRS); aborting rollback to avoid incorrect procedure."
        send_phase_html_report "GI Rollback" "GI Rollback FAILED (Unknown cluster mode) - $HOST" "FAIL"
        log "GI Rollback aborted: unknown cluster mode."
        return 0
    fi

    collect_lspatches "$OLD_GI_HOME" "$NEW_GI_HOME" "After_Rollback"

    check_asm_running_html "$OLD_GI_HOME"

    if [[ "$DRYRUN" == false ]]; then
        run_gi_datapatch_for_home "$OLD_GI_HOME" "Rollback"
        update_oratab_gi_home "$OLD_GI_HOME"
    else
        add_html_row "GI datapatch (Rollback)" "INFO" "DRYRUN: GI datapatch not executed."
    fi

    local msg
    if [[ "$DRYRUN" == true ]]; then
        msg="DRYRUN: GI rollback simulated. No changes applied."
    else
        msg="CRS/HAS home successfully rolled back to OLD_GI_HOME (${OLD_GI_HOME})."
    fi
    add_html_row "GI Rollback Result" "PASS" "$msg"

    send_phase_html_report "GI Rollback" "GI Rollback Report - $HOST" "$PHASE_STATUS"
}
# ------------------------------------------------------------
# NEW: GI UPGRADE (19c -> 23/26ai)
# ------------------------------------------------------------
get_cluster_nodes() {
    if command -v olsnodes >/dev/null 2>&1; then
        olsnodes 2>/dev/null || true
    else
        echo "$(hostname -s)"
    fi
}
# ------------------------------------------------------------
# GI UPGRADE PRECHECK (19c -> 23/26ai)
# ------------------------------------------------------------
gi_upgrade_precheck() {
    reset_html_report
    LOG_FILE="${GI_UPGRADE_LOG_DIR}/gi_upgrade_precheck_$(date +%F_%H%M%S).log"
    log "GI UPGRADE PRECHECK (19c -> 23/26ai)"
	assert_precheck_homes_safe

    # First, run the same basic GI health checks as gi_precheck (no software staging here)
    check_at_service_html

    local gi_fs db_fs
    gi_fs=$(df -P "$OLD_GI_HOME" 2>/dev/null | awk 'NR==2{print $6}' || true)
    db_fs=$(df -P "$OLD_DB_HOME" 2>/dev/null | awk 'NR==2{print $6}' || true)
    if [[ -n "$gi_fs" ]]; then
        check_space_html "$gi_fs" 20
    else
        add_html_row "Filesystem space for OLD_GI_HOME" "WARN" "Could not determine filesystem for $OLD_GI_HOME"
    fi
    if [[ -n "$db_fs" ]]; then
        check_space_html "$db_fs" 30
    else
        add_html_row "Filesystem space for OLD_DB_HOME" "WARN" "Could not determine filesystem for $OLD_DB_HOME"
    fi

    check_oracle_sudo_nopass_html
    detect_cluster_type_html
    GI_CLUSTER_MODE=$(detect_gi_cluster_mode)
    add_html_row "GI cluster mode (automation)" "INFO" "$GI_CLUSTER_MODE"

    local oratab_html
    oratab_html=$(format_oratab_html "$OLD_GI_HOME")
    add_html_row "/etc/oratab entries" "INFO" "$oratab_html"

    local gi_patch
    gi_patch=$(get_patch_level "$OLD_GI_HOME")
    add_html_row "GI patch level (OLD_GI_HOME)" "INFO" "$gi_patch"

    OLD_GI_OSOPER_GROUP=$(get_old_gi_osoper_group)
    add_html_row "GI OSOPER group (19c config.c)" "INFO" \
       "${OLD_GI_OSOPER_GROUP:-<empty>}"
    
    # GI CVU precheck (HAS/CRS)
    check_gi_cvu_preinstall "$OLD_GI_HOME" "$GI_CLUSTER_MODE"

    # ------------------------------------------------------------------
    # ASM SPFILE status (using OLD_GI_HOME, SYSASM)
    # ------------------------------------------------------------------
    check_asm_spfile_status_html "$OLD_GI_HOME"

    # ------------------------------------------------------------------
    # Build 23/26ai GI rsp (uses cluster type, nodes, sudoPath)
    # ------------------------------------------------------------------
    write_gi_23ai_rsp

    # Summarise root.sh mode / sudo path
    local sudo_path_val="/usr/bin/sudo"
    add_html_row "sudoPath (GI upgrade)" "INFO" \
        "GI_USE_SUDO_FOR_ROOT=${GI_USE_SUDO_FOR_ROOT:-true}, sudoPath=${sudo_path_val:-<not found>} in rsp when enabled"
    add_html_row "Root script mode (GI upgrade)" "INFO" \
        "executeRootScript=$( [[ ${GI_USE_SUDO_FOR_ROOT:-true} == true ]] && echo true || echo false )"

    # ------------------------------------------------------------------
    # ASM compatible.rdbms (read-only report using OLD_GI_HOME)
    # ------------------------------------------------------------------
    local asm_sql="${GI_UPGRADE_LOG_DIR}/gi_upgrade_asm_compat_$(date +%F_%H%M%S).sql"
    local asm_log="${asm_sql%.sql}.log"

    # Note: v\$asm_diskgroup inside the here-doc to avoid Bash expansion.
    cat > "$asm_sql" <<'EOF'
set lines 200
col name                  for a30
col compatibility         for a20
col database_compatibility for a20
select name,
       compatibility,
       database_compatibility
  from v$asm_diskgroup
 order by name;
exit
EOF

    # Discover ASM SID(s) from PMON first
    local asm_sids=()
    local p_asm
    p_asm=$(ps -eo args | awk -F'pmon_' '/pmon_/ {print $2}' | sed 's/ .*$//' | grep '^+ASM' || true)
    if [[ -n "$p_asm" ]]; then
        while IFS= read -r s; do
            [[ -n "$s" ]] && asm_sids+=( "$s" )
        done <<< "$p_asm"
    fi
    # Fallback only if PMON gave us nothing
    if [[ ${#asm_sids[@]} -eq 0 ]]; then
        asm_sids+=( "+ASM1" "+ASM" )
    fi

    local asm_ok=false
    for sid in "${asm_sids[@]}"; do
        ORACLE_HOME="$OLD_GI_HOME" \
        ORACLE_SID="$sid" \
        PATH="$OLD_GI_HOME/bin:$PATH" \
        "$OLD_GI_HOME/bin/sqlplus" -s / as sysasm @"$asm_sql" > "$asm_log" 2>&1 || true

        # Success = at least one non-header, non-separator, non-SQL*Plus line
        # that looks like: NAME COMPAT DB_COMPAT
        if ! grep -q "ORA-01034" "$asm_log" 2>/dev/null && \
           grep -qE '^[[:alnum:]_]+\s+[0-9]+\.[0-9]+\.[0-9]+' "$asm_log" 2>/dev/null; then
            asm_ok=true
            break
        fi
    done

    add_attachment "$asm_log"

    if [[ "$asm_ok" != true ]]; then
        # Automation could not reliably parse any diskgroup compatibility rows.
        # Do NOT claim "could not query ASM" if there is content; just say inconclusive.
        add_html_row "ASM compatible.rdbms" "WARN" \
            "ASM compatibility check was inconclusive in automation (no usable diskgroup rows parsed from v\\\$asm_diskgroup).<br/>\
            Please review the attached ASM log:<br/>\
            <code>$asm_log</code><br/>\
            and manually confirm diskgroup compatibility before GI upgrade:<br/>\
            <code>sqlplus / as sysasm</code><br/>\
            <code>SELECT name, compatibility, database_compatibility FROM v\\\$asm_diskgroup;</code><br/>\
            For any diskgroup where <code>database_compatibility</code> &lt; 19.0.0.0.0, run:<br/>\
            <code>ALTER DISKGROUP &lt;DG_NAME&gt; SET ATTRIBUTE 'compatible.rdbms'='19.0.0.0.0';</code>"
        else
    # Parse diskgroups and database_compatibility values out of asm_log
    local bad_dgs_html="" good_dgs_html=""
    # Filter out blank lines first
    local asm_log_filtered
    asm_log_filtered="$(grep -v -E '^[[:space:]]*$' "$asm_log" 2>/dev/null || true)"

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        # Skip obvious headers / separators / prompts
        if [[ "$line" == NAME* ]] || \
           [[ "$line" =~ ^-+$ ]] || \
           [[ "$line" =~ ^SQL\> ]]; then
            continue
        fi

        # Example data row:
        # DATA               19.0.0.0.0        19.0.0.0.0
        local dg_name dg_compat dg_dbcompat
        dg_name=$(echo "$line" | awk '{print $1}')
        dg_compat=$(echo "$line" | awk '{print $2}')
        dg_dbcompat=$(echo "$line" | awk '{print $3}')

        # Must have all 3 tokens
        [[ -z "$dg_name" || -z "$dg_dbcompat" ]] && continue

        # Only accept rows where the 3rd column *looks* like a version (N.N.N.N.N)
        if ! [[ "$dg_dbcompat" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            continue
        fi

        if [[ "$dg_dbcompat" < "19.0.0.0.0" ]]; then
            bad_dgs_html+="- ${dg_name}: database_compatibility=${dg_dbcompat} (compat=${dg_compat})<br/>"
        else
            good_dgs_html+="- ${dg_name}: database_compatibility=${dg_dbcompat} (compat=${dg_compat})<br/>"
        fi
    done <<< "$asm_log_filtered"

    if [[ -n "$bad_dgs_html" ]]; then
        add_html_row "ASM compatible.rdbms" "WARN" \
            "The following ASM diskgroups have database_compatibility &lt; 19.0.0.0.0:<br/>\
            ${bad_dgs_html}<br/>\
            Engineer MUST fix before upgrade:<br/>\
            <code>sqlplus / as sysasm</code><br/>\
            <code>SELECT name, compatibility, database_compatibility FROM v\\\$asm_diskgroup;</code><br/>\
            For each affected DG, run:<br/>\
            <code>ALTER DISKGROUP &lt;DG_NAME&gt; SET ATTRIBUTE 'compatible.rdbms'='19.0.0.0.0';</code><br/>\
            See $asm_log for full output."
    else
        local details="ASM diskgroups queried successfully from v\\\$asm_diskgroup. All listed diskgroups have database_compatibility >= 19.0.0.0.0.<br/>"
        if [[ -n "$good_dgs_html" ]]; then
            details+="Current values:<br/>${good_dgs_html}"
        fi
        details+="See $asm_log for the full query output."
        add_html_row "ASM compatible.rdbms" "PASS" "$details"
    fi
fi

    # ------------------------------------------------------------------
    # Stage 23/26ai GI software into a TEMP precheck home & run executePrereqs
    # ------------------------------------------------------------------
    local gi_upgrade_pre_home="${GI_UPGRADE_NEW_HOME}-precheck"
    local preq_log="${GI_UPGRADE_LOG_DIR}/gridSetup_23ai_prereq_$(date +%F_%H%M%S).log"

    if [[ -x "$gi_upgrade_pre_home/gridSetup.sh" ]]; then
        add_html_row "GI 23/26ai precheck home" "INFO" \
            "Using existing staged precheck home: $gi_upgrade_pre_home"
    else
        if [[ ! -f "$GI_UPGRADE_BASE_ZIP" ]]; then
            add_html_row "GI 23/26ai software" "WARN" \
                "GI_UPGRADE_BASE_ZIP ($GI_UPGRADE_BASE_ZIP) not found; cannot stage 23/26ai GI software for executePrereqs."
            add_html_row "GI 23/26ai executePrereqs" "INFO" \
                "Skipped: 23/26ai GI software not staged (no gridSetup.sh in $gi_upgrade_pre_home)."
            send_html_report "GI Upgrade Precheck - $HOST" "GI Upgrade Precheck"
            return 0
        fi
        add_html_row "GI 23/26ai precheck home" "INFO" \
            "Staging 23/26ai GI software from $GI_UPGRADE_BASE_ZIP into $gi_upgrade_pre_home for executePrereqs only."
        run_cmd "sudo mkdir -p \"$gi_upgrade_pre_home\""
        run_cmd "sudo chown -R ${GRID_USER}:${OINSTALL} \"$gi_upgrade_pre_home\""
        run_cmd "unzip -oq \"$GI_UPGRADE_BASE_ZIP\" -d \"$gi_upgrade_pre_home\""
    fi

    if [[ ! -x "$gi_upgrade_pre_home/gridSetup.sh" ]]; then
        add_html_row "GI 23/26ai executePrereqs" "WARN" \
            "gridSetup.sh not found in $gi_upgrade_pre_home even after staging; -executePrereqs skipped."
        send_html_report "GI Upgrade Precheck - $HOST" "GI Upgrade Precheck"
        return 0
    fi

    run_cmd "sudo -u \"$GRID_USER\" \"$gi_upgrade_pre_home/gridSetup.sh\" -silent -executePrereqs -responseFile \"$GI_UPGRADE_RSP\" > \"$preq_log\" 2>&1 || true"
    add_attachment "$preq_log"

    # Attach central GridSetupActions log if present
    local inv_root inv_log
    if [[ -f /etc/oraInst.loc ]]; then
        inv_root=$(awk -F= '/inventory_loc/ {gsub(/[[:space:]]*/, "", $2); print $2}' /etc/oraInst.loc)
        inv_log=$(find "$inv_root/logs" -type f -name 'gridSetupActions*.log' -printf '%T@ %p\n' 2>/dev/null \
                  | sort -nr | awk 'NR==1{print $2}')
        if [[ -n "$inv_log" && -f "$inv_log" ]]; then
            add_attachment "$inv_log"
            add_html_row "GI 23/26ai GridSetupActions log" "INFO" \
                "Central inventory prereq log attached: $(basename "$inv_log")."
        else
            add_html_row "GI 23/26ai GridSetupActions log" "INFO" \
                "No gridSetupActions*.log found under $inv_root/logs at precheck time."
        fi
    else
        add_html_row "GI 23/26ai GridSetupActions log" "INFO" \
            "/etc/oraInst.loc not found; cannot auto-attach central GridSetupActions log."
    fi

    local pkg_issues=""
    pkg_issues=$(grep -E 'PRVF-7532|Package:' "$preq_log" 2>/dev/null || true)
    local kernel_issues=""
    kernel_issues=$(grep -E 'PRVG-1205|kernel.panic' "$preq_log" 2>/dev/null || true)

    if [[ -n "$pkg_issues" || -n "$kernel_issues" ]]; then
        local details=""
        [[ -n "$pkg_issues" ]] && details+="<b>Package issues:</b><br/>$(printf '%s\n' "$pkg_issues" | sed 's/$/<br\/>/')<br/>"
        [[ -n "$kernel_issues" ]] && details+="<b>Kernel issues:</b><br/>$(printf '%s\n' "$kernel_issues" | sed 's/$/<br\/>/')<br/>"
        add_html_row "GI 23/26ai executePrereqs" "WARN" \
            "gridSetup.sh -executePrereqs reported WARN/FAIL. See $preq_log.<br/>${details}"
    else
        add_html_row "GI 23/26ai executePrereqs" "PASS" \
            "gridSetup.sh -executePrereqs completed with no critical issues. See $preq_log."
    fi

    # Optional: clean up the staged precheck home
    if [[ -d "$gi_upgrade_pre_home" ]]; then
    add_html_row "GI 23/26ai precheck cleanup" "INFO" \
        "Removing 23/26ai precheck home $gi_upgrade_pre_home to free space."
    safe_rm_rf "$gi_upgrade_pre_home" true
    fi

    send_html_report "GI Upgrade Precheck - $HOST" "GI Upgrade Precheck"
}
gi_upgrade_install() {
    reset_html_report
    LOG_FILE="${GI_UPGRADE_LOG_DIR}/gi_upgrade_install_$(date +%F_%H%M%S).log"
    log "GI UPGRADE INSTALL (23/26ai software)"

    # Build 23/26ai GI rsp (uses cluster type, nodes, sudoPath)
    write_gi_23ai_rsp

    # Validate base ZIP
    if [[ ! -f "$GI_UPGRADE_BASE_ZIP" ]]; then
        add_html_row "GI 23/26ai Base ZIP" "FAIL" \
            "Missing GI_UPGRADE_BASE_ZIP: $GI_UPGRADE_BASE_ZIP"
        send_html_report "GI Upgrade Install FAILED - $HOST" "GI Upgrade Install"
        die "GI_UPGRADE_BASE_ZIP missing: $GI_UPGRADE_BASE_ZIP"
    fi
    add_html_row "GI 23/26ai Base ZIP" "PASS" "$GI_UPGRADE_BASE_ZIP"

    # Stage 23/26ai GI software
    run_cmd "sudo mkdir -p \"$GI_UPGRADE_NEW_HOME\""
    run_cmd "sudo chown -R ${GRID_USER}:${OINSTALL} \"$GI_UPGRADE_NEW_HOME\""
    run_cmd "unzip -oq \"$GI_UPGRADE_BASE_ZIP\" -d \"$GI_UPGRADE_NEW_HOME\""

    local grid_log="${GI_UPGRADE_LOG_DIR}/gridSetup_23ai_install_$(date +%F_%H%M%S).log"

    if [[ "$DRYRUN" == true ]]; then
        add_html_row "GI Upgrade Install (dry-run)" "INFO" \
            "Would run $GI_UPGRADE_NEW_HOME/gridSetup.sh -silent -ignorePrereqFailure -responseFile $GI_UPGRADE_RSP -waitForCompletion"
        send_html_report "GI Upgrade Install (Dry-run) - $HOST" "GI Upgrade Install"
        return 0
    fi

    log "Starting 23/26ai GI Software Install. Installer log will be in ${grid_log}"

    # Run installer in background (like db_install)
    sudo -u "$GRID_USER" bash -c "yes randn_pass | \
        \"$GI_UPGRADE_NEW_HOME/gridSetup.sh\" \
            -silent -ignorePrereqFailure \
            -responseFile \"$GI_UPGRADE_RSP\" \
            -waitForCompletion" \
        &> "$grid_log" &

    local installer_pid=$!
    local timeout_seconds=7200
    local poll_interval=10
    local elapsed=0
    local installer_rc=0
    local failure_reason="Unknown failure"

    log "Monitoring 23/26ai GI installer (PID=$installer_pid) with timeout ${timeout_seconds}s..."
    while (( elapsed < timeout_seconds )); do
        # Only bail early for obvious errors
        if [[ -f "$grid_log" ]] && grep -qi "error" "$grid_log" 2>/dev/null; then
            failure_reason="Error string detected in 23/26ai installer log. See $grid_log"
            break
        fi

        if ! kill -0 "$installer_pid" 2>/dev/null; then
            wait "$installer_pid" || installer_rc=$?
            break
        fi

        sleep "$poll_interval"
        elapsed=$(( elapsed + poll_interval ))
    done

    if (( elapsed >= timeout_seconds )) && kill -0 "$installer_pid" 2>/dev/null; then
        failure_reason="Timeout after ${timeout_seconds}s waiting for 23/26ai GI installer. See $grid_log"
        kill "$installer_pid" 2>/dev/null || true
        wait "$installer_pid" || installer_rc=$?
    fi

    add_attachment "$grid_log"

    # Final decision: inspect log and RC
    local status_msg=""
    local has_success=false
    local has_warnings=false

    if grep -qi "Successfully Setup Software with warning(s)" "$grid_log" 2>/dev/null; then
        status_msg="Successfully Setup Software with warning(s)"
        has_success=true
        has_warnings=true
    elif grep -qi "Successfully Setup Software" "$grid_log" 2>/dev/null; then
        status_msg="Successfully Setup Software"
        has_success=true
    fi

    # CASE 1: success string present and RC is acceptable (0 or 6)
    if [[ "$has_success" == true ]] && { (( installer_rc == 0 )) || (( installer_rc == 6 )); }; then
        add_html_row "GI Upgrade Software Install" "PASS" \
            "$status_msg. See $grid_log"

        # Root.sh instructions in email when executeRootScript=false
        if [[ "${GI_USE_SUDO_FOR_ROOT:-true}" != true ]]; then
            local root_script=""
            root_script=$(awk '/As a root user, run the following script\(s\):/{flag=1;next}/^Successfully Setup Software/{flag=0}flag' "$grid_log" 2>/dev/null | \
                          awk '/root\.sh/ {print $1; exit}' || true)

            local nodes_line=""
            nodes_line=$(awk '/Run .*root\.sh on the following nodes:/{getline; gsub(/[\[\]]/,""); print}' "$grid_log" 2>/dev/null || true)

            if [[ -n "$root_script" ]]; then
                if [[ -n "$nodes_line" ]]; then
                    add_html_row "root.sh execution (GI upgrade install)" "WARN" \
                        "GI_USE_SUDO_FOR_ROOT=false  Installer did NOT run root.sh.<br/>\
                         As root, run:<br/>\
                         <code>${root_script}</code><br/>\
                         on the following node(s):<br/>\
                         <code>${nodes_line}</code><br/>\
                         See $grid_log for full context."
                else
                    add_html_row "root.sh execution (GI upgrade install)" "WARN" \
                        "GI_USE_SUDO_FOR_ROOT=false  Installer did NOT run root.sh.<br/>\
                         As root, run:<br/>\
                         <code>${root_script}</code><br/>\
                         on this node. See $grid_log for full context."
                fi
            else
                add_html_row "root.sh execution (GI upgrade install)" "WARN" \
                    "GI_USE_SUDO_FOR_ROOT=false  Installer did NOT run root.sh.<br/>\
                     Refer to $grid_log for the exact root.sh command and node list."
            fi
        else
            add_html_row "root.sh execution (GI upgrade install)" "INFO" \
                "GI_USE_SUDO_FOR_ROOT=true  executeRootScript=true with SUDO. Root scripts were driven by Oracle installer (see $grid_log)."
        fi

        send_html_report "GI Upgrade Install - $HOST" "GI Upgrade Install"
        log "23/26ai GI installer completed successfully (RC=${installer_rc}) with status: $status_msg"
        return 0
    fi

    # CASE 2: no success string; treat as failure regardless of RC
    if [[ "$has_success" != true ]]; then
        if (( installer_rc == 0 )); then
            failure_reason="23/26ai installer RC=0 but no 'Successfully Setup Software' found in log. See $grid_log"
        else
            failure_reason="23/26ai installer exited with RC=${installer_rc} and no success string. See $grid_log"
        fi
    fi

    add_html_row "GI Upgrade Software Install" "FAIL" \
        "$failure_reason. See $grid_log"
    send_html_report "GI Upgrade Install FAILED - $HOST" "GI Upgrade Install (FAILED)"
    log "23/26ai GI installer failed: $failure_reason"
    die "$failure_reason"
}
gi_upgrade_upgrade() {
    reset_html_report
    LOG_FILE="${GI_UPGRADE_LOG_DIR}/gi_upgrade_upgrade_$(date +%F_%H%M%S).log"
    log "GI UPGRADE (19c -> 23/26ai)"

    write_gi_23ai_upgrade_rsp

    add_html_row "GI Upgrade" "INFO" \
        "Will perform GI upgrade using $GI_UPGRADE_NEW_HOME and response $GI_UPGRADE_RSP_UPGRADE."

    # Stop DBs first (srvctl if available, else PMON-based SID shutdown)
    stop_all_dbs_for_gi_upgrade

    if [[ "$DRYRUN" == true ]]; then
        add_html_row "GI Upgrade (dry-run)" "INFO" \
            "Would run: yes randn_pass | $GI_UPGRADE_NEW_HOME/gridSetup.sh -silent -responseFile $GI_UPGRADE_RSP_UPGRADE -waitForCompletion"
        send_html_report "GI Upgrade (Dry-run) - $HOST" "GI Upgrade"
        return 0
    fi

    local upg_log="${GI_UPGRADE_LOG_DIR}/gridSetup_23ai_upgrade_$(date +%F_%H%M%S).log"

    log "Starting 23/26ai GI UPGRADE. Log: $upg_log"

    # Run gridSetup.sh in background and monitor with a timeout so we don't hang forever
    sudo -u "$GRID_USER" bash -c "yes randn_pass | \
        \"$GI_UPGRADE_NEW_HOME/gridSetup.sh\" \
            -silent \
            -responseFile \"$GI_UPGRADE_RSP_UPGRADE\" \
            -waitForCompletion" \
        &> "$upg_log" &

    local installer_pid=$!
    local timeout_seconds=7200     # 2 hours
    local poll_interval=10
    local elapsed=0
    local installer_rc=0
    local finished=false

    while (( elapsed < timeout_seconds )); do
        if ! kill -0 "$installer_pid" 2>/dev/null; then
            # process finished
            wait "$installer_pid" || installer_rc=$?
            finished=true
            break
        fi
        sleep "$poll_interval"
        elapsed=$(( elapsed + poll_interval ))
    done

    if [[ "$finished" != true ]]; then
        # Timed out - kill process and mark as failure
        log "WARN: GI upgrade timed out after ${timeout_seconds}s. Killing installer PID=$installer_pid."
        kill "$installer_pid" 2>/dev/null || true
        wait "$installer_pid" 2>/dev/null || true
        installer_rc=124
    fi

    # Attach the log file regardless of success/failure
    add_attachment "$upg_log"

    local status_msg=""
    local has_success=false
    local has_warnings=false

    if grep -qi "Successfully Setup Software with warning(s)" "$upg_log" 2>/dev/null; then
        status_msg="Successfully Setup Software with warning(s)"
        has_success=true
        has_warnings=true
    elif grep -qi "Successfully Setup Software" "$upg_log" 2>/dev/null; then
        status_msg="Successfully Setup Software"
        has_success=true
    fi

    #
    # SUCCESS PATH
    #
    if [[ "$has_success" == true ]] && { (( installer_rc == 0 )) || (( installer_rc == 6 )); }; then
        add_html_row "GI Upgrade" "PASS" \
            "$status_msg. Log: $upg_log"

        if [[ "${GI_USE_SUDO_FOR_ROOT:-true}" != true ]]; then
            local nodes
            nodes=$(get_cluster_nodes | sed '/^$/d' | sort || true)
            local count
            count=$(printf '%s\n' "$nodes" | wc -l)

            if (( count <= 1 )); then
                add_html_row "root.sh execution" "WARN" \
                    "GI_USE_SUDO_FOR_ROOT=false  Installer did NOT run root.sh.<br/>\
                 Run <code>${GI_UPGRADE_NEW_HOME}/root.sh</code> manually as root on this node."
            elif (( count == 2 )); then
                local n1 n2
                n1=$(printf '%s\n' "$nodes" | sed -n '1p')
                n2=$(printf '%s\n' "$nodes" | sed -n '2p')
                add_html_row "root.sh execution (2-node RAC)" "WARN" \
                    "GI_USE_SUDO_FOR_ROOT=false  Installer did NOT run root.sh.<br/>\
                 Recommended sequence:<br/>\
                 1) On node <b>${n1}</b>: run <code>${GI_UPGRADE_NEW_HOME}/root.sh</code> as root.<br/>\
                 2) On node <b>${n2}</b> (last node): run <code>${GI_UPGRADE_NEW_HOME}/root.sh</code> as root."
            else
                add_html_row "root.sh execution (multi-node RAC)" "WARN" \
                    "GI_USE_SUDO_FOR_ROOT=false  Installer did NOT run root.sh.<br/>\
                 Run <code>${GI_UPGRADE_NEW_HOME}/root.sh</code> as root on each cluster node in the documented sequence."
            fi
        else
            add_html_row "root.sh execution" "INFO" \
                "GI_USE_SUDO_FOR_ROOT=true  executeRootScript=true with SUDO. Root scripts were driven by Oracle installer (see $upg_log)."
        fi

        # Restart DBs that were stopped for GI upgrade (only if ASM is up)
        start_all_dbs_after_gi_upgrade

        # Ensure ASM oratab entry exists for the upgraded GI home
        ensure_asm_oratab_entry_for_gi_home "$GI_UPGRADE_NEW_HOME"

        send_html_report "GI Upgrade - $HOST" "GI Upgrade"
        log "23/26ai GI UPGRADE completed (RC=${installer_rc}) with status: $status_msg"
        return 0
    fi

    #
    # FAILURE PATH – parse known Oracle prereq errors, but ALWAYS send mail with attachment
    #
    local failure_reason=""
    local asm_compat_block=""
    local asm_ds_block=""
    local kernel_panic_block=""
    local pkg_block=""

    # ASM compatible.rdbms (PRVE-3180)
    if grep -q "PRVE-3180" "$upg_log" 2>/dev/null; then
        asm_compat_block=$(grep -A5 "PRVE-3180" "$upg_log" 2>/dev/null | sed 's/$/<br\/>/' || true)
        add_html_row "ASM compatible.rdbms" "FAIL" \
            "Oracle upgrade prereq reported PRVE-3180 on one or more diskgroups:<br/>\
             ${asm_compat_block}<br/>\
             Action:<br/>\
             <code>sqlplus / as sysasm</code><br/>\
             <code>SELECT name, compatibility, database_compatibility FROM v\\\$asm_diskgroup;</code><br/>\
             For each DG with database_compatibility &lt; 19.0.0.0.0, run:<br/>\
             <code>ALTER DISKGROUP &lt;DG_NAME&gt; SET ATTRIBUTE 'compatible.rdbms'='19.0.0.0.0';</code>"
    fi

    # ASM discovery string mismatch (PRVG-4654)
    if grep -q "PRVG-4654" "$upg_log" 2>/dev/null; then
        asm_ds_block=$(grep -A5 "PRVG-4654" "$upg_log" 2>/dev/null | sed 's/$/<br\/>/' || true)
        add_html_row "ASM discovery string" "FAIL" \
            "Oracle upgrade prereq reported PRVG-4654 (ASM discovery string mismatch):<br/>\
             ${asm_ds_block}<br/>\
             Action:<br/>\
             <code>export ORACLE_HOME=$OLD_GI_HOME; export ORACLE_SID=+ASM1</code><br/>\
             <code>asmcmd dsget</code><br/>\
             <code>asmcmd dsset \"/dev/oracleasm/*\"</code>"
    fi

    # kernel.panic (PRVG-1205)
    if grep -q "PRVG-1205" "$upg_log" 2>/dev/null; then
        kernel_panic_block=$(grep -A5 "PRVG-1205" "$upg_log" 2>/dev/null | sed 's/$/<br\/>/' || true)
        add_html_row "kernel.panic parameter" "WARN" \
            "Oracle upgrade prereq reported PRVG-1205 for kernel.panic:<br/>\
             ${kernel_panic_block}<br/>\
             Action:<br/>\
             <code>sysctl -w kernel.panic=1</code><br/>\
             and persist via /etc/sysctl.conf if required."
    fi

    # Missing packages (PRVF-7532)
    if grep -q "PRVF-7532" "$upg_log" 2>/dev/null; then
        pkg_block=$(grep -A5 "PRVF-7532" "$upg_log" 2>/dev/null | sed 's/$/<br\/>/' || true)
        add_html_row "Missing OS packages" "WARN" \
            "Oracle upgrade prereq reported PRVF-7532 (missing packages):<br/>\
             ${pkg_block}<br/>\
             Action: Install the listed RPMs (e.g. compat-openssl10, fontconfig)."
    fi

    # Compose top-level failure reason
    if [[ -n "$asm_compat_block" ]]; then
        failure_reason="GI upgrade blocked by ASM compatible.rdbms (PRVE-3180). See HTML rows and $upg_log."
    elif [[ -n "$asm_ds_block" ]]; then
        failure_reason="GI upgrade blocked by ASM discovery string mismatch (PRVG-4654). See HTML rows and $upg_log."
    elif (( installer_rc == 124 )); then
        failure_reason="GI upgrade timed out after ${timeout_seconds}s. See $upg_log."
    else
        if (( installer_rc == 0 )); then
            failure_reason="gridSetup.sh RC=0 but no 'Successfully Setup Software' string in log. See $upg_log"
        else
            failure_reason="gridSetup.sh exited with RC=${installer_rc} and no success string. See $upg_log"
        fi
    fi

    add_html_row "GI Upgrade" "FAIL" "$failure_reason<br/>Log: $upg_log"

    # Attempt to restart DBs that were stopped (if ASM is up)
    start_all_dbs_after_gi_upgrade

    # Always send the mail, with the logfile attached
    send_html_report "GI Upgrade FAILED - $HOST" "GI Upgrade (FAILED)"
    log "23/26ai GI upgrade failed: $failure_reason"

    die "$failure_reason"
}
# ------------------------------------------------------------
# LIST/CANCEL SCHEDULED JOBS
# ------------------------------------------------------------
list_orchestrator_jobs() {
    ensure_at_service
    local found=false
    echo "========================================"
    echo " Scheduled GI/DB Switch Jobs (at)"
    echo "========================================"
    printf "%-6s %-24s %-12s\n" "ID" "When" "Type"
    echo "----------------------------------------"

    # Capture atq output first to avoid bash process substitution (MEC-safe)
    local atq_out
    atq_out=$(atq 2>/dev/null || true)

    if [[ -n "$atq_out" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue

            local id when
            id=$(awk '{print $1}' <<<"$line")
            when=$(awk '{print $2, $3, $4, $5, $6}' <<<"$line")

            local cmd
            cmd=$(at -c "$id" 2>/dev/null | grep -F "$SCRIPT_PATH gi_switch_scheduled" || \
                  at -c "$id" 2>/dev/null | grep -F "$SCRIPT_PATH db_switch_scheduled" || true)
            if [[ -z "$cmd" ]]; then
                continue
            fi

            local type="UNKNOWN"
            if grep -Fq "$SCRIPT_PATH gi_switch_scheduled" <<<"$cmd"; then
                type="GI_SWITCH"
            elif grep -Fq "$SCRIPT_PATH db_switch_scheduled" <<<"$cmd"; then
                type="DB_SWITCH"
            fi

            found=true
            printf "%-6s %-24s %-12s\n" "$id" "$when" "$type"
        done <<< "$atq_out"
    fi

    if [[ "$found" != true ]]; then
        echo "No scheduled GI/DB switch jobs found for this orchestrator."
        echo
        sleep 2
        return 0
    fi
    echo
    read -rp "Enter job ID to cancel (or press Enter to leave unchanged): " jid
    if [[ -z "$jid" ]]; then
        echo "No job cancelled."
        sleep 2
        return 0
    fi
    run_cmd "atrm $jid"
    echo "Job $jid cancelled."
    sleep 2
}
# ------------------------------------------------------------
# GI SCHEDULING
# ------------------------------------------------------------
schedule_gi_switch() {
    ensure_at_service
    read -rp "Enter GI switch schedule datetime (YYYY-MM-DD HH:MM): " sched_time
    if [[ ! "$sched_time" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})[[:space:]]([0-9]{2}):([0-9]{2})$ ]]; then
        echo "Invalid format. Use: YYYY-MM-DD HH:MM"
        sleep 2
        return 0
    fi
    local year="${BASH_REMATCH[1]}"
    local month="${BASH_REMATCH[2]}"
    local day="${BASH_REMATCH[3]}"
    local hour="${BASH_REMATCH[4]}"
    local minute="${BASH_REMATCH[5]}"
    local at_time="${hour}:${minute} ${month}/${day}/${year}"
    local out jobid
    out=$(echo "$SCRIPT_PATH gi_switch_scheduled" | at "$at_time" 2>&1)
    jobid=$(awk '/job/{print $2}' <<<"$out" || true)
    log "GI switch scheduled for $sched_time (jobid=${jobid:-unknown})"
    echo "GI switch scheduled for $sched_time (jobid=${jobid:-unknown})"
    sleep 2
}
schedule_gi_upgrade() {
    ensure_at_service
    echo "Scheduling GI upgrade (gridSetup.sh -upgrade):"
    read -rp "Enter GI upgrade switch schedule datetime (YYYY-MM-DD HH:MM): " sched_time

    if [[ ! "$sched_time" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})[[:space:]]([0-9]{2}):([0-9]{2})$ ]]; then
        echo "Invalid format. Use: YYYY-MM-DD HH:MM"
        sleep 2
        return 0
    fi

    local year="${BASH_REMATCH[1]}"
    local month="${BASH_REMATCH[2]}"
    local day="${BASH_REMATCH[3]}"
    local hour="${BASH_REMATCH[4]}"
    local minute="${BASH_REMATCH[5]}"
    local at_time="${hour}:${minute} ${month}/${day}/${year}"

    # You advertised this as [gi_upgrade_upgrade_scheduled] in the menu,
    # so schedule that wrapper phase (see CLI case below).
    local out jobid
    out=$(echo "$SCRIPT_PATH gi_upgrade_upgrade_scheduled" | at "$at_time" 2>&1)
    jobid=$(awk '/job/{print $2}' <<<"$out" || true)

    log "GI upgrade (switch) scheduled for $sched_time (jobid=${jobid:-unknown})"
    echo "GI upgrade (switch) scheduled for $sched_time (jobid=${jobid:-unknown})"
    sleep 2
}
# ------------------------------------------------------------
# DB PRECHECK: SQL-based discovery (runs only if a DB is up)
# ------------------------------------------------------------
db_sql_discovery_html() {
    local sid="$1"
    local oracle_home="$2"
    log "Running SQL discovery for SID=$sid ORACLE_HOME=$oracle_home"

    local sqlplus_bin="$oracle_home/bin/sqlplus"
    if [[ ! -x "$sqlplus_bin" ]]; then
        add_html_row "DB SQL Discovery" "WARN" "sqlplus not found at $sqlplus_bin — skipping SQL checks."
        return 0
    fi

    # Single sqlplus session — all queries in one pass
    local sql_output
    sql_output=$(ORACLE_SID="$sid" ORACLE_HOME="$oracle_home" \
        PATH="$oracle_home/bin:$PATH" \
        "$sqlplus_bin" -S / as sysdba 2>/dev/null <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF TRIMOUT ON TRIMSPOOL ON
WHENEVER SQLERROR CONTINUE
-- DB identity
SELECT 'DB_NAME='||name FROM v$database;
SELECT 'DB_UNIQUE_NAME='||db_unique_name FROM v$database;
SELECT 'DB_ROLE='||database_role FROM v$database;
SELECT 'OPEN_MODE='||open_mode FROM v$database;
SELECT 'SWITCHOVER_STATUS='||switchover_status FROM v$database;
SELECT 'PROTECTION_MODE='||protection_mode FROM v$database;
-- Instance (primary)
SELECT 'INSTANCE_NAME='||instance_name FROM v$instance;
SELECT 'HOST_NAME='||host_name FROM v$instance;
SELECT 'DB_VERSION='||version FROM v$instance;
SELECT 'STARTUP_TIME='||TO_CHAR(startup_time,'YYYY-MM-DD HH24:MI:SS') FROM v$instance;
-- SPFILE
SELECT 'SPFILE='||value FROM v$parameter WHERE name='spfile';
-- Key parameters
SELECT 'COMPATIBLE='||value FROM v$parameter WHERE name='compatible';
SELECT 'CLUSTER_DATABASE='||value FROM v$parameter WHERE name='cluster_database';
SELECT 'LOCAL_LISTENER='||value FROM v$parameter WHERE name='local_listener';
SELECT 'REMOTE_LISTENER='||value FROM v$parameter WHERE name='remote_listener';
SELECT 'LOG_ARCHIVE_DEST_1='||value FROM v$parameter WHERE name='log_archive_dest_1';
SELECT 'DB_RECOVERY_FILE_DEST='||value FROM v$parameter WHERE name='db_recovery_file_dest';
SELECT 'DB_RECOVERY_FILE_DEST_SIZE='||value FROM v$parameter WHERE name='db_recovery_file_dest_size';
SELECT 'PROCESSES='||value FROM v$parameter WHERE name='processes';
SELECT 'SGA_TARGET='||value FROM v$parameter WHERE name='sga_target';
SELECT 'PGA_AGGREGATE_TARGET='||value FROM v$parameter WHERE name='pga_aggregate_target';
SELECT 'MEMORY_TARGET='||value FROM v$parameter WHERE name='memory_target';
-- All RAC instances
SELECT 'RAC_INSTANCE='||instance_number||':'||instance_name||':'||host_name||':'||status FROM gv$instance ORDER BY instance_number;
-- Services (exclude internal services)
SELECT 'SERVICE='||name FROM v$services WHERE name NOT IN (SELECT db_unique_name FROM v$database) AND name NOT LIKE 'SYS$%' ORDER BY name;
-- RMAN backup (last 7 days)
SELECT 'LAST_BACKUP='||TO_CHAR(MAX(completion_time),'YYYY-MM-DD HH24:MI:SS') FROM v$backup_set WHERE status='A';
SELECT 'RMAN_LAST_STATUS='||MAX(status) FROM v$backup_set WHERE completion_time > SYSDATE-7;
EXIT
SQLEOF
    ) || true

    if [[ -z "$sql_output" ]]; then
        add_html_row "DB SQL Discovery ($sid)" "WARN" "No output from sqlplus — DB may not be open or sysdba connection failed."
        return 0
    fi

    # ---- Parse output ----
    local db_name db_unique role open_mode switchover protection
    local instance host version startup spfile
    local compatible cluster local_list remote_list archive_dest recovery_dest recovery_size
    local processes sga pga memory
    local last_backup rman_status
    local -a rac_instances=()
    local -a services=()

    while IFS= read -r rawline; do
        # Trim whitespace
        local trimmed
        trimmed=$(printf '%s' "$rawline" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$trimmed" ]] && continue
        local key="${trimmed%%=*}"
        local val="${trimmed#*=}"
        case "$key" in
            DB_NAME)                db_name="$val" ;;
            DB_UNIQUE_NAME)         db_unique="$val" ;;
            DB_ROLE)                role="$val" ;;
            OPEN_MODE)              open_mode="$val" ;;
            SWITCHOVER_STATUS)      switchover="$val" ;;
            PROTECTION_MODE)        protection="$val" ;;
            INSTANCE_NAME)          instance="$val" ;;
            HOST_NAME)              host="$val" ;;
            DB_VERSION)             version="$val" ;;
            STARTUP_TIME)           startup="$val" ;;
            SPFILE)                 spfile="$val" ;;
            COMPATIBLE)             compatible="$val" ;;
            CLUSTER_DATABASE)       cluster="$val" ;;
            LOCAL_LISTENER)         local_list="$val" ;;
            REMOTE_LISTENER)        remote_list="$val" ;;
            LOG_ARCHIVE_DEST_1)     archive_dest="$val" ;;
            DB_RECOVERY_FILE_DEST)  recovery_dest="$val" ;;
            DB_RECOVERY_FILE_DEST_SIZE) recovery_size="$val" ;;
            PROCESSES)              processes="$val" ;;
            SGA_TARGET)             sga="$val" ;;
            PGA_AGGREGATE_TARGET)   pga="$val" ;;
            MEMORY_TARGET)          memory="$val" ;;
            LAST_BACKUP)            last_backup="$val" ;;
            RMAN_LAST_STATUS)       rman_status="$val" ;;
            RAC_INSTANCE)           rac_instances+=("$val") ;;
            SERVICE)                services+=("$val") ;;
        esac
    done <<< "$sql_output"

    # ---- Determine cluster type ----
    local cluster_type="Single Instance (SI)"
    if [[ "${cluster:-FALSE}" == "TRUE" ]]; then
        cluster_type="RAC"
    fi

    # ---- Section header ----
    add_html_row "--- DB IDENTITY ---" "INFO" "Values discovered via v\$database / v\$instance"

    add_html_row "DB Name"        "INFO" "${db_name:-<unknown>}"
    add_html_row "DB Unique Name" "INFO" "${db_unique:-<unknown>}"

    local role_status="INFO"
    [[ "${role:-}" == "PRIMARY" ]] && role_status="PASS"
    add_html_row "Database Role" "$role_status" "${role:-<unknown>}"

    local open_status="PASS"
    [[ "${open_mode:-}" != "READ WRITE" ]] && open_status="WARN"
    add_html_row "Open Mode" "$open_status" "${open_mode:-<unknown>}"

    add_html_row "Switchover Status" "INFO" "${switchover:-<unknown>}"
    add_html_row "Protection Mode"   "INFO" "${protection:-<unknown>}"
    add_html_row "DB Version"        "INFO" "${version:-<unknown>}"
    add_html_row "ORACLE_HOME"       "INFO" "$oracle_home"
    add_html_row "Startup Time"      "INFO" "${startup:-<unknown>}"
    add_html_row "Cluster Type"      "INFO" "$cluster_type"

    # ---- RAC instances ----
    add_html_row "--- INSTANCE LIST ---" "INFO" "From gv\$instance"
    if [[ ${#rac_instances[@]} -gt 0 ]]; then
        for inst_info in "${rac_instances[@]}"; do
            local inst_num inst_name inst_host inst_status
            IFS=: read -r inst_num inst_name inst_host inst_status <<< "$inst_info"
            local inst_st="PASS"
            [[ "${inst_status:-}" != "OPEN" ]] && inst_st="WARN"
            add_html_row "Instance $inst_num" "$inst_st" "$inst_name @ $inst_host — $inst_status"
        done
    else
        add_html_row "Instances" "INFO" "${instance:-<unknown>} @ ${host:-<unknown>}"
    fi

    # ---- Services ----
    add_html_row "--- SERVICES ---" "INFO" "From v\$services"
    if [[ ${#services[@]} -gt 0 ]]; then
        for svc in "${services[@]}"; do
            add_html_row "Service" "INFO" "$svc"
        done
    else
        add_html_row "Services" "INFO" "No application services found (default service only)."
    fi

    # ---- SPFILE ----
    add_html_row "--- SPFILE ---" "INFO" ""
    if [[ -n "${spfile:-}" ]]; then
        add_html_row "SPFILE" "PASS" "$spfile"
    else
        add_html_row "SPFILE" "WARN" "No SPFILE — database using PFILE. SPFILE is required for patching."
    fi

    # ---- Parameter validation ----
    add_html_row "--- PARAMETER VALIDATION ---" "INFO" "Key init parameters"

    add_html_row "db_unique_name" "INFO" "${db_unique:-<not set>}"
    add_html_row "compatible"     "INFO" "${compatible:-<not set>}"
    add_html_row "cluster_database" "INFO" "${cluster:-FALSE}"

    if [[ -n "${local_list:-}" ]]; then
        add_html_row "local_listener"  "PASS" "$local_list"
    else
        add_html_row "local_listener"  "WARN" "Not set — listener dynamic registration only."
    fi
    if [[ -n "${remote_list:-}" ]]; then
        add_html_row "remote_listener" "INFO" "$remote_list"
    else
        add_html_row "remote_listener" "INFO" "Not set (expected for standalone / non-RAC)."
    fi
    [[ -n "${archive_dest:-}" ]]   && add_html_row "log_archive_dest_1"       "INFO" "$archive_dest"
    [[ -n "${recovery_dest:-}" ]]  && add_html_row "db_recovery_file_dest"    "INFO" "${recovery_dest} (size: ${recovery_size:-unset})"
    [[ -n "${processes:-}" ]]      && add_html_row "processes"                "INFO" "$processes"
    [[ -n "${sga:-}" ]]            && add_html_row "sga_target"               "INFO" "$sga"
    [[ -n "${pga:-}" ]]            && add_html_row "pga_aggregate_target"     "INFO" "$pga"
    [[ -n "${memory:-}" ]]         && add_html_row "memory_target"            "INFO" "$memory"

    # ---- RMAN ----
    add_html_row "--- BACKUP VALIDATION ---" "INFO" "RMAN backup status"
    if [[ -n "${last_backup:-}" && "${last_backup:-}" != " " ]]; then
        add_html_row "Last RMAN Backup" "PASS" "$last_backup (status: ${rman_status:-unknown})"
    else
        add_html_row "Last RMAN Backup" "WARN" "No completed RMAN backup found in the last 7 days."
    fi

    # ---- Build service/instance JSON arrays ----
    local svc_json="[]"
    if [[ ${#services[@]} -gt 0 ]]; then
        svc_json="["
        for svc in "${services[@]}"; do
            svc_json+="\"${svc}\","
        done
        svc_json="${svc_json%,}]"
    fi

    local inst_json="[]"
    if [[ ${#rac_instances[@]} -gt 0 ]]; then
        inst_json="["
        for inst_info in "${rac_instances[@]}"; do
            IFS=: read -r inst_num inst_name inst_host inst_status <<< "$inst_info"
            inst_json+="{\"number\":${inst_num:-0},\"name\":\"${inst_name:-}\",\"host\":\"${inst_host:-}\",\"status\":\"${inst_status:-}\"},"
        done
        inst_json="${inst_json%,}]"
    else
        inst_json="[{\"number\":1,\"name\":\"${instance:-}\",\"host\":\"${host:-}\",\"status\":\"${open_mode:-}\"}]"
    fi

    # ---- Write discovery.json file ----
    local json_file="${DB_LOG_DIR}/discovery.json"
    cat > "$json_file" <<JSONEOF
{
  "type": "db_discovery",
  "hostname": "$HOSTNAME",
  "db_name": "${db_name:-}",
  "db_unique_name": "${db_unique:-}",
  "database_role": "${role:-}",
  "open_mode": "${open_mode:-}",
  "switchover_status": "${switchover:-}",
  "protection_mode": "${protection:-}",
  "oracle_home": "$oracle_home",
  "db_version": "${version:-}",
  "cluster_type": "${cluster_type}",
  "cluster_database": "${cluster:-FALSE}",
  "spfile": "${spfile:-}",
  "compatible": "${compatible:-}",
  "local_listener": "${local_list:-}",
  "remote_listener": "${remote_list:-}",
  "log_archive_dest_1": "${archive_dest:-}",
  "instances": $inst_json,
  "services": $svc_json,
  "last_rman_backup": "${last_backup:-}",
  "generated_at": "$(date '+%F %T')"
}
JSONEOF
    add_html_row "Discovery JSON" "INFO" "Written to $json_file"
    log "Discovery JSON written to $json_file"

    # ---- Emit as structured log line for backend storage ----
    local json_content
    json_content=$(cat "$json_file")
    log "[DISCOVERY_JSON] ${json_content}"
}

# ------------------------------------------------------------
# DB PRECHECK: Listener status
# ------------------------------------------------------------
db_listener_html() {
    local oracle_home="$1"
    local lsnrctl="$oracle_home/bin/lsnrctl"

    if [[ ! -x "$lsnrctl" ]]; then
        add_html_row "Listener check" "WARN" "lsnrctl not found at $lsnrctl — skipping listener validation."
        return 0
    fi

    local lsnr_out
    lsnr_out=$(ORACLE_HOME="$oracle_home" PATH="$oracle_home/bin:$PATH" \
        "$lsnrctl" status 2>&1 | head -30 || true)

    if echo "$lsnr_out" | grep -qi "TNS-12541\|no listener\|not running"; then
        add_html_row "Listener status" "FAIL" "Listener does not appear to be running. lsnrctl status: $(echo "$lsnr_out" | head -5)"
    elif echo "$lsnr_out" | grep -qi "alias\|listening on\|READY"; then
        local endpoints
        endpoints=$(echo "$lsnr_out" | grep -i "listening on" | head -5 | tr '\n' ' ' || echo "see log")
        add_html_row "Listener status" "PASS" "Listener is running. Endpoints: $endpoints"
    else
        add_html_row "Listener status" "WARN" "Could not determine listener status. Output: $(echo "$lsnr_out" | head -3)"
    fi
}

# ------------------------------------------------------------
# DB PRECHECK / INSTALL (19c patching) + optional upgrade check
# ------------------------------------------------------------
db_precheck() {

    # Ensure DB log dirs exist and are writable before any logging
    ensure_phase_log_dirs db

    reset_report
    reset_html_report

    LOG_FILE="${DB_LOG_DIR}/db_precheck_$(date +%F_%H%M%S).log"
    add_attachment "$LOG_FILE"
    log "DB PRECHECK (19c OOP)"

    assert_precheck_homes_safe

    write_db_rsp_if_embedded
    # Predict INS-32826: NEW_DB_HOME already registered in central inventory
    check_new_db_home_already_registered_html

    check_at_service_html

    # Validate required software is staged
    validate_staged_software_html db || true

    local gi_fs db_fs

    gi_fs=$(df -P "$OLD_GI_HOME" 2>/dev/null | awk 'NR==2{print $6}' || true)
    db_fs=$(df -P "$OLD_DB_HOME" 2>/dev/null | awk 'NR==2{print $6}' || true)

    if [[ -n "$db_fs" ]]; then
        check_space_html "$db_fs" 30
    else
        add_html_row "Filesystem space for OLD_DB_HOME" "WARN" \
            "Could not determine filesystem for $OLD_DB_HOME"
    fi

    if [[ -n "${OLD_GI_HOME:-}" ]]; then
        if [[ -n "$gi_fs" ]]; then
            check_space_html "$gi_fs" 20
        else
            add_html_row "Filesystem space for OLD_GI_HOME" "WARN" \
                "Could not determine filesystem for $OLD_GI_HOME"
        fi
    fi

    check_oracle_sudo_nopass_html
    detect_cluster_type_html

    local oratab_html
    oratab_html=$(format_oratab_html "$OLD_DB_HOME")
    add_html_row "/etc/oratab entries" "INFO" "$oratab_html"

    # ------------------------------------------------------------
    # OPatch check
    # ------------------------------------------------------------
    if [[ -d "$OLD_DB_HOME" ]]; then
        local req_opatch_db cur_opatch_db
        req_opatch_db=$(required_opatch_version)
        cur_opatch_db=$(current_opatch_version "$OLD_DB_HOME")
        if [[ -z "$req_opatch_db" ]]; then
            add_html_row "OPatch version (DB home)" "WARN" \
                "Could not parse required OPatch version from $RU_README; current DB OPatch is ${cur_opatch_db:-unknown}."
        else
            if [[ -z "$cur_opatch_db" || "$cur_opatch_db" == "0" ]]; then
                add_html_row "OPatch version (DB home)" "INFO" \
                    "Required: $req_opatch_db (per $RU_README), current DB OPatch in $OLD_DB_HOME is unknown."
            else
                if compare_versions "$cur_opatch_db" "$req_opatch_db"; then
                    add_html_row "OPatch version (DB home)" "INFO" \
                        "Current: $cur_opatch_db, required: $req_opatch_db"
                else
                    add_html_row "OPatch version (DB home)" "WARN" \
                        "Current DB OPatch is $cur_opatch_db, lower than required $req_opatch_db"
                fi
            fi
        fi
    else
        add_html_row "OPatch version (DB home)" "WARN" \
            "OLD_DB_HOME ($OLD_DB_HOME) does not exist"
    fi

    # ----------------------------------------------------------------
    # /tmp exec check — Oracle CVU requires exec permission on /tmp
    # ----------------------------------------------------------------
    local tmp_test_script="/tmp/.oop_exec_test_$$.sh"
    echo '#!/bin/sh' > "$tmp_test_script" 2>/dev/null
    echo 'exit 0' >> "$tmp_test_script" 2>/dev/null
    chmod +x "$tmp_test_script" 2>/dev/null
    if ! "$tmp_test_script" 2>/dev/null; then
        add_html_row "/tmp exec check" "FAIL" \
            "<b>/tmp is mounted with noexec</b> — runInstaller and CVU will fail with PRVG-1901.<br/>\
Fix: <code>sudo mount -o remount,exec /tmp</code> or create an alternative:<br/>\
<code>mkdir -p /app/tmp && chmod 1777 /app/tmp</code><br/>\
The db_install phase will auto-detect and use /app/tmp if /tmp is noexec."
    else
        add_html_row "/tmp exec check" "PASS" \
            "Scripts can execute in /tmp — CVU framework will work."
    fi
    rm -f "$tmp_test_script" 2>/dev/null

    # ------------------------------------------------------------
    # DB FILE DISCOVERY
    # ------------------------------------------------------------
    discover_db_files
    if [[ ${#DB_FILES[@]} -gt 0 ]]; then
        add_html_row "DB config files discovered" "INFO" \
            "$(printf "%s " "${DB_FILES[@]}")"
    else
        add_html_row "DB config files discovered" "INFO" \
            "No DB home config files discovered under $OLD_DB_HOME"
    fi

    # ------------------------------------------------------------
    # DATABASE DISCOVERY via PMON (SID -> HOME from /proc)
    # ------------------------------------------------------------
    DB_UNIQUES=()
    local pmon_sids
    pmon_sids=$(ps -eo args | awk -F'pmon_' '/pmon_/ {print $2}' | sed 's/ .*$//' | sort -u || true)

    while read -r sid; do
        [[ -z "$sid" || "$sid" == +ASM* ]] && continue   # skip ASM
        DB_UNIQUES+=("$sid")
    done <<< "$pmon_sids"

    if [[ ${#DB_UNIQUES[@]} -eq 0 ]]; then
        add_html_row "DB status / patch levels (per database)" "INFO" \
            "No running PMON processes found; cannot detect databases."
    else
        local html_summary=""
        local DB_SID

        for DB_SID in "${DB_UNIQUES[@]}"; do
            # Derive Oracle home directly from PMON (via /proc)
            local DB_HOME
            DB_HOME=$(get_home_from_pmon_sid "$DB_SID")

            # Fallback to OLD_DB_HOME if we couldn't resolve
            if [[ -z "$DB_HOME" ]]; then
                DB_HOME="$OLD_DB_HOME"
            fi

            # Skip invalid homes
            if [[ ! -d "$DB_HOME" ]]; then
                html_summary+="<b>${DB_SID}</b> (Type: UNKNOWN, Oracle home: ${DB_HOME})<br/>"
                html_summary+="  Current open mode: UNKNOWN<br/>"
                html_summary+="  OPatch not found in ${DB_HOME} — cannot determine patch level.<br/>"
                html_summary+="  Open PDBs: none or instance is non-CDB / not accessible.<br/><br/>"
                continue
            fi

            # Determine DB type and open mode in a single sqlplus call to avoid
            # running the heavy connection twice. Query db_unique_name, cluster_database,
            # and open_mode together.
            local DB_TYPE="SINGLE INSTANCE"
            local OPEN_MODE="UNKNOWN"
            local _disc_db_uniq=""
            local _disc_cluster_db="FALSE"
            if [[ -x "$DB_HOME/bin/sqlplus" ]]; then
                local _disc_sql_out
                _disc_sql_out=$(
                    sudo -u "$ORACLE_USER" bash -c "
                        export ORACLE_HOME=\"$DB_HOME\"
                        export ORACLE_SID=\"$DB_SID\"
                        export PATH=\"$DB_HOME/bin:\$PATH\"
                        export LD_LIBRARY_PATH=\"$DB_HOME/lib:\${LD_LIBRARY_PATH:-}\"
                        \"$DB_HOME/bin/sqlplus\" -s / as sysdba 2>&1 <<'EOF'
set heading off feedback off pages 0 verify off echo off termout off
select 'OPEN_MODE='||open_mode from v\$database;
select 'DB_UNIQUE_NAME='||db_unique_name from v\$database;
select 'CLUSTER_DATABASE='||value from v\$parameter where name='cluster_database';
exit
EOF
                    "
                ) || true

                OPEN_MODE=$(printf '%s\n' "$_disc_sql_out" | grep '^OPEN_MODE=' | head -1 | cut -d= -f2- | tr -d ' \r')
                _disc_db_uniq=$(printf '%s\n' "$_disc_sql_out" | grep '^DB_UNIQUE_NAME=' | head -1 | cut -d= -f2- | tr -d ' \r')
                _disc_cluster_db=$(printf '%s\n' "$_disc_sql_out" | grep '^CLUSTER_DATABASE=' | head -1 | cut -d= -f2- | tr -d ' \r' | tr '[:lower:]' '[:upper:]')
                [[ -z "$OPEN_MODE" ]] && OPEN_MODE="UNKNOWN"
            fi

            # DB type detection: srvctl (most accurate) → cluster_database fallback
            local _db_name_for_srvctl="${_disc_db_uniq:-$DB_SID}"
            if [[ -n "$SRVCTL_BIN" && -n "$_db_name_for_srvctl" ]]; then
                local _srvctl_type
                _srvctl_type=$(ORACLE_HOME="${OLD_GI_HOME:-}" "$SRVCTL_BIN" config database \
                    -d "$_db_name_for_srvctl" 2>/dev/null \
                    | awk -F: '/^Type/{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' || true)
                [[ -n "$_srvctl_type" ]] && DB_TYPE="$_srvctl_type"
            elif [[ "$_disc_cluster_db" == "TRUE" ]]; then
                # cluster_database=TRUE means GI manages this DB (RAC ONE NODE or RAC).
                # Without srvctl we can't distinguish; default to RAC ONE NODE for
                # single-node GI environments which is more accurate than SINGLE INSTANCE.
                DB_TYPE="RAC ONE NODE"
            fi

            # Patch level
            local PATCH_LEVEL=""
            if [[ -x "$DB_HOME/OPatch/opatch" ]]; then
                PATCH_LEVEL=$(get_patch_level "$DB_HOME" || echo "")
            else
                PATCH_LEVEL="OPatch not found in ${DB_HOME} — cannot determine patch level."
            fi

            # FIX: PDBs — run as ORACLE_USER with exported env + || true guard
            local PDBS=""
            if [[ -x "$DB_HOME/bin/sqlplus" ]]; then
                PDBS=$(
                    sudo -u "$ORACLE_USER" bash -c "
                        export ORACLE_HOME=\"$DB_HOME\"
                        export ORACLE_SID=\"$DB_SID\"
                        export PATH=\"$DB_HOME/bin:\$PATH\"
                        export LD_LIBRARY_PATH=\"$DB_HOME/lib:\${LD_LIBRARY_PATH:-}\"
                        \"$DB_HOME/bin/sqlplus\" -s / as sysdba 2>&1 <<'EOF'
set heading off feedback off pages 0 verify off echo off termout off
whenever sqlerror exit 1
select name || ' (' || open_mode || ')' from v\$pdbs order by 1;
exit
EOF
                    "
                ) || true
                PDBS=$(printf '%s\n' "$PDBS" | tr -d '\r' | grep -v '^SQL\*Plus\|^Connected\|^ERROR:\|^ORA-\|^SP2-' | sed '/^[[:space:]]*$/d')
            fi

            # Build HTML
            html_summary+="<b>${DB_SID}</b> (Type: ${DB_TYPE}, Oracle home: ${DB_HOME})<br/>"
            html_summary+="  Current open mode: ${OPEN_MODE}<br/>"
            if [[ -n "$PATCH_LEVEL" ]]; then
                html_summary+=$(printf '%s<br/>' "$PATCH_LEVEL")
            else
                html_summary+="  Patch level: unknown<br/>"
            fi

            if [[ -n "$PDBS" ]]; then
                html_summary+="<br/>Open PDBs (will be patched by datapatch):<br/>"
                while IFS= read -r p; do
                    [[ -n "$p" ]] || continue
                    html_summary+="$p<br/>"
                done <<< "$PDBS"
            else
                html_summary+="<br/>Open PDBs: none or instance is non-CDB / not accessible.<br/>"
            fi

            html_summary+="<br/>"
        done

        add_html_row "DB status / patch levels (per database)" "INFO" "$html_summary"
    fi

    # ------------------------------------------------------------
    # Capture old DB patch level
    # ------------------------------------------------------------
    local old_db_pl
    old_db_pl=$(get_patch_level "$OLD_DB_HOME" || echo "")
    if [[ -n "$old_db_pl" ]]; then
        echo "$old_db_pl" > "${DB_LOG_DIR}/db_old_patchlevel.html"
    else
        echo "Patch level unknown for OLD_DB_HOME ($OLD_DB_HOME)" \
            > "${DB_LOG_DIR}/db_old_patchlevel.html"
    fi
    add_attachment "${DB_LOG_DIR}/db_old_patchlevel.html"

    # ------------------------------------------------------------
    # runInstaller prerequisite check
    # ------------------------------------------------------------
    local db_prereq_log="${DB_LOG_DIR}/db_executePrereqs_$(date +%F_%H%M%S).log"
    local db_prereq_home="$PRECHECK_DB_HOME"

    if stage_db_software_for_precheck "$db_prereq_home"; then
        if [[ -x "$db_prereq_home/runInstaller" ]]; then

            # Marker so we can find all OUI logs created during this executePrereqs run
            local oui_marker="${DB_LOG_DIR}/.marker_db_executePrereqs_$(date +%F_%H%M%S)"
            : > "$oui_marker"

            # Auto-detect safe TMP for precheck too
            local prereq_tmp="/tmp"
            local prereq_test="/tmp/.oop_exec_test_$$.sh"
            echo '#!/bin/sh' > "$prereq_test" 2>/dev/null
            echo 'exit 0' >> "$prereq_test" 2>/dev/null
            chmod +x "$prereq_test" 2>/dev/null
            if ! "$prereq_test" 2>/dev/null; then
                for d in /app/tmp /var/tmp; do
                    [[ -d "$d" ]] && { prereq_tmp="$d"; break; }
                done
            fi
            rm -f "$prereq_test" 2>/dev/null

            run_cmd \
                "TMP=$prereq_tmp TMPDIR=$prereq_tmp TEMP=$prereq_tmp \
                sudo -u \"$ORACLE_USER\" \"$db_prereq_home/runInstaller\" \
                -silent -executePrereqs \
                -responseFile \"$DB_RSP\" \
                > \"$db_prereq_log\" 2>&1 || true"

            add_attachment "$db_prereq_log"
            log_file_content "$db_prereq_log" "DB: runInstaller executePrereqs"

            # Attach detailed OUI logs (InstallActions / prereq logs) created after the marker
            attach_latest_oui_logs_since_marker "$oui_marker" "DB executePrereqs" 8
            rm -f "$oui_marker" 2>/dev/null || true

            if grep -qi "failed" "$db_prereq_log"; then
                add_html_row "DB executePrereqs" "FAIL" \
                    "runInstaller -executePrereqs reported failures. See $db_prereq_log"
            else
                add_html_row "DB executePrereqs" "PASS" \
                    "runInstaller -executePrereqs completed. See $db_prereq_log"
            fi
        else
            add_html_row "DB executePrereqs" "WARN" \
                "runInstaller not found in $db_prereq_home"
        fi
    else
        add_html_row "DB executePrereqs" "WARN" \
            "Could not stage DB software for precheck"
    fi

    # ------------------------------------------------------------
    # SQL-based discovery (runs per running DB instance)
    # ------------------------------------------------------------
    if [[ ${#DB_UNIQUES[@]} -gt 0 ]]; then
        local _disc_idx=0
        for _disc_db in "${DB_UNIQUES[@]}"; do
            _disc_idx=$(( _disc_idx + 1 ))
            local _pmon_home
            _pmon_home=$(get_home_from_pmon_sid "$_disc_db" 2>/dev/null || true)
            [[ -z "$_pmon_home" ]] && _pmon_home="$OLD_DB_HOME"
            if [[ ${#DB_UNIQUES[@]} -gt 1 ]]; then
                add_html_section "Database Instance ${_disc_idx}/${#DB_UNIQUES[@]}: ${_disc_db}  (home: ${_pmon_home})"
            fi
            db_sql_discovery_html "$_disc_db" "$_pmon_home"
            db_listener_html "$_pmon_home"
        done
    else
        # DB not running — still check listener using OLD_DB_HOME
        db_listener_html "$OLD_DB_HOME"
        add_html_row "DB SQL Discovery" "INFO" \
            "No running database instances found — SQL-based checks skipped. Start DB before patching if SQL validation is required."
    fi

    # ------------------------------------------------------------
    # Cleanup
    # ------------------------------------------------------------
    if [[ -d "$PRECHECK_DB_HOME" ]]; then
        add_html_row "DB precheck software cleanup" "INFO" \
            "Removing precheck DB home $PRECHECK_DB_HOME"
        safe_rm_rf "$PRECHECK_DB_HOME"
    fi

    # ------------------------------------------------------------
    # Optional DB Upgrade Precheck
    # ------------------------------------------------------------
    if [[ "${RUN_DB_UPGRADE_CHECKS_FROM_DB_PRECHECK:-false}" == true ]]; then
        if [[ ${#DB_UNIQUES[@]} -gt 0 ]]; then
            local upg_db="${DB_UNIQUES[0]}"
            log "Running DB upgrade precheck for $upg_db"
            db_upgrade_precheck "$upg_db"
        fi
    fi

    send_html_report "DB Precheck Report - $HOST" "DB Precheck Report"
}
db_install() {
    ensure_phase_log_dirs db

    reset_report
    reset_html_report

    LOG_FILE="${DB_LOG_DIR}/db_install_$(date +%F_%H%M%S).log"
    add_attachment "$LOG_FILE"
    log "DB INSTALL (19c OOP)"

    write_db_rsp_if_embedded

    add_html_row "DB target ORACLE_HOME" "INFO" "$NEW_DB_HOME"
    add_html_row "DB RU directory" "INFO" "${RU_DIR:-<not set>}"

    run_cmd "mkdir -p \"$NEW_DB_HOME\""
    run_cmd "chown -R ${ORACLE_USER}:${OINSTALL} \"$NEW_DB_HOME\""

    # FIX: Auto-discover DB_BASE_ZIP if the configured path doesn't exist
    if [[ ! -f "$DB_BASE_ZIP" ]]; then
        log "INFO: DB_BASE_ZIP not found at configured path: $DB_BASE_ZIP — searching..."
        local _search_dirs=(
            "/staging/DB_BASE_SOFT"
            "/staging"
            "${STAGING_DROP_DIR:-/home/oracle/staging}"
            "$(dirname "$DB_BASE_ZIP")"
            "/app/software/db_software"
            "/app/software"
        )
        local _found_zip=""
        local _bname
        _bname=$(basename "$DB_BASE_ZIP")
        local _d
        for _d in "${_search_dirs[@]}"; do
            [[ -d "$_d" ]] || continue
            if [[ -f "$_d/$_bname" ]]; then
                _found_zip="$_d/$_bname"
                break
            fi
            # Also try globbing for V982063*.zip in case filename differs slightly
            shopt -s nullglob
            local _candidates=( "$_d"/V982063*.zip )
            shopt -u nullglob
            if (( ${#_candidates[@]} > 0 )); then
                _found_zip="${_candidates[0]}"
                break
            fi
        done

        if [[ -n "$_found_zip" ]]; then
            log "INFO: Found DB base ZIP at: $_found_zip (overriding configured DB_BASE_ZIP)"
            add_html_row "DB Base ZIP discovery" "INFO" \
                "Configured path missing ($DB_BASE_ZIP). Found at: $_found_zip"
            DB_BASE_ZIP="$_found_zip"
        fi
    fi

    # HARD BLOCK: refuse to install into a home that has live databases running from it.
    if [[ -d "$NEW_DB_HOME" ]]; then
        local _live_sids=()
        local _chk_sid
        while IFS= read -r _chk_sid; do
            local _chk_home
            _chk_home=$(get_home_from_pmon_sid "$_chk_sid" 2>/dev/null || true)
            [[ "$_chk_home" == "$NEW_DB_HOME" ]] && _live_sids+=("$_chk_sid")
        done < <(ps -eo args 2>/dev/null | grep -oP '(?<=ora_pmon_)[A-Za-z0-9_]+' | grep -v '^\+' | grep -v 'MGMTDB' | sort -u)
        if (( ${#_live_sids[@]} > 0 )); then
            add_html_row "DB Install Safety Check" "FAIL" \
                "HARD BLOCK: instance(s) ${_live_sids[*]} are running from $NEW_DB_HOME. \
Unzipping the base media into a live home will corrupt it. \
Run db_rollback first to return the database to $OLD_DB_HOME, then retry db_install."
            send_html_report "DB Install BLOCKED - $HOST" "DB Install Report (BLOCKED)"
            die "HARD BLOCK: db_install refused — instance(s) ${_live_sids[*]} are running from NEW_DB_HOME=$NEW_DB_HOME"
        fi
    fi

    # Depot mode: agent pre-extracted the DB base tar directly into NEW_DB_HOME.
    # Detect by the presence of runInstaller — if it's there, skip zip + unzip entirely.
    if [[ -f "$NEW_DB_HOME/runInstaller" ]]; then
        add_html_row "DB Base (depot mode)" "PASS" \
            "$NEW_DB_HOME already contains runInstaller — pre-extracted from orchestrator depot. Skipping zip transfer and unzip."
        log "INFO: Depot mode — $NEW_DB_HOME already extracted, skipping unzip"
    elif [[ ! -f "$DB_BASE_ZIP" ]]; then
        add_html_row "DB Base ZIP" "FAIL" \
            "DB base ZIP missing: $DB_BASE_ZIP. Searched: /staging/DB_BASE_SOFT, /staging, $STAGING_DROP_DIR, $(dirname "$DB_BASE_ZIP"). Either upload the zip or run 'Extract to Depot' from the Patches UI and re-stage."
        send_html_report "DB Install FAILED - $HOST" "DB Install Report (FAILED)"
        die "DB Base ZIP missing: $DB_BASE_ZIP"
    else
        add_html_row "DB Base ZIP" "PASS" "$DB_BASE_ZIP"
        run_cmd "unzip -oq \"$DB_BASE_ZIP\" -d \"$NEW_DB_HOME\""
    fi

    update_opatch "$NEW_DB_HOME"
    add_html_row "OPatch in NEW_DB_HOME" "INFO" "OPatch updated under $NEW_DB_HOME (see logs)"

    apply_ojvm_on_db_install_if_enabled

    ensure_cvu_config_ol7 "$NEW_DB_HOME"

    copy_db_files
    add_html_row "DB config files copied" "INFO" \
        "Copied config/SPFILE/listener/tnsnames/sqlnet files from $OLD_DB_HOME into $NEW_DB_HOME (where present)."

    local db_log="${DB_LOG_DIR}/dbSetup_$(date +%F_%H%M%S).log"
    if [[ "$DRYRUN" == true ]]; then
        log "[DRYRUN] Would run DB installer"
        add_html_row "DB Install (dry-run)" "INFO" "Installer would log to $db_log"
        send_html_report "DB Install (Dry-run) - $HOST" "DB Install (Dry-run) Report"
        return 0
    fi

    log "Starting DB Software Install. Installer log will be in ${db_log}"

    stage_db_ojvm_oneoffs_for_install

    # FIX: Validate RU_DIR before constructing -applyRU
    if [[ -z "${RU_DIR:-}" || ! -d "${RU_DIR:-}" ]]; then
        add_html_row "RU Directory" "FAIL" \
            "RU_DIR is empty or does not exist: '${RU_DIR:-<not set>}'. Run stage_software first to extract the RU ZIP."
        send_html_report "DB Install FAILED - $HOST" "DB Install Report (FAILED)"
        die "RU_DIR is empty or missing ('${RU_DIR:-}'). Cannot pass -applyRU to runInstaller. Run: $0 stage_software"
    fi

    local apply_opts="-applyRU \"$RU_DIR\""
    if [[ "${APPLY_OJVM_DURING_DB_INSTALL:-false}" == true ]]; then
        if [[ -d "$OJVM_ONEOFF_DIR" ]]; then
            apply_opts="$apply_opts -applyOneOffs \"$OJVM_ONEOFF_DIR\""
            add_html_row "OJVM (installer)" "INFO" \
                "Applying OJVM one-off from $OJVM_ONEOFF_DIR together with RU during DB install."
        else
            add_html_row "OJVM (installer)" "WARN" \
                "APPLY_OJVM_DURING_DB_INSTALL=true but OJVM_ONEOFF_DIR ($OJVM_ONEOFF_DIR) not found; OJVM will NOT be applied by runInstaller."
        fi
    else
        add_html_row "OJVM (installer)" "INFO" \
            "APPLY_OJVM_DURING_DB_INSTALL=false — OJVM not applied by runInstaller."
    fi

    sudo -u "$ORACLE_USER" bash -c "yes randn_pass | \
        \"$NEW_DB_HOME/runInstaller\" \
            -silent -ignorePrereqFailure -responseFile \"$DB_RSP\" \
            $apply_opts \
            -waitForCompletion" \
        &> "$db_log" &

    local installer_pid=$!
    local timeout_seconds=7200
    local poll_interval=10
    local elapsed=0
    local success=false
    local installer_rc=0
    local failure_reason="Unknown failure"

    log "Monitoring DB installer (PID=$installer_pid) with timeout ${timeout_seconds}s..."
    while (( elapsed < timeout_seconds )); do
        if [[ -f "$db_log" ]]; then
            # FIX: Check for success FIRST
            if grep -q "Successfully Setup Software" "$db_log" 2>/dev/null; then
                success=true
                break
            fi
            # FIX: Only match genuine fatal/severe errors, not informational lines
            if grep -qiE '^(FATAL|SEVERE):' "$db_log" 2>/dev/null; then
                failure_reason="Fatal/Severe error detected in DB installer log. See $db_log"
                break
            fi
        fi
        if ! kill -0 "$installer_pid" 2>/dev/null; then
            wait "$installer_pid" || installer_rc=$?
            # FIX: Re-check success string after process exit
            if grep -q "Successfully Setup Software" "$db_log" 2>/dev/null; then
                success=true
            elif (( installer_rc == 0 )); then
                success=true
                failure_reason="DB installer RC=0 but success string not found. See $db_log"
            else
                failure_reason="DB installer exited with RC=${installer_rc}. See $db_log"
            fi
            break
        fi
        sleep "$poll_interval"
        elapsed=$(( elapsed + poll_interval ))
    done

    if [[ "$success" != true && $elapsed -ge $timeout_seconds ]]; then
        failure_reason="Timeout after ${timeout_seconds}s waiting for DB installer. See $db_log"
        if kill -0 "$installer_pid" 2>/dev/null; then
            kill "$installer_pid" 2>/dev/null || true
        fi
    fi

    if [[ "$success" == true ]]; then
        if kill -0 "$installer_pid" 2>/dev/null; then
            wait "$installer_pid" || installer_rc=$?
        fi
        local status_msg="Successfully Setup Software"
        if grep -qi "warning(s)" "$db_log" 2>/dev/null; then
            status_msg="Successfully Setup Software with warning(s)"
        fi

        local new_db_pl
        new_db_pl=$(get_patch_level "$NEW_DB_HOME" || echo "")
        if [[ -n "$new_db_pl" ]]; then
            echo "$new_db_pl" > "${DB_LOG_DIR}/db_new_patchlevel.html"
            add_attachment "${DB_LOG_DIR}/db_new_patchlevel.html"
        else
            echo "Patch level unknown for NEW_DB_HOME ($NEW_DB_HOME)" > "${DB_LOG_DIR}/db_new_patchlevel.html"
        fi

        add_attachment "$db_log"

        add_html_row "DB Software Install" "PASS" "$status_msg. Log: $db_log"
        send_html_report "DB Install Completed - $HOST" "DB Install Report"
        log "DB installer completed successfully."
        return 0
    fi

    # Failure path
    add_attachment "$db_log"
    add_html_row "DB Software Install" "FAIL" "$failure_reason. Log: $db_log"
    send_html_report "DB Install FAILED - $HOST" "DB Install Report (FAILED)"
    log "DB installer failed: $failure_reason"
    die "$failure_reason"
}
db_switch_core() {
    local DB_UNIQUE_NAME="$1"
    reset_report
    reset_html_report
    LOG_FILE="${DB_LOG_DIR}/db_switch_${DB_UNIQUE_NAME}_$(date +%F_%H%M%S).log"
    log "DB SWITCH for $DB_UNIQUE_NAME"

    # -------------------------------------------------------
    # DB_ONLY_MODE: no srvctl
    # -------------------------------------------------------
    if [[ "${DB_ONLY_MODE:-false}" == true || -z "$SRVCTL_BIN" ]]; then
        add_html_row "DB Switch" "INFO" "DB_ONLY_MODE: switching $DB_UNIQUE_NAME to NEW_DB_HOME (no srvctl)."

        local sid_for_switch
        sid_for_switch=$(get_db_sid "$DB_UNIQUE_NAME")
        if [[ -z "$sid_for_switch" ]]; then
            add_html_row "SID resolution" "FAIL" \
                "No PMON process found for '$DB_UNIQUE_NAME' — database does not appear to be running. Start the database before running db_switch."
            send_phase_html_report "DB Switch" "DB Switch Report - $HOST" "FAIL"
            return 1
        fi
        add_html_row "SID resolution" "INFO" "Resolved SID: $sid_for_switch"

        # Verify the DB is actually OPEN (not just that a pmon exists)
        local _db_open_check
        _db_open_check=$(sudo -u "$ORACLE_USER" bash -c "
            export ORACLE_HOME=\"$(get_db_home "$DB_UNIQUE_NAME" 2>/dev/null || echo "$OLD_DB_HOME")\"
            export ORACLE_SID=\"$sid_for_switch\"
            export PATH=\"\$ORACLE_HOME/bin:\$PATH\"
            export LD_LIBRARY_PATH=\"\$ORACLE_HOME/lib:\${LD_LIBRARY_PATH:-}\"
            \"\$ORACLE_HOME/bin/sqlplus\" -s / as sysdba 2>&1 <<'SQEOF'
set heading off feedback off
select status from v\$instance;
exit;
SQEOF
        " 2>/dev/null) || true
        if echo "$_db_open_check" | grep -qi "ORA-01034\|not available\|ORA-27101"; then
            add_html_row "DB open check" "FAIL" \
                "Database '$DB_UNIQUE_NAME' is not available (ORA-01034). Start the database before running db_switch."
            send_phase_html_report "DB Switch" "DB Switch Report - $HOST" "FAIL"
            return 1
        fi
        add_html_row "DB open check" "PASS" "Database is running (pmon confirmed + sqlplus responsive)."

        local current_home
        current_home=$(get_db_home "$DB_UNIQUE_NAME")
        if [[ -z "$current_home" ]]; then
            current_home="$OLD_DB_HOME"
        fi
        add_html_row "Current ORACLE_HOME" "INFO" "$current_home"
        add_html_row "Target ORACLE_HOME" "INFO" "$NEW_DB_HOME"

        if [[ "$current_home" == "$NEW_DB_HOME" ]]; then
            add_html_row "DB Switch" "WARN" \
                "Database $DB_UNIQUE_NAME is already running from $NEW_DB_HOME — nothing to switch."
            send_phase_html_report "DB Switch" "DB Switch Report - $HOST" "WARN"
            return 0
        fi

        if [[ "$DRYRUN" == true ]]; then
            log "[DRYRUN] Would switch $DB_UNIQUE_NAME from $current_home to $NEW_DB_HOME"
            add_html_row "DB Switch (dry-run)" "INFO" "DRYRUN: no changes applied."
            send_phase_html_report "DB Switch" "DB Switch (Dry-run) - $HOST" "INFO"
            return 0
        fi

        # Validate pfile/spfile in new home — auto-copy from old home if missing
        local new_dbs="$NEW_DB_HOME/dbs"
        local old_dbs="$current_home/dbs"
        local _dbs_ok=false
        for _f in "spfile${sid_for_switch}.ora" "init${sid_for_switch}.ora" \
                   "spfile${DB_UNIQUE_NAME}.ora" "init${DB_UNIQUE_NAME}.ora"; do
            [[ -f "$new_dbs/$_f" ]] && { _dbs_ok=true; break; }
        done
        if [[ "$_dbs_ok" == true ]]; then
            add_html_row "DBS files check" "PASS" "init/spfile found in $new_dbs."
        else
            # Try to copy from current home
            local _copied=()
            for _f in "spfile${sid_for_switch}.ora" "init${sid_for_switch}.ora" \
                       "spfile${DB_UNIQUE_NAME}.ora" "init${DB_UNIQUE_NAME}.ora" \
                       "orapw${sid_for_switch}" "orapw${DB_UNIQUE_NAME}"; do
                if [[ -f "$old_dbs/$_f" ]]; then
                    sudo -u "$ORACLE_USER" cp -p "$old_dbs/$_f" "$new_dbs/$_f" 2>/dev/null && \
                        _copied+=("$_f")
                fi
            done
            if [[ ${#_copied[@]} -gt 0 ]]; then
                add_html_row "DBS files check" "PASS" \
                    "Copied from $old_dbs: ${_copied[*]}. New home dbs directory is ready."
            else
                add_html_row "DBS files check" "FAIL" \
                    "No init/spfile found in $new_dbs or $old_dbs for SID '$sid_for_switch'. Run db_install first to copy database files to the new home."
                send_phase_html_report "DB Switch" "DB Switch Report - $HOST" "FAIL"
                return 1
            fi
        fi

        local new_net="$NEW_DB_HOME/network/admin"
        if [[ -f "$new_net/tnsnames.ora" ]]; then
            add_html_row "Network files check" "PASS" \
                "tnsnames.ora found in $new_net."
        else
            add_html_row "Network files check" "WARN" \
                "tnsnames.ora not found in $new_net. TNS resolution may fail."
        fi

        # -------------------------------------------------------
        # Try AutoUpgrade (handles shutdown, startup, oratab, datapatch)
        # -------------------------------------------------------
        local autoupgrade_jar="$NEW_DB_HOME/rdbms/admin/autoupgrade.jar"
        local au_switch_used=false

        if [[ -f "$autoupgrade_jar" ]]; then
            local java_bin=""
            if [[ -x "$NEW_DB_HOME/jdk/bin/java" ]]; then
                java_bin="$NEW_DB_HOME/jdk/bin/java"
            elif [[ -x "$NEW_DB_HOME/jdk/jre/bin/java" ]]; then
                java_bin="$NEW_DB_HOME/jdk/jre/bin/java"
            elif [[ -x "$current_home/jdk/bin/java" ]]; then
                java_bin="$current_home/jdk/bin/java"
            elif [[ -x "$current_home/jdk/jre/bin/java" ]]; then
                java_bin="$current_home/jdk/jre/bin/java"
            elif command -v java &>/dev/null; then
                java_bin="java"
            fi

            if [[ -z "$java_bin" ]]; then
                add_html_row "AutoUpgrade" "WARN" \
                    "No java found — skipping AutoUpgrade."
            else
                add_html_row "Switch method" "INFO" "AutoUpgrade deploy (handles shutdown, startup, oratab, datapatch)."
                add_html_row "Java binary" "INFO" "$java_bin"

                local au_cfg au_logdir
                local _au_cfg_out
                _au_cfg_out=$(write_db_switch_autoupgrade_cfg "$DB_UNIQUE_NAME" "$current_home" "$NEW_DB_HOME")
                au_logdir=$(echo "$_au_cfg_out" | tail -2 | head -1)
                au_cfg=$(echo "$_au_cfg_out" | tail -1)
                add_html_row "AutoUpgrade config" "INFO" "$au_cfg"

                local au_log="${DB_LOG_DIR}/autoupgrade_switch_${DB_UNIQUE_NAME}_$(date +%F_%H%M%S).log"

                log "Starting AutoUpgrade deploy for DB switch..."
                sudo -u "$ORACLE_USER" bash -c "
                    export ORACLE_HOME=\"$NEW_DB_HOME\"
                    export PATH=\"$NEW_DB_HOME/jdk/bin:$NEW_DB_HOME/bin:\$PATH\"
                    export LD_LIBRARY_PATH=\"$NEW_DB_HOME/lib:\${LD_LIBRARY_PATH:-}\"
                    \"$java_bin\" -jar \"$autoupgrade_jar\" \
                        -config \"$au_cfg\" \
                        -mode deploy \
                        -noconsole
                " &> "$au_log" &

                local au_pid=$!
                local au_timeout=3600
                local au_poll=15
                local au_elapsed=0
                local au_success=false
                local au_failure_reason="Unknown"
                local au_lines_seen=0

                log "Monitoring AutoUpgrade deploy (PID=$au_pid) with timeout ${au_timeout}s..."
                while (( au_elapsed < au_timeout )); do
                    if [[ -f "$au_log" ]]; then
                        # Stream any new lines from the AutoUpgrade log to the UI
                        local au_total_now
                        au_total_now=$(wc -l < "$au_log" 2>/dev/null || echo 0)
                        if (( au_total_now > au_lines_seen )); then
                            tail -n +"$(( au_lines_seen + 1 ))" "$au_log" | while IFS= read -r _au_line; do
                                echo "[AutoUpgrade] ${_au_line}"
                            done
                            au_lines_seen=$au_total_now
                        fi

                        if grep -qi "Job .* completed" "$au_log" 2>/dev/null; then
                            if grep -q "Jobs failed.*\[0\]" "$au_log" 2>/dev/null || \
                               grep -qi "Jobs finished.*\[1\]" "$au_log" 2>/dev/null; then
                                au_success=true
                                break
                            fi
                        fi
                        if grep -qiE "Jobs failed.*\[[1-9]" "$au_log" 2>/dev/null; then
                            au_failure_reason="AutoUpgrade reported failed job(s). See $au_log"
                            break
                        fi
                        if grep -qi "FATAL ERROR\|AutoUpgrade failed" "$au_log" 2>/dev/null; then
                            au_failure_reason="AutoUpgrade FATAL ERROR. See $au_log"
                            break
                        fi
                    fi
                    if ! kill -0 "$au_pid" 2>/dev/null; then
                        local au_rc=0
                        wait "$au_pid" || au_rc=$?
                        # Flush any remaining log lines
                        if [[ -f "$au_log" ]]; then
                            au_total_now=$(wc -l < "$au_log" 2>/dev/null || echo 0)
                            if (( au_total_now > au_lines_seen )); then
                                tail -n +"$(( au_lines_seen + 1 ))" "$au_log" | while IFS= read -r _au_line; do
                                    echo "[AutoUpgrade] ${_au_line}"
                                done
                            fi
                        fi
                        if grep -qi "Job .* completed" "$au_log" 2>/dev/null && \
                           grep -q "Jobs failed.*\[0\]" "$au_log" 2>/dev/null; then
                            au_success=true
                        else
                            au_failure_reason="AutoUpgrade exited with RC=${au_rc}. See $au_log"
                        fi
                        break
                    fi
                    sleep "$au_poll"
                    au_elapsed=$(( au_elapsed + au_poll ))
                done

                if [[ "$au_success" != true && $au_elapsed -ge $au_timeout ]]; then
                    au_failure_reason="Timeout after ${au_timeout}s. See $au_log"
                    kill "$au_pid" 2>/dev/null || true
                fi

                add_html_attachment "$au_log" "AutoUpgrade Deploy Log"
                local au_status_dir="${au_logdir}/cfgtoollogs/upgrade/auto/status"
                local au_status_html="${au_status_dir}/status.html"
                local au_status_log="${au_status_dir}/status.log"
                if [[ -f "$au_status_html" ]]; then
                    add_attachment "$au_status_html"
                fi
                if [[ -f "$au_status_log" ]]; then
                    add_attachment "$au_status_log"
                fi

                # Emit AU logs into the UI Reports tab for inline viewing
                emit_file_as_html_report "$au_log" "AutoUpgrade Switch Log - ${DB_UNIQUE_NAME} - ${HOST}"
                emit_file_as_html_report "$au_status_html" "AutoUpgrade Status - ${DB_UNIQUE_NAME} - ${HOST}"
                emit_file_as_html_report "$au_status_log" "AutoUpgrade Status Log - ${DB_UNIQUE_NAME} - ${HOST}"

                # Parse status.log for [Detail] and Summary: file paths and emit each as a report
                if [[ -f "$au_status_log" ]]; then
                    while IFS= read -r _sl; do
                        local _fpath=""
                        # Match "[Detail]        /path/to/file" lines
                        if [[ "$_sl" =~ \[Detail\][[:space:]]+(/[^[:space:]]+) ]]; then
                            _fpath="${BASH_REMATCH[1]}"
                        # Match "Summary:/path/to/file" line
                        elif [[ "$_sl" =~ ^Summary:(/[^[:space:]]+) ]]; then
                            _fpath="${BASH_REMATCH[1]}"
                        fi
                        if [[ -n "$_fpath" && -f "$_fpath" ]]; then
                            local _fname
                            _fname=$(basename "$_fpath")
                            # Derive a human-readable stage name from the parent directory
                            local _stage
                            _stage=$(basename "$(dirname "$_fpath")" | tr '[:lower:]' '[:upper:]')
                            emit_file_as_html_report "$_fpath" "AU ${_stage} - ${_fname} - ${DB_UNIQUE_NAME} - ${HOST}"
                        fi
                    done < "$au_status_log"
                fi

                if [[ "$au_success" == true ]]; then
                    add_html_row "AutoUpgrade deploy" "PASS" \
                        "AutoUpgrade completed (shutdown, startup, oratab, datapatch all handled)."
                    au_switch_used=true
                else
                    add_html_row "AutoUpgrade deploy" "FAIL" "$au_failure_reason"
                    log "AutoUpgrade failed: $au_failure_reason — falling back to SQL*Plus."
                    add_html_row "Fallback" "WARN" "Falling back to SQL*Plus shutdown/startup."
                fi
            fi
        else
            add_html_row "Switch method" "INFO" \
                "AutoUpgrade JAR not found — using SQL*Plus."
        fi

        # -------------------------------------------------------
        # SQL*Plus fallback ONLY if AutoUpgrade was not used
        # -------------------------------------------------------
        if [[ "$au_switch_used" != true ]]; then
            log "Shutting down $DB_UNIQUE_NAME (SID=$sid_for_switch) from home $current_home..."
            local shutdown_out shutdown_rc=0
            shutdown_out=$(
                sudo -u "$ORACLE_USER" bash -c "
                    export ORACLE_HOME=\"$current_home\"
                    export ORACLE_SID=\"$sid_for_switch\"
                    export PATH=\"$current_home/bin:\$PATH\"
                    export LD_LIBRARY_PATH=\"$current_home/lib:\${LD_LIBRARY_PATH:-}\"
                    \"$current_home/bin/sqlplus\" -s / as sysdba 2>&1 <<'SQEOF'
shutdown immediate;
exit;
SQEOF
                "
            ) || shutdown_rc=$?
            log "Shutdown output (RC=$shutdown_rc): $shutdown_out"

            if echo "$shutdown_out" | grep -qi "ORACLE instance shut down\|ORA-01034\|not available"; then
                add_html_row "DB Shutdown" "PASS" "Database shut down successfully (or was already down)."
            else
                add_html_row "DB Shutdown" "WARN" \
                    "Shutdown RC=$shutdown_rc. Output: $(echo "$shutdown_out" | head -5). Proceeding."
            fi

            normalize_oratab_for_sid "$sid_for_switch" "$NEW_DB_HOME"

            log "Starting $DB_UNIQUE_NAME (SID=$sid_for_switch) from new home $NEW_DB_HOME..."
            local startup_out startup_rc=0
            startup_out=$(
                sudo -u "$ORACLE_USER" bash -c "
                    export ORACLE_HOME=\"$NEW_DB_HOME\"
                    export ORACLE_SID=\"$sid_for_switch\"
                    export PATH=\"$NEW_DB_HOME/bin:\$PATH\"
                    export LD_LIBRARY_PATH=\"$NEW_DB_HOME/lib:\${LD_LIBRARY_PATH:-}\"
                    \"$NEW_DB_HOME/bin/sqlplus\" -s / as sysdba 2>&1 <<'SQEOF'
startup;
exit;
SQEOF
                "
            ) || startup_rc=$?
            log "Startup output (RC=$startup_rc): $startup_out"

            if echo "$startup_out" | grep -qi "Database opened\|ORACLE instance started"; then
                add_html_row "DB Startup" "PASS" "Started successfully from $NEW_DB_HOME."
            else
                add_html_row "DB Startup" "WARN" \
                    "Startup RC=$startup_rc. Output: $(echo "$startup_out" | head -5). Check manually."
            fi
        fi

        # -------------------------------------------------------
        # Wait + datapatch (only for SQL*Plus fallback)
        # -------------------------------------------------------
        local ran_datapatch=false

        # Ensure oratab reflects NEW_DB_HOME before starting listener
        normalize_oratab_for_sid "${sid_for_switch:-$DB_UNIQUE_NAME}" "$NEW_DB_HOME"

        # -------------------------------------------------------
        # Listener management for DB_ONLY VMs with multiple DBs:
        # Only restart the listener once — when the NEW_DB_HOME listener
        # is not yet running. Concurrent db_switch jobs on the same VM
        # (one per DB) would otherwise each restart the listener.
        # Use a lock file so only the first job to reach this point restarts;
        # subsequent jobs skip gracefully because the listener is already up.
        # -------------------------------------------------------
        _maybe_restart_db_only_listener() {
            local _from_home="$1" _to_home="$2"
            if [[ "${DB_ONLY_MODE:-false}" != true ]]; then return 0; fi
            local _lock="/tmp/.listener_switch_${HOSTNAME}.lock"
            local _marker="/tmp/.listener_switched_to_${_to_home//\//_}"
            # If another db_switch job already moved the listener to NEW_DB_HOME, skip
            if [[ -f "$_marker" ]]; then
                add_html_row "Listener" "INFO" "Already restarted for NEW_DB_HOME by a concurrent switch job — skipping."
                return 0
            fi
            (
                flock -x 200
                if [[ ! -f "$_marker" ]]; then
                    manage_db_only_listener "$_from_home" "$_to_home"
                    touch "$_marker"
                else
                    add_html_row "Listener" "INFO" "Listener already moved to NEW_DB_HOME — skipping."
                fi
            ) 200>"$_lock"
        }

        if [[ "$au_switch_used" == true ]]; then
            if wait_for_db_ready_state "$DB_UNIQUE_NAME" "$NEW_DB_HOME"; then
                _maybe_restart_db_only_listener "$current_home" "$NEW_DB_HOME"
                send_db_open_notification "DB Switch" "$DB_UNIQUE_NAME" "$NEW_DB_HOME" "$DB_LAST_ROLE" "$DB_LAST_MODE"
                add_html_row "DB open mode check" "PASS" "Database reached target state (AutoUpgrade handled datapatch)."
                ran_datapatch=true
            else
                add_html_row "DB open mode check" "WARN" \
                    "Database did not reach target state within timeout after AutoUpgrade."
            fi
        else
            if wait_for_db_ready_state "$DB_UNIQUE_NAME" "$NEW_DB_HOME"; then
                _maybe_restart_db_only_listener "$current_home" "$NEW_DB_HOME"
                send_db_open_notification "DB Switch" "$DB_UNIQUE_NAME" "$NEW_DB_HOME" "$DB_LAST_ROLE" "$DB_LAST_MODE"
                add_html_row "DB open mode check" "PASS" "Database reached target state — running datapatch."

                sid_for_switch=$(get_db_sid "$DB_UNIQUE_NAME")
                [[ -z "$sid_for_switch" ]] && sid_for_switch="$DB_UNIQUE_NAME"

                if [[ -n "$sid_for_switch" ]]; then
                    run_cmd "ORACLE_HOME=\"$NEW_DB_HOME\" ORACLE_SID=\"$sid_for_switch\" PATH=\"$NEW_DB_HOME/bin:\$PATH\" \"$NEW_DB_HOME/OPatch/datapatch\" -verbose"
                    ran_datapatch=true
                else
                    add_html_row "Datapatch" "WARN" "Could not determine SID; skipping datapatch."
                fi
            else
                add_html_row "DB open mode check" "WARN" "Database did not reach target state — datapatch skipped."
            fi
        fi

        local switch_method="SQL*Plus"
        [[ "$au_switch_used" == true ]] && switch_method="AutoUpgrade"

        if [[ "$ran_datapatch" == true ]]; then
            add_html_row "DB Switch Result" "PASS" \
                "Switched to $NEW_DB_HOME via $switch_method. [DB_ONLY_MODE]"
            send_phase_html_report "DB Switch" "DB Switch Report - $HOST" "$PHASE_STATUS"
        else
            add_html_row "DB Switch Result" "WARN" \
                "Switched to $NEW_DB_HOME via $switch_method but datapatch did NOT run. [DB_ONLY_MODE]"
            send_phase_html_report "DB Switch" "DB Switch Report - $HOST" "$PHASE_STATUS"
        fi
        return 0
    fi

    # -------------------------------------------------------
    # SRVCTL path
    # -------------------------------------------------------
    local db_type_raw db_type
    db_type_raw=$(get_db_type "$DB_UNIQUE_NAME")
    db_type=$(echo "$db_type_raw" | tr '[:upper:]' '[:lower:]')

    if [[ -z "$db_type" || "$db_type" == "unknown" ]]; then
        local gi_mode
        gi_mode=$(detect_gi_cluster_mode)
        if [[ "$gi_mode" == "HAS" ]]; then
            db_type="single-instance"
            db_type_raw="SINGLE INSTANCE"
        fi
    fi

    local switch_desc
    case "$db_type" in
        raconenode)  switch_desc="RACOneNode switch to NEW_DB_HOME for $DB_UNIQUE_NAME" ;;
        rac*)        switch_desc="RAC switch to NEW_DB_HOME for $DB_UNIQUE_NAME" ;;
        *)           switch_desc="Single-instance switch to NEW_DB_HOME for $DB_UNIQUE_NAME" ;;
    esac

    add_html_row "DB Switch" "INFO" "$switch_desc"

    local autoupgrade_bin="$NEW_DB_HOME/autoupgrade/bin/autoupgrade"
    local ran_datapatch=false
    local sid_for_dp
    sid_for_dp=$(get_db_sid "$DB_UNIQUE_NAME")

    add_html_row "Database type" "INFO" "$DB_UNIQUE_NAME type detected as '${db_type_raw:-UNKNOWN}'"

    if [[ "$db_type" == rac* && "$db_type" != "raconenode" ]]; then
        add_html_row "Switch mode" "INFO" "RAC — rolling per instance"
        if [[ -x "$autoupgrade_bin" ]]; then
            run_cmd "$autoupgrade_bin -silent -configfile $DB_AUTOCFG"
        else
            for inst in $("$SRVCTL_BIN" status database -d "$DB_UNIQUE_NAME" | awk '/Instance/ {print $2}'); do
                run_cmd "$SRVCTL_BIN stop instance -d $DB_UNIQUE_NAME -i $inst"
                run_cmd "$SRVCTL_BIN modify database -d $DB_UNIQUE_NAME -oraclehome $NEW_DB_HOME"
                run_cmd "$SRVCTL_BIN start instance -d $DB_UNIQUE_NAME -i $inst"
            done
        fi
        if wait_for_db_open_readwrite "$DB_UNIQUE_NAME" "$NEW_DB_HOME"; then
            send_db_open_notification "DB Switch" "$DB_UNIQUE_NAME" "$NEW_DB_HOME" "$DB_LAST_ROLE" "$DB_LAST_MODE"
            if [[ -n "$sid_for_dp" ]]; then
                run_cmd "ORACLE_HOME=\"$NEW_DB_HOME\" ORACLE_SID=\"$sid_for_dp\" PATH=\"$NEW_DB_HOME/bin:\$PATH\" \"$NEW_DB_HOME/OPatch/datapatch\" -verbose"
                ran_datapatch=true
            fi
        fi

    elif [[ "$db_type" == "raconenode" ]]; then
        add_html_row "Switch mode" "INFO" "RACOneNode — srvctl stop/modify/start"
        if [[ -x "$autoupgrade_bin" ]]; then
            run_cmd "$autoupgrade_bin -silent -configfile $DB_AUTOCFG"
        else
            run_cmd "$SRVCTL_BIN stop database -d $DB_UNIQUE_NAME"
            run_cmd "$SRVCTL_BIN modify database -d $DB_UNIQUE_NAME -oraclehome $NEW_DB_HOME"
            run_cmd "$SRVCTL_BIN start database -d $DB_UNIQUE_NAME"
        fi
        if wait_for_db_open_readwrite "$DB_UNIQUE_NAME" "$NEW_DB_HOME"; then
            send_db_open_notification "DB Switch" "$DB_UNIQUE_NAME" "$NEW_DB_HOME" "$DB_LAST_ROLE" "$DB_LAST_MODE"
            if [[ -n "$sid_for_dp" ]]; then
                run_cmd "ORACLE_HOME=\"$NEW_DB_HOME\" ORACLE_SID=\"$sid_for_dp\" PATH=\"$NEW_DB_HOME/bin:\$PATH\" \"$NEW_DB_HOME/OPatch/datapatch\" -verbose"
                ran_datapatch=true
            fi
        fi

    else
        add_html_row "Switch mode" "INFO" "Single-instance — srvctl stop/modify/start"
        if [[ -x "$autoupgrade_bin" ]]; then
            run_cmd "$autoupgrade_bin -silent -configfile $DB_AUTOCFG"
        else
            run_cmd "$SRVCTL_BIN stop database -d $DB_UNIQUE_NAME"
            run_cmd "$SRVCTL_BIN modify database -d $DB_UNIQUE_NAME -oraclehome $NEW_DB_HOME"
            run_cmd "$SRVCTL_BIN start database -d $DB_UNIQUE_NAME"
        fi
        if wait_for_db_open_readwrite "$DB_UNIQUE_NAME" "$NEW_DB_HOME"; then
            send_db_open_notification "DB Switch" "$DB_UNIQUE_NAME" "$NEW_DB_HOME" "$DB_LAST_ROLE" "$DB_LAST_MODE"
            if [[ -n "$sid_for_dp" ]]; then
                run_cmd "ORACLE_HOME=\"$NEW_DB_HOME\" ORACLE_SID=\"$sid_for_dp\" PATH=\"$NEW_DB_HOME/bin:\$PATH\" \"$NEW_DB_HOME/OPatch/datapatch\" -verbose"
                ran_datapatch=true
            fi
        fi
    fi

    if [[ "$DRYRUN" == false ]]; then
        # Use the actual SID for oratab (not the unique name — oratab keys on SID)
        local _sid_for_oratab="${sid_for_dp:-}"
        [[ -z "$_sid_for_oratab" ]] && _sid_for_oratab=$(get_db_sid "$DB_UNIQUE_NAME" 2>/dev/null || true)
        [[ -z "$_sid_for_oratab" ]] && _sid_for_oratab="$DB_UNIQUE_NAME"
        normalize_oratab_for_sid "$_sid_for_oratab" "$NEW_DB_HOME"
    fi

    if [[ "$ran_datapatch" == true ]]; then
        add_html_row "DB Switch Result" "PASS" \
            "Switched to NEW_DB_HOME (${NEW_DB_HOME}) and datapatch executed."
        send_phase_html_report "DB Switch" "DB Switch Report - $HOST" "$PHASE_STATUS"
    else
        add_html_row "DB Switch Result" "WARN" \
            "Switched but datapatch did NOT run."
        send_phase_html_report "DB Switch" "DB Switch Report - $HOST" "WARN"
    fi

    # Snapshot homes at switch time so orchestrator can fade old rollback targets.
    # old_db_home becomes the rollback target; new_db_home becomes the new active.
    if [[ "$DRYRUN" == false && -n "${NEW_DB_HOME:-}" && -n "${OLD_DB_HOME:-}" ]]; then
        echo "[DISCOVERY_JSON] {\"type\":\"home_switched\",\"old_db_home\":\"${OLD_DB_HOME}\",\"new_db_home\":\"${NEW_DB_HOME}\",\"old_gi_home\":\"\",\"new_gi_home\":\"\"}"
    fi
}
db_switch() {
    prompt_for_db_unique
    db_switch_core "$DB_UNIQUE_NAME"
}
# ------------------------------------------------------------
# DB ROLLBACK (19c OOP)
# ------------------------------------------------------------
db_rollback() {
    reset_report
    reset_html_report
    LOG_FILE="${DB_LOG_DIR}/db_rollback_$(date +%F_%H%M%S).log"
    log "DB ROLLBACK (19c OOP)"

    # After a switch, OLD_DB_HOME is the patched (active) home. Use ROLLBACK_DB_HOME
    # (snapshotted at switch time) as the rollback target.
    if [[ -n "${ROLLBACK_DB_HOME:-}" && "$ROLLBACK_DB_HOME" != "$OLD_DB_HOME" ]]; then
        log "INFO: Using ROLLBACK_DB_HOME=${ROLLBACK_DB_HOME} as rollback target (OLD_DB_HOME was ${OLD_DB_HOME})"
        NEW_DB_HOME="${OLD_DB_HOME}"
        OLD_DB_HOME="${ROLLBACK_DB_HOME}"
    fi

    add_html_row "DB Rollback" "INFO" "Reverting database home: NEW=${NEW_DB_HOME} → OLD=${OLD_DB_HOME}"

    if [[ -z "${DB_UNIQUE_NAME:-}" ]]; then
        prompt_for_db_unique
    fi

    # -------------------------------------------------------
    # DB_ONLY_MODE: no srvctl
    # AutoUpgrade cannot downgrade (source RU > target RU)
    # so rollback always uses SQL*Plus shutdown/startup
    # -------------------------------------------------------
    if [[ "${DB_ONLY_MODE:-false}" == true || -z "$SRVCTL_BIN" ]]; then
        add_html_row "DB Rollback" "INFO" \
            "DB_ONLY_MODE: rolling back $DB_UNIQUE_NAME to OLD_DB_HOME via SQL*Plus (no srvctl, AutoUpgrade cannot downgrade)."

        local sid_for_rb
        sid_for_rb=$(get_db_sid "$DB_UNIQUE_NAME")
        if [[ -z "$sid_for_rb" ]]; then
            sid_for_rb="$DB_UNIQUE_NAME"
            add_html_row "SID resolution" "WARN" \
                "Could not find running PMON for $DB_UNIQUE_NAME; using ${sid_for_rb} as SID."
        else
            add_html_row "SID resolution" "INFO" "Resolved SID: ${sid_for_rb}"
        fi

        local current_home
        current_home=$(get_db_home "$DB_UNIQUE_NAME")
        if [[ -z "$current_home" ]]; then
            current_home="$NEW_DB_HOME"
        fi
        add_html_row "Current ORACLE_HOME" "INFO" "$current_home"
        add_html_row "Rollback target ORACLE_HOME" "INFO" "$OLD_DB_HOME"

        if [[ "$current_home" == "$OLD_DB_HOME" ]]; then
            add_html_row "DB Rollback" "WARN" \
                "Database $DB_UNIQUE_NAME is already running from $OLD_DB_HOME — nothing to roll back."
            send_phase_html_report "DB Rollback" "DB Rollback Report - $HOST" "WARN"
            return 0
        fi

        if [[ "$DRYRUN" == true ]]; then
            add_html_row "DB Rollback (dry-run)" "INFO" "DRYRUN: no changes applied."
            send_phase_html_report "DB Rollback" "DB Rollback (Dry-run) - $HOST" "INFO"
            return 0
        fi

        add_html_row "Rollback method" "INFO" \
            "SQL*Plus shutdown/startup (AutoUpgrade does not support downgrading RU versions)."

        # --- Shutdown from current home ---
        log "Shutting down $DB_UNIQUE_NAME (SID=${sid_for_rb}) from home $current_home..."
        local shutdown_out shutdown_rc=0
        shutdown_out=$(
            sudo -u "$ORACLE_USER" bash -c "
                export ORACLE_HOME=\"$current_home\"
                export ORACLE_SID=\"$sid_for_rb\"
                export PATH=\"$current_home/bin:\$PATH\"
                export LD_LIBRARY_PATH=\"$current_home/lib:\${LD_LIBRARY_PATH:-}\"
                \"$current_home/bin/sqlplus\" -s / as sysdba 2>&1 <<'SQEOF'
shutdown immediate;
exit;
SQEOF
            "
        ) || shutdown_rc=$?
        log "Shutdown output (RC=$shutdown_rc): $shutdown_out"

        if echo "$shutdown_out" | grep -qi "ORACLE instance shut down\|ORA-01034\|not available"; then
            add_html_row "DB Shutdown (rollback)" "PASS" "Database shut down successfully."
        else
            add_html_row "DB Shutdown (rollback)" "WARN" \
                "Shutdown RC=$shutdown_rc. Output: $(echo "$shutdown_out" | head -5). Proceeding."
        fi

        # --- Update /etc/oratab ---
        normalize_oratab_for_sid "$sid_for_rb" "$OLD_DB_HOME"

        # --- Startup from OLD_DB_HOME (untouched, no file copies needed) ---
        log "Starting $DB_UNIQUE_NAME (SID=${sid_for_rb}) from old home $OLD_DB_HOME..."
        local startup_out startup_rc=0
        startup_out=$(
            sudo -u "$ORACLE_USER" bash -c "
                export ORACLE_HOME=\"$OLD_DB_HOME\"
                export ORACLE_SID=\"$sid_for_rb\"
                export PATH=\"$OLD_DB_HOME/bin:\$PATH\"
                export LD_LIBRARY_PATH=\"$OLD_DB_HOME/lib:\${LD_LIBRARY_PATH:-}\"
                \"$OLD_DB_HOME/bin/sqlplus\" -s / as sysdba 2>&1 <<'SQEOF'
startup;
exit;
SQEOF
            "
        ) || startup_rc=$?
        log "Startup output (RC=$startup_rc): $startup_out"

        if echo "$startup_out" | grep -qi "Database opened\|ORACLE instance started"; then
            add_html_row "DB Startup (rollback)" "PASS" "Started from $OLD_DB_HOME."
        else
            add_html_row "DB Startup (rollback)" "WARN" \
                "Startup RC=$startup_rc. Output: $(echo "$startup_out" | head -5). Check manually."
        fi

        # --- Wait for ready state + listener start + datapatch ---
        local ran_datapatch=false

        if wait_for_db_ready_state "$DB_UNIQUE_NAME" "$OLD_DB_HOME"; then
            # DB_ONLY_MODE only — on GI systems the listener is managed by CRS; do not touch it
            [[ "${DB_ONLY_MODE:-false}" == true ]] && manage_db_only_listener "$current_home" "$OLD_DB_HOME"
            send_db_open_notification "DB Rollback" "$DB_UNIQUE_NAME" "$OLD_DB_HOME" "$DB_LAST_ROLE" "$DB_LAST_MODE"
            if [[ "$DB_LAST_ROLE" == "PRIMARY" ]]; then
                add_html_row "DB open mode check (rollback)" "PASS" \
                    "Database role PRIMARY reached OPEN READ WRITE — running datapatch."
                sid_for_rb=$(get_db_sid "$DB_UNIQUE_NAME")
                [[ -z "$sid_for_rb" ]] && sid_for_rb="$DB_UNIQUE_NAME"
                if [[ -n "$sid_for_rb" ]]; then
                    add_html_row "Datapatch" "INFO" "Running datapatch on $OLD_DB_HOME..."
                    run_cmd "ORACLE_HOME=\"$OLD_DB_HOME\" ORACLE_SID=\"$sid_for_rb\" PATH=\"$OLD_DB_HOME/bin:\$PATH\" \"$OLD_DB_HOME/OPatch/datapatch\" -verbose"
                    ran_datapatch=true
                    add_html_row "Datapatch" "PASS" "datapatch completed on $OLD_DB_HOME"
                fi
            else
                add_html_row "DB open mode check (rollback)" "PASS" \
                    "Database role $DB_LAST_ROLE — datapatch skipped (standby)."
            fi
        else
            add_html_row "DB open mode check (rollback)" "WARN" \
                "Database did not reach target state — datapatch skipped."
        fi

        local msg="Database $DB_UNIQUE_NAME rolled back to OLD_DB_HOME (${OLD_DB_HOME}) via SQL*Plus. [DB_ONLY_MODE]"
        if [[ "$ran_datapatch" == true ]]; then
            add_html_row "DB Rollback Result" "PASS" "$msg Datapatch executed."
        else
            add_html_row "DB Rollback Result" "WARN" "$msg Datapatch did NOT run."
        fi

        send_phase_html_report "DB Rollback" "DB Rollback Report - $HOST" "$PHASE_STATUS"
        return 0
    fi

    # -------------------------------------------------------
    # SRVCTL path
    # -------------------------------------------------------
    local db_type
    db_type=$(get_db_type "$DB_UNIQUE_NAME" | tr '[:upper:]' '[:lower:]')

    add_html_row "Database type" "INFO" "$DB_UNIQUE_NAME type detected as ${db_type:-UNKNOWN}"

    if [[ "$db_type" == rac* && "$db_type" != "raconenode" ]]; then
        add_html_row "Rollback mode" "INFO" "RAC — rolling per instance"
        for inst in $("$SRVCTL_BIN" status database -d "$DB_UNIQUE_NAME" | awk '/Instance/ {print $2}'); do
            add_html_row "Instance $inst" "INFO" "Stopping and rolling back instance $inst"
            run_cmd "$SRVCTL_BIN stop instance -d $DB_UNIQUE_NAME -i $inst || true"
            run_cmd "$SRVCTL_BIN modify database -d $DB_UNIQUE_NAME -oraclehome $OLD_DB_HOME"
            run_cmd "$SRVCTL_BIN start instance -d $DB_UNIQUE_NAME -i $inst || true"
            add_html_row "Instance $inst" "PASS" "Rolled back and restarted"
        done
    elif [[ "$db_type" == "raconenode" ]]; then
        add_html_row "Rollback mode" "INFO" "RACOneNode — srvctl stop/modify/start"
        run_cmd "$SRVCTL_BIN stop database -d $DB_UNIQUE_NAME || true"
        run_cmd "$SRVCTL_BIN modify database -d $DB_UNIQUE_NAME -oraclehome $OLD_DB_HOME"
        run_cmd "$SRVCTL_BIN start database -d $DB_UNIQUE_NAME || true"
    else
        add_html_row "Rollback mode" "INFO" "Single-instance — srvctl stop/modify/start"
        run_cmd "$SRVCTL_BIN stop database -d $DB_UNIQUE_NAME || true"
        run_cmd "$SRVCTL_BIN modify database -d $DB_UNIQUE_NAME -oraclehome $OLD_DB_HOME"
        run_cmd "$SRVCTL_BIN start database -d $DB_UNIQUE_NAME || true"
    fi

    local ran_datapatch=false
    local sid_for_dp
    sid_for_dp=$(get_db_sid "$DB_UNIQUE_NAME")

    if wait_for_db_ready_state "$DB_UNIQUE_NAME" "$OLD_DB_HOME"; then
        send_db_open_notification "DB Rollback" "$DB_UNIQUE_NAME" "$OLD_DB_HOME" "$DB_LAST_ROLE" "$DB_LAST_MODE"
        if [[ "$DB_LAST_ROLE" == "PRIMARY" ]]; then
            add_html_row "DB open mode check (rollback)" "PASS" \
                "Database role PRIMARY reached OPEN READ WRITE — running datapatch."
            if [[ -n "$sid_for_dp" ]]; then
                add_html_row "Datapatch" "INFO" "Running datapatch on $OLD_DB_HOME..."
                run_cmd "ORACLE_HOME=\"$OLD_DB_HOME\" ORACLE_SID=\"$sid_for_dp\" PATH=\"$OLD_DB_HOME/bin:\$PATH\" \"$OLD_DB_HOME/OPatch/datapatch\" -verbose"
                ran_datapatch=true
                add_html_row "Datapatch" "PASS" "datapatch completed on $OLD_DB_HOME"
            fi
        else
            add_html_row "DB open mode check (rollback)" "PASS" \
                "Database role $DB_LAST_ROLE — datapatch skipped (standby)."
        fi
    else
        add_html_row "DB open mode check (rollback)" "WARN" \
            "Database did not reach target state — datapatch skipped."
    fi

    if [[ "$DRYRUN" == false ]]; then
        normalize_oratab_for_sid "${sid_for_dp:-$DB_UNIQUE_NAME}" "$OLD_DB_HOME"
    fi

    if [[ -f "${LOG_DIR}/db_old_patchlevel.html" ]]; then
        local pl_old
        pl_old=$(<"${LOG_DIR}/db_old_patchlevel.html")
        add_html_row "DB patch level (OLD_DB_HOME)" "INFO" "$pl_old"
    fi

    local msg="Database $DB_UNIQUE_NAME rolled back to OLD_DB_HOME (${OLD_DB_HOME})."
    if [[ "$ran_datapatch" == true ]]; then
        add_html_row "DB Rollback Result" "PASS" "$msg Datapatch executed."
        send_phase_html_report "DB Rollback" "DB Rollback Report - $HOST" "$PHASE_STATUS"
    else
        add_html_row "DB Rollback Result" "WARN" "$msg Datapatch did NOT run. Verify DB is open and run datapatch manually: ORACLE_HOME=$OLD_DB_HOME ORACLE_SID=\$(srvctl status database -d $DB_UNIQUE_NAME | awk '/Instance/{print \$2}') $OLD_DB_HOME/OPatch/datapatch -verbose"
        send_phase_html_report "DB Rollback" "DB Rollback Report - $HOST" "WARN"
    fi
}
# ------------------------------------------------------------
# DB OJVM ONLY (NEW_DB_HOME)
# ------------------------------------------------------------
db_ojvm_only() {
    reset_report
    reset_html_report
    LOG_FILE="${DB_LOG_DIR}/db_ojvm_only_$(date +%F_%H%M%S).log"
    log "DB OJVM ONLY (NEW_DB_HOME)"

    add_html_row "Target ORACLE_HOME" "INFO" "$NEW_DB_HOME"
    add_html_row "OJVM_PATCH_DIR" "INFO" "${OJVM_PATCH_DIR:-<unset>}"
    add_html_row "APPLY_OJVM_ON_DB_INSTALL" "INFO" "${APPLY_OJVM_ON_DB_INSTALL:-false}"

    if [[ "${APPLY_OJVM_ON_DB_INSTALL:-false}" != true ]]; then
        add_html_row "OJVM opatch (NEW_DB_HOME)" "WARN" \
            "APPLY_OJVM_ON_DB_INSTALL=false ? no OJVM opatch run. Enable in manual config if you intend to patch NEW_DB_HOME now."
        send_phase_html_report "DB OJVM Only" "DB OJVM Only (No Action) - $HOST" "WARN"
        return 0
    fi

    apply_ojvm_on_db_install_if_enabled
    send_phase_html_report "DB OJVM Only" "DB OJVM Only Report - $HOST" "INFO"
}
# ------------------------------------------------------------
# DB SCHEDULING
# ------------------------------------------------------------
schedule_db_switch() {
    ensure_at_service
    echo "Scheduling DB switch:"
    prompt_for_db_unique
    local db="$DB_UNIQUE_NAME"
    read -rp "Enter DB switch schedule datetime (YYYY-MM-DD HH:MM): " sched_time
    if [[ ! "$sched_time" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})[[:space:]]([0-9]{2}):([0-9]{2})$ ]]; then
        echo "Invalid format. Use: YYYY-MM-DD HH:MM"
        sleep 2
        return 0
    fi
    local year="${BASH_REMATCH[1]}"
    local month="${BASH_REMATCH[2]}"
    local day="${BASH_REMATCH[3]}"
    local hour="${BASH_REMATCH[4]}"
    local minute="${BASH_REMATCH[5]}"
    local at_time="${hour}:${minute} ${month}/${day}/${year}"
    local out jobid
    out=$(echo "$SCRIPT_PATH db_switch_scheduled $db" | at "$at_time" 2>&1)
    jobid=$(awk '/job/{print $2}' <<<"$out" || true)
    log "DB switch for $db scheduled for $sched_time (jobid=${jobid:-unknown})"
    echo "DB switch for $db scheduled for $sched_time (jobid=${jobid:-unknown})"
    sleep 2
}
schedule_db_upgrade() {
    ensure_at_service
    echo "Scheduling DB upgrade (AutoUpgrade DEPLOY):"
    prompt_for_db_unique
    local db="$DB_UNIQUE_NAME"

    read -rp "Enter DB upgrade schedule datetime (YYYY-MM-DD HH:MM): " sched_time
    if [[ ! "$sched_time" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})[[:space:]]([0-9]{2}):([0-9]{2})$ ]]; then
        echo "Invalid format. Use: YYYY-MM-DD HH:MM"
        sleep 2
        return 0
    fi

    local year="${BASH_REMATCH[1]}"
    local month="${BASH_REMATCH[2]}"
    local day="${BASH_REMATCH[3]}"
    local hour="${BASH_REMATCH[4]}"
    local minute="${BASH_REMATCH[5]}"
    local at_time="${hour}:${minute} ${month}/${day}/${year}"

    local out jobid
    out=$(echo "$SCRIPT_PATH db_upgrade_upgrade_scheduled $db" | at "$at_time" 2>&1)
    jobid=$(awk '/job/{print $2}' <<<"$out" || true)

    log "DB upgrade (DEPLOY) for $db scheduled for $sched_time (jobid=${jobid:-unknown})"
    echo "DB upgrade (DEPLOY) for $db scheduled for $sched_time (jobid=${jobid:-unknown})"
    sleep 2
}
# ------------------------------------------------------------
# NEW: DB UPGRADE HELPERS (AutoUpgrade)
# ------------------------------------------------------------
write_db_autoupgrade_cfg() {
    local db="$1"
    local sid=""
    local src_home=""
    local tgt_home="$DB_UPGRADE_NEW_HOME"

    sid=$(get_db_sid "$db")
    [[ -z "$sid" ]] && sid="$db"

    src_home=$(get_home_from_oratab_for_sid "$sid")
    [[ -z "$src_home" ]] && src_home="$DB_UPGRADE_OLD_HOME"

    local logdir="${DB_UPGRADE_LOG_DIR}/autoup_${db}_$(date +%F_%H%M%S)"
    mkdir -p "$logdir"

    cat > "$DB_UPGRADE_CONFIG" <<EOF
global.autoupg_log_dir=${logdir}
upg1.sid=${sid}
upg1.source_home=${src_home}
upg1.target_home=${tgt_home}
upg1.log_dir=${logdir}/upg1
upg1.target_cdb=yes
EOF
    chown "${ORACLE_USER}:${OINSTALL}" "$DB_UPGRADE_CONFIG" 2>/dev/null || true
    chmod 600 "$DB_UPGRADE_CONFIG" 2>/dev/null || true

    echo "$logdir"
}

# ------------------------------------------------------------
# DB SWITCH HELPER: Write AutoUpgrade config for OOP patching
# (source=OLD_DB_HOME -> target=NEW_DB_HOME, deploy mode)
# Modelled after write_db_autoupgrade_cfg() for upgrades.
# ------------------------------------------------------------
write_db_switch_autoupgrade_cfg() {
    local db="$1"
    local src_home_override="${2:-}"
    local tgt_home_override="${3:-$NEW_DB_HOME}"
    local sid=""
    local src_home=""

    sid=$(get_db_sid "$db")
    [[ -z "$sid" ]] && sid="$db"

    if [[ -n "$src_home_override" && -d "$src_home_override" ]]; then
        src_home="$src_home_override"
    else
        src_home=$(get_db_home "$db")
        [[ -z "$src_home" ]] && src_home=$(get_home_from_oratab_for_sid "$sid")
        [[ -z "$src_home" ]] && src_home="$OLD_DB_HOME"
    fi

    local logdir="${DB_LOG_DIR}/autoup_switch_${db}_$(date +%F_%H%M%S)"
    mkdir -p "$logdir"

    local cfg_file="${DB_LOG_DIR}/db_switch_autoupgrade_${db}.cfg"

    # Derive target Oracle version from the home path (e.g. /app/oracle/product/19.26 → 19)
    # AutoUpgrade deploy mode (patching within same major version) does not use target_version,
    # but setting it avoids interactive prompts when source and target are both 19c.
    local target_version="19"
    if [[ "$tgt_home_override" =~ /([0-9]+)\.[0-9]+ ]]; then
        target_version="${BASH_REMATCH[1]}"
    fi

    cat > "$cfg_file" <<EOF
global.autoupg_log_dir=${logdir}
global.timezone_upg=no
global.restoration=no

upg1.sid=${sid}
upg1.source_home=${src_home}
upg1.target_home=${tgt_home_override}
upg1.target_version=${target_version}
upg1.log_dir=${logdir}/upg1
upg1.start_time=NOW
EOF
    chown "${ORACLE_USER}:${OINSTALL}" "$cfg_file" 2>/dev/null || true
    chmod 600 "$cfg_file" 2>/dev/null || true

    log "INFO: write_db_switch_autoupgrade_cfg: config written to $cfg_file"
    log "INFO:   SID=$sid, source_home=$src_home, target_home=$tgt_home_override, log_dir=$logdir"

    echo "$logdir"
    echo "$cfg_file"
}
db_upgrade_precheck() {
    reset_html_report
    LOG_FILE="${DB_UPGRADE_LOG_DIR}/db_upgrade_precheck_$(date +%F_%H%M%S).log"
    log "DB UPGRADE PRECHECK (19c -> 23/26ai; DB + host + AutoUpgrade ANALYZE)"

    # ------------------------------------------------------------------
    # Reuse all the DB_PRECHECK-style checks, but labelled as upgrade
    # ------------------------------------------------------------------
    check_at_service_html

    local gi_fs db_fs
    gi_fs=$(df -P "$OLD_GI_HOME" 2>/dev/null | awk 'NR==2{print $6}' || true)
    db_fs=$(df -P "$OLD_DB_HOME" 2>/dev/null | awk 'NR==2{print $6}' || true)

    if [[ -n "$db_fs" ]]; then
        check_space_html "$db_fs" 30
    else
        add_html_row "Filesystem space for OLD_DB_HOME" "WARN" "Could not determine filesystem for $OLD_DB_HOME"
    fi
    if [[ -n "$gi_fs" ]]; then
        check_space_html "$gi_fs" 20
    else
        add_html_row "Filesystem space for OLD_GI_HOME" "WARN" "Could not determine filesystem for $OLD_GI_HOME"
    fi

    check_oracle_sudo_nopass_html
    detect_cluster_type_html

    local oratab_html
    oratab_html=$(format_oratab_html "$OLD_DB_HOME")
    add_html_row "/etc/oratab entries" "INFO" "$oratab_html"

    # OPatch in OLD_DB_HOME
    if [[ -d "$OLD_DB_HOME" ]]; then
        local req_opatch_db cur_opatch_db
        req_opatch_db=$(required_opatch_version)
        cur_opatch_db=$(current_opatch_version "$OLD_DB_HOME")
        if [[ -z "$req_opatch_db" ]]; then
            add_html_row "OPatch version (DB home)" "WARN" \
                "Could not parse required OPatch version from $RU_README; current DB OPatch is ${cur_opatch_db:-unknown}."
        else
            if [[ -z "$cur_opatch_db" || "$cur_opatch_db" == "0" ]]; then
                add_html_row "OPatch version (DB home)" "INFO" \
                    "Required: $req_opatch_db (per $RU_README), current DB OPatch in $OLD_DB_HOME is unknown. OPatch will be updated during DB install/upgrade using $OPATCH_ZIP (if configured)."
            else
                if compare_versions "$cur_opatch_db" "$req_opatch_db"; then
                    add_html_row "OPatch version (DB home)" "INFO" \
                        "Current: $cur_opatch_db, required: $req_opatch_db (per $RU_README)."
                else
                    add_html_row "OPatch version (DB home)" "WARN" \
                        "Current DB OPatch in $OLD_DB_HOME is $cur_opatch_db, lower than required $req_opatch_db (per $RU_README). OPatch will be updated during DB install/upgrade using $OPATCH_ZIP."
                fi
            fi
        fi
    else
        add_html_row "OPatch version (DB home)" "WARN" \
            "OLD_DB_HOME ($OLD_DB_HOME) does not exist; cannot report OPatch version."
    fi

    # Config files
    discover_db_files
    if [[ ${#DB_FILES[@]} -gt 0 ]]; then
        add_html_row "DB config files discovered" "INFO" "$(printf "%s " "${DB_FILES[@]}")"
    else
        add_html_row "DB config files discovered" "INFO" \
            "No DB home config files discovered under $OLD_DB_HOME (may be expected if config is centralised or in a different home)."
    fi

    # DBs, open modes, patch levels, PDBs (same as db_precheck)
    discover_databases
    if [[ ${#DB_UNIQUES[@]} -gt 0 ]]; then
        local html_summary=""
        for db in "${DB_UNIQUES[@]}"; do
            local home t mode pl pdbs
            home=$(get_db_home "$db")
            t=$(get_db_type "$db")
            if [[ -z "$t" ]]; then
                local gi_mode
                gi_mode=$(detect_gi_cluster_mode)
                if [[ "$gi_mode" == "HAS" ]]; then
                    t="ORACLE RESTART"
                fi
            fi
            if [[ -z "$home" ]]; then
                mode="UNKNOWN (Oracle home not found; cannot connect)"
                pl="Oracle home not found via srvctl/oratab; cannot determine patch level."
                pdbs=""
            else
                mode=$(get_db_open_mode "$db" "$home")
                pl=$(get_patch_level "$home")
                pdbs=$(list_open_pdbs "$db" "$home")
            fi
            html_summary+="<b>${db}</b> (Type: ${t:-UNKNOWN}, Oracle home: ${home:-UNKNOWN})<br/>"
            html_summary+="  Current open mode: ${mode}<br/>"
            if [[ -n "$pl" ]]; then
                local pl_indented
                pl_indented=$(printf '%s\n' "$pl" | sed 's/^/  /')
                html_summary+="${pl_indented}<br/>"
            else
                html_summary+="  Patch level: unknown<br/>"
            fi
            if [[ -n "$pdbs" ]]; then
                html_summary+="  Open PDBs (will be upgraded and patched by datapatch):<br/>"
                while IFS= read -r p; do
                    [[ -n "$p" ]] || continue
                    html_summary+="    - ${p}<br/>"
                done <<< "$pdbs"
            else
                html_summary+="  Open PDBs: none or instance is non-CDB / not accessible.<br/>"
            fi
            html_summary+="<br/>"
        done
        add_html_row "DB status / patch levels (per database)" "INFO" "$html_summary"
    else
        add_html_row "DB status / patch levels" "INFO" \
            "No running PMON processes or srvctl-managed databases detected on this host at upgrade-precheck time."
    fi

    # OLD_DB_HOME patch snapshot
    local old_db_pl
    old_db_pl=$(get_patch_level "$OLD_DB_HOME" || echo "")
    if [[ -n "$old_db_pl" ]]; then
        echo "$old_db_pl" > "${LOG_DIR}/db_old_patchlevel.html"
    else
        echo "Patch level unknown for OLD_DB_HOME ($OLD_DB_HOME)" > "${LOG_DIR}/db_old_patchlevel.html"
    fi

    # ------------------------------------------------------------------
    # AutoUpgrade ANALYZE-specific part (existing logic, slightly tweaked)
    # ------------------------------------------------------------------
    # Optional CLI arg: DB unique name
    if [[ $# -ge 1 ]]; then
        DB_UNIQUE_NAME="$1"
        log "DB UPGRADE PRECHECK: using DB_UNIQUE_NAME from CLI: $DB_UNIQUE_NAME"
    else
        # Reuse DB_UNIQUES discovered above for selector
        prompt_for_db_unique
    fi
    local db="$DB_UNIQUE_NAME"

    local logdir
    logdir=$(write_db_autoupgrade_cfg "$db")

    add_html_row "DB Upgrade target (AutoUpgrade)" "INFO" \
        "DB=${db}, source_home=${DB_UPGRADE_OLD_HOME}, target_home=${DB_UPGRADE_NEW_HOME}"
    add_html_row "AutoUpgrade config" "INFO" "$DB_UPGRADE_CONFIG"
    add_html_row "AutoUpgrade log dir" "INFO" "$logdir"

    if [[ ! -f "$DB_UPGRADE_JAR" ]]; then
        add_html_row "AutoUpgrade JAR" "FAIL" \
            "autoupgrade.jar not found at $DB_UPGRADE_JAR. Ensure 23/26ai DB home is staged and jar located correctly."
        send_html_report "DB Upgrade Precheck FAILED - $db - $HOST" "DB Upgrade Precheck (Upgrade + Host)"
        return 0
    fi

    # Remind about ASM compat for upgrade
    local asm_cmds="
Check disk group RDBMS compatibility setting:
Expected: compatible_rdbms >= 19.0.0.0.0
Example manual commands to run as SYSASM (engineer only):
  sqlplus / as sysasm
  SELECT name, compatibility, database_compatibility FROM v\\\$asm_diskgroup;
If compatible_rdbms = 10.1.0.0.0, run:
  ALTER DISKGROUP DATA SET ATTRIBUTE 'compatible.rdbms'='19.0.0.0.0';
  ALTER DISKGROUP FRA  SET ATTRIBUTE 'compatible.rdbms'='19.0.0.0.0';
  SELECT name, compatibility, database_compatibility FROM v\\\$asm_diskgroup;
"
    add_html_row "ASM compatible.rdbms (DB upgrade)" "INFO" \
        "$(printf '%s\n' "$asm_cmds" | sed 's/$/<br\/>/' )"

    local au_log="${DB_UPGRADE_LOG_DIR}/autoupgrade_analyze_${db}_$(date +%F_%H%M%S).log"
    if [[ "$DRYRUN" == true ]]; then
        add_html_row "AutoUpgrade Analyze" "INFO" \
            "DRYRUN ? would run: java -jar $DB_UPGRADE_JAR -config $DB_UPGRADE_CONFIG -mode analyze"
    else
        run_cmd "java -jar \"$DB_UPGRADE_JAR\" -config \"$DB_UPGRADE_CONFIG\" -mode analyze > \"$au_log\" 2>&1 || true"
        add_attachment "$au_log"
    fi

    local html_report=""
    if [[ -d "$logdir" ]]; then
        html_report=$(find "$logdir" -type f -iname '*html*' 2>/dev/null | head -n1 || true)
    fi

    if [[ -n "$html_report" && -f "$html_report" ]]; then
        add_attachment "$html_report"
        add_html_row "AutoUpgrade Analyze HTML" "PASS" \
            "HTML analysis attached: $(basename "$html_report")."
    else
        add_html_row "AutoUpgrade Analyze HTML" "WARN" \
            "Could not locate HTML analysis under $logdir. Check autoupgrade analyze log: $au_log"
    fi

    send_html_report "DB Upgrade Precheck (Upgrade + Host + ANALYZE) - $db - $HOST" \
                     "DB Upgrade Precheck (19c -> 23/26ai)"
}
db_upgrade_install() {
    reset_html_report
    LOG_FILE="${DB_UPGRADE_LOG_DIR}/db_upgrade_install_$(date +%F_%H%M%S).log"
    log "DB UPGRADE INSTALL (23/26ai software)"

    add_html_row "DB Upgrade target ORACLE_HOME" "INFO" "$DB_UPGRADE_NEW_HOME"

    run_cmd "mkdir -p \"$DB_UPGRADE_NEW_HOME\""
    run_cmd "chown -R ${ORACLE_USER}:${OINSTALL} \"$DB_UPGRADE_NEW_HOME\""

    if [[ ! -f "$DB_UPGRADE_BASE_ZIP" ]]; then
        add_html_row "DB 23/26ai Base ZIP" "FAIL" "Missing DB_UPGRADE_BASE_ZIP: $DB_UPGRADE_BASE_ZIP"
        send_html_report "DB Upgrade Install FAILED - $HOST" "DB Upgrade Install"
        die "DB_UPGRADE_BASE_ZIP missing: $DB_UPGRADE_BASE_ZIP"
    fi

    run_cmd "unzip -oq \"$DB_UPGRADE_BASE_ZIP\" -d \"$DB_UPGRADE_NEW_HOME\""

    local db_log="${DB_UPGRADE_LOG_DIR}/db_23ai_install_$(date +%F_%H%M%S).log"
    if [[ "$DRYRUN" == true ]]; then
        add_html_row "DB Upgrade Install (dry-run)" "INFO" \
            "Would run: $DB_UPGRADE_NEW_HOME/runInstaller -silent -responseFile $DB_RSP (23ai rsp) ..."
    else
        sudo -u "$ORACLE_USER" bash -c "\"$DB_UPGRADE_NEW_HOME/runInstaller\" -silent -ignorePrereqFailure -responseFile \"$DB_RSP\" -waitForCompletion" \
            &> "$db_log"
        add_attachment "$db_log"
        if grep -q "Successfully Setup Software" "$db_log" 2>/dev/null; then
            add_html_row "DB 23/26ai Software Install" "PASS" \
                "Successfully Setup Software. See $db_log"
        else
            add_html_row "DB 23/26ai Software Install" "FAIL" "See $db_log"
        fi
    fi

    send_html_report "DB Upgrade Install (23/26ai) - $HOST" "DB Upgrade Install"
}
db_upgrade_upgrade_core() {
    local db="$1"
    reset_html_report
    LOG_FILE="${DB_UPGRADE_LOG_DIR}/db_upgrade_deploy_${db}_$(date +%F_%H%M%S).log"
    log "DB UPGRADE DEPLOY (AutoUpgrade DEPLOY) for $db"

    local logdir
    logdir=$(write_db_autoupgrade_cfg "$db")

    add_html_row "DB Upgrade" "INFO" \
        "Running AutoUpgrade DEPLOY for DB=${db}, source_home=${DB_UPGRADE_OLD_HOME}, target_home=${DB_UPGRADE_NEW_HOME}"
    add_html_row "AutoUpgrade config" "INFO" "$DB_UPGRADE_CONFIG"

    if [[ ! -f "$DB_UPGRADE_JAR" ]]; then
        add_html_row "AutoUpgrade JAR" "FAIL" "autoupgrade.jar not found at $DB_UPGRADE_JAR."
        send_html_report "DB Upgrade DEPLOY FAILED - $db - $HOST" "DB Upgrade DEPLOY"
        return 0
    fi

    local au_log="${DB_UPGRADE_LOG_DIR}/autoupgrade_deploy_${db}_$(date +%F_%H%M%S).log"

    if [[ "$DRYRUN" == true ]]; then
        add_html_row "AutoUpgrade DEPLOY" "INFO" \
            "DRYRUN ? would run: java -jar $DB_UPGRADE_JAR -config $DB_UPGRADE_CONFIG -mode deploy"
    else
        run_cmd "java -jar \"$DB_UPGRADE_JAR\" -config \"$DB_UPGRADE_CONFIG\" -mode deploy > \"$au_log\" 2>&1 || true"
        add_attachment "$au_log"
    fi

    local html_report=""
    if [[ -d "$logdir" ]]; then
        html_report=$(find "$logdir" -type f -name '*html' 2>/dev/null | head -n1 || true)
    fi
    if [[ -n "$html_report" && -f "$html_report" ]]; then
        add_attachment "$html_report"
        add_html_row "AutoUpgrade DEPLOY HTML" "INFO" \
            "Upgrade HTML report attached: $(basename "$html_report")"
    fi

    send_html_report "DB Upgrade DEPLOY - $db - $HOST" "DB Upgrade DEPLOY"
}

db_upgrade_upgrade() {
    prompt_for_db_unique
    db_upgrade_upgrade_core "$DB_UNIQUE_NAME"
}
db_upgrade_rollback() {
    reset_html_report
    LOG_FILE="${DB_UPGRADE_LOG_DIR}/db_upgrade_rollback_$(date +%F_%H%M%S).log"
    log "DB UPGRADE ROLLBACK (placeholder)"

    prompt_for_db_unique
    local db="$DB_UNIQUE_NAME"

    add_html_row "DB Upgrade Rollback" "WARN" \
        "Rollback for AutoUpgrade is environment-specific. Implement your chosen AutoUpgrade rollback or manual restore here."
    add_html_row "DB" "INFO" "$db"

    send_html_report "DB Upgrade Rollback (placeholder) - $db - $HOST" "DB Upgrade Rollback"
}
# ------------------------------------------------------------
# NEW: LOCAL DB STOPPER (POSTGRES + ORACLE) FOR CLUSTER MAINTENANCE
# ------------------------------------------------------------
cluster_stop_local_dbs() {
    local phase_label="${1:-Cluster maintenance}"
    local dbstopped="false"

    # Reset the tracking array for this maintenance run
    GI_UPGRADE_STOPPED_DBS=()

    add_html_row "${phase_label} - DB stop" "INFO" \
        "Attempting to detect and gracefully stop local databases (PostgreSQL / Oracle)."

    # ----------------- PostgreSQL first ----------------------
    local DB_SERVICE
    DB_SERVICE=$(systemctl list-unit-files 2>/dev/null | grep -E '^postgresql(-[0-9]+)?\.service' | awk '{print $1}' | head -n1 || true)
    if [[ -n "${DB_SERVICE:-}" ]]; then
        add_html_row "PostgreSQL detection" "INFO" \
            "PostgreSQL service detected: <code>${DB_SERVICE}</code>"
        if systemctl is-active --quiet "$DB_SERVICE"; then
            add_html_row "PostgreSQL status" "INFO" "Service is active; attempting graceful stop."
            if [[ "$DRYRUN" == true ]]; then
                log "[DRYRUN] Would run: systemctl stop $DB_SERVICE"
                add_html_row "PostgreSQL stop (dry-run)" "INFO" \
                    "DRYRUN – PostgreSQL stop skipped."
            else
                systemctl stop "$DB_SERVICE"
                sleep 3
                if systemctl is-active --quiet "$DB_SERVICE"; then
                    add_html_row "PostgreSQL stop" "FAIL" \
                        "Service ${DB_SERVICE} is still active after stop attempt."
                    dbstopped="false"
                else
                    add_html_row "PostgreSQL stop" "PASS" \
                        "Successfully stopped PostgreSQL service ${DB_SERVICE}."
                    dbstopped="true"
                fi
            fi
        else
            add_html_row "PostgreSQL status" "INFO" \
                "PostgreSQL installed but not running; shutdown skipped."
            dbstopped="skipped"
        fi
        log_to_state_file "DBTYPE=postgresql"
        log_to_state_file "DB_SERVICE=${DB_SERVICE}"
        log_to_state_file "dbstopped=${dbstopped}"
        return 0
    fi

    # ----------------- Oracle detection ----------------------
    if pgrep -f "ora_pmon_" >/dev/null 2>&1 || pgrep -f "asm_pmon_" >/dev/null 2>&1; then
        add_html_row "Oracle detection" "INFO" \
            "Oracle processes detected (ora_pmon_ / asm_pmon_ present)."
        log_to_state_file "DBTYPE=oracle"
    else
        add_html_row "Local DB detection" "INFO" \
            "No supported database processes detected; DB shutdown skipped."
        log_to_state_file "dbstopped=NA"
        return 0
    fi

    # ----------------- Oracle via srvctl if possible ---------
    local GI_ORACLE_HOME=""
    local ORACLE_BASE_HOME_CANDIDATES=(
        "$OLD_GI_HOME"
        "$NEW_GI_HOME"
        /grid/oracle/product/*
        /u01/app/grid/*
        /app/oracle/product/*
        /opt/oracle/*
    )
    for d in "${ORACLE_BASE_HOME_CANDIDATES[@]}"; do
        [[ -x "$d/bin/srvctl" ]] && { GI_ORACLE_HOME="$d"; break; }
    done

    log "DEBUG: cluster_stop_local_dbs: GI_ORACLE_HOME='$GI_ORACLE_HOME', SRVCTL_BIN='$SRVCTL_BIN'"

    local used_srvctl=false
    if [[ -n "$GI_ORACLE_HOME" && -x "$GI_ORACLE_HOME/bin/srvctl" ]]; then
        local DB_LIST
        DB_LIST=$(sudo -u "$ORACLE_USER" "$GI_ORACLE_HOME/bin/srvctl" config database 2>/dev/null | awk '{print $1}' | sort -u || true)
        log "DEBUG: cluster_stop_local_dbs: srvctl DB_LIST='$DB_LIST'"
        if [[ -n "$DB_LIST" ]]; then
            add_html_row "Oracle srvctl home" "INFO" \
                "Using srvctl from <code>${GI_ORACLE_HOME}</code> to stop DBs/ASM."
            local db
            for db in $DB_LIST; do
                if [[ "$DRYRUN" == true ]]; then
                    log "[DRYRUN] Would run: srvctl stop database -d $db -o immediate"
                    add_html_row "Oracle DB stop (srvctl, dry-run)" "INFO" \
                        "DRYRUN – would stop database <code>$db</code> via srvctl."
                else
                    add_html_row "Oracle DB stop (srvctl)" "INFO" \
                        "Stopping database <code>$db</code> via srvctl."
                    if sudo -u "$ORACLE_USER" "$GI_ORACLE_HOME/bin/srvctl" stop database -d "$db" -o immediate; then
                        add_html_row "Oracle DB stop (srvctl)" "PASS" \
                            "Database <code>$db</code> stopped via srvctl."
                        dbstopped="true"
                        log_to_state_file "dbstopped=${db}"
                    else
                        add_html_row "Oracle DB stop (srvctl)" "FAIL" \
                            "Failed to stop database <code>$db</code> via srvctl."
                        dbstopped="false"
                        log_to_state_file "dbstopped=false"
                    fi
                fi
            done
            used_srvctl=true

            # ASM via srvctl
            if "$GI_ORACLE_HOME/bin/srvctl" config asm >/dev/null 2>&1; then
                if [[ "$DRYRUN" == true ]]; then
                    log "[DRYRUN] Would run: srvctl stop asm -f"
                    add_html_row "ASM stop (srvctl, dry-run)" "INFO" \
                        "DRYRUN – would stop ASM via srvctl."
                else
                    add_html_row "ASM stop (srvctl)" "INFO" \
                        "Stopping ASM via srvctl."
                    if sudo -u "$ORACLE_USER" "$GI_ORACLE_HOME/bin/srvctl" stop asm -f; then
                        add_html_row "ASM stop (srvctl)" "PASS" \
                            "ASM stopped via srvctl."
                        log_to_state_file "asmstopped=srvctl"
                    else
                        add_html_row "ASM stop (srvctl)" "FAIL" \
                            "Failed to stop ASM via srvctl."
                        log_to_state_file "asmstopped=failed"
                    fi
                fi
            else
                add_html_row "ASM srvctl config" "INFO" \
                    "ASM not configured under srvctl; skipping srvctl ASM stop."
            fi
        else
            log "DEBUG: cluster_stop_local_dbs: srvctl present but no databases configured in $GI_ORACLE_HOME"
        fi
    fi

    # If srvctl didn't stop anything, fallback to PMON/sqlplus
    if [[ "$used_srvctl" != true ]]; then
        add_html_row "Oracle srvctl" "WARN" \
            "srvctl either not found or no databases configured – falling back to PMON/sqlplus stop for DBs and ASM."

        local PMON ORA_SID
        for PMON in $(ps -ef | grep -E 'ora_pmon_' | grep -v grep | awk '{print $8}'); do
            ORA_SID=${PMON#ora_pmon_}
            if [[ "$DRYRUN" == true ]]; then
                log "[DRYRUN] Would shutdown immediate SID=$ORA_SID via sqlplus."
                add_html_row "Oracle DB stop (PMON, dry-run)" "INFO" \
                    "DRYRUN – would stop instance <code>$ORA_SID</code> via sqlplus."
                continue
            fi
            log "Stopping Oracle instance: $ORA_SID"
            sudo -u "$ORACLE_USER" bash -c "
                export ORACLE_SID=$ORA_SID
                export ORACLE_HOME=\$(grep -m1 \"^$ORA_SID:\" /etc/oratab | cut -d: -f2)
                PATH=\$ORACLE_HOME/bin:\$PATH
                sqlplus -s / as sysdba <<EOF
shutdown immediate;
exit;
EOF
            " >/dev/null 2>&1
            if ps -ef | grep -E "ora_pmon_$ORA_SID" | grep -v grep >/dev/null; then
                add_html_row "Oracle DB stop (PMON)" "FAIL" \
                    "Instance <code>$ORA_SID</code> still appears to be running after shutdown attempt."
                dbstopped="false"
                log_to_state_file "dbstopped=false"
            else
                add_html_row "Oracle DB stop (PMON)" "PASS" \
                    "Instance <code>$ORA_SID</code> stopped via sqlplus."
                dbstopped="true"
                log_to_state_file "dbstopped=${ORA_SID}"
            fi
        done

        local ASM_SID
        for PMON in $(ps -ef | grep -E 'asm_pmon_' | grep -v grep | awk '{print $8}'); do
            ASM_SID=${PMON#asm_pmon_}
            if [[ "$DRYRUN" == true ]]; then
                log "[DRYRUN] Would shutdown immediate ASM SID=$ASM_SID via sqlplus as sysasm."
                add_html_row "ASM stop (PMON, dry-run)" "INFO" \
                    "DRYRUN – would stop ASM instance <code>$ASM_SID</code> via sqlplus."
                continue
            fi
            log "Stopping ASM instance: $ASM_SID"
            sudo -u "$ORACLE_USER" bash -c "
                export ORACLE_SID=$ASM_SID
                export ORACLE_HOME=\$(grep -m1 \"^$ASM_SID:\" /etc/oratab | cut -d: -f2)
                PATH=\$ORACLE_HOME/bin:\$PATH
                sqlplus -s / as sysasm <<EOF
shutdown immediate;
exit;
EOF
            " >/dev/null 2>&1
            if ps -ef | grep -E "asm_pmon_$ASM_SID" | grep -v grep >/dev/null; then
                add_html_row "ASM stop (PMON)" "FAIL" \
                    "ASM instance <code>$ASM_SID</code> still appears to be running after shutdown attempt."
                log_to_state_file "asmstopped=false"
            else
                add_html_row "ASM stop (PMON)" "PASS" \
                    "ASM instance <code>$ASM_SID</code> stopped via sqlplus."
                log_to_state_file "asmstopped=${ASM_SID}"
            fi
        done
    fi
}

# ------------------------------------------------------------
# CLUSTER MAINTENANCE PHASES (Per-node, MEC-friendly)
# ------------------------------------------------------------
os_repo_snapshot_html() {
    local phase_log_dir
    phase_log_dir="$(current_phase_log_dir)"
    local repo_log="${phase_log_dir}/os_repo_snapshot_$(date +%F_%H%M%S).log"

    {
        echo "==== /etc/os-release ===="
        cat /etc/os-release 2>/dev/null || echo "N/A"
        echo

        if command -v dnf >/dev/null 2>&1; then
            echo "==== dnf repolist all ===="
            dnf repolist all 2>&1 || echo "dnf repolist all failed"
            echo
        elif command -v yum >/dev/null 2>&1; then
            echo "==== yum repolist all ===="
            yum repolist all 2>&1 || echo "yum repolist all failed"
            echo
        elif command -v apt-cache >/dev/null 2>&1; then
            echo "==== apt-cache policy ===="
            apt-cache policy 2>&1 || echo "apt-cache policy failed"
            echo
        else
            echo "No known package manager (dnf/yum/apt) detected; repo snapshot limited to /etc/os-release."
        fi

        echo "==== Current running kernel ===="
        uname -a 2>&1
        echo

        if command -v rpm >/dev/null 2>&1; then
            echo "==== Installed kernel packages (rpm) ===="
            rpm -qa | grep -Ei 'kernel(|-core|-uek)' | sort || true
            echo
        elif command -v dpkg-query >/dev/null 2>&1; then
            echo "==== Installed kernel packages (dpkg-query) ===="
            dpkg-query -W 'linux-image*' 2>/dev/null | sort || true
            echo
        fi
    } > "$repo_log"

    add_attachment "$repo_log"
    log_file_content "$repo_log" "OS: repo & kernel snapshot"
    add_html_row "OS precheck - repo & kernel snapshot" "INFO" "Captured OS release, repo list and kernel packages. See $(basename "$repo_log")."
}
is_valid_cluster_db_name() {
    local db="$1"
    [[ -z "$db" ]] && return 1
    case "$db" in
        +ASM*|PRCR-*|CRS-*|PRCD-*|PRKH-*|ORA-*|TNS-*|Usage:*|ERROR:*|Warning:*|"ORACLE_HOME environment variable is not set") return 1 ;;
    esac
    [[ "$db" =~ ^[A-Za-z0-9_.$#-]+$ ]]
}

cluster_local_pmon_sids() {
    ps -eo args 2>/dev/null | awk -Fpmon_ '/pmon_/ {print $2}' | sed 's/ .*$//' | sort -u || true
}

cluster_get_db_home_for_sid() {
    local sid="$1"
    local home=""
    home=$(get_home_from_pmon_sid "$sid")
    if [[ -z "$home" ]]; then
        log "DEBUG: get_home_from_pmon_sid('$sid') returned empty — trying /proc/pid/exe path"
        local pids
        pids=$(pgrep -f "pmon_${sid}" 2>/dev/null || true)
        if [[ -z "$pids" ]]; then
            log "DEBUG: pgrep found no processes matching pmon_${sid}"
        else
            log "DEBUG: pgrep found pids: $(echo "$pids" | tr '\n' ' ')"
        fi
    fi
    if [[ -z "$home" && -n "${OLD_DB_HOME:-}" && -d "${OLD_DB_HOME}" ]]; then
        log "DEBUG: falling back to OLD_DB_HOME='$OLD_DB_HOME' for sid=$sid"
        home="$OLD_DB_HOME"
    fi
    printf '%s' "$home"
}

_add_sid_mapping_cluster() {
    local sid="$1"
    local guessed_db=""

    if [[ "$sid" =~ ^(.+)_([0-9]+)$ ]]; then
        guessed_db="${BASH_REMATCH[1]}"
    fi

    DB_NAME_TO_SID_MAP+="${DB_NAME_TO_SID_MAP:+ }${sid}=${sid}"

    if [[ -n "$guessed_db" ]]; then
        DB_NAME_TO_SID_MAP+="${DB_NAME_TO_SID_MAP:+ }${guessed_db}=${sid}"
    fi
}

discover_databases_for_cluster() {
    DB_UNIQUES=()
    DB_NAME_TO_SID_MAP=""

    local sids sid home db_name raw already existing existing2

    # ---- Step 1: inventory the environment ----
    log "DEBUG: discover_databases_for_cluster: starting discovery on host $(hostname)"
    log "DEBUG: ORACLE_USER=${ORACLE_USER:-<unset>}  OLD_DB_HOME=${OLD_DB_HOME:-<unset>}"

    # Log /etc/oratab contents so we can see what the script sees
    if [[ -f "${ORATAB_FILE:-/etc/oratab}" ]]; then
        log "DEBUG: ${ORATAB_FILE:-/etc/oratab} contents (non-comment lines):"
        grep -v '^[[:space:]]*#' "${ORATAB_FILE:-/etc/oratab}" | grep -v '^[[:space:]]*$' | while IFS= read -r oratab_line; do
            log "DEBUG:   oratab: $oratab_line"
        done || log "DEBUG:   (no active entries in oratab)"
    else
        log "DEBUG: ${ORATAB_FILE:-/etc/oratab} NOT FOUND"
    fi

    # Log all pmon processes visible to this user
    local raw_pmons
    raw_pmons=$(ps -eo args 2>/dev/null | grep -E 'pmon_' | grep -v grep || true)
    if [[ -n "$raw_pmons" ]]; then
        log "DEBUG: PMON processes found:"
        echo "$raw_pmons" | while IFS= read -r pline; do
            log "DEBUG:   $pline"
        done
    else
        log "DEBUG: No PMON processes visible to current user ($(id -un))"
        log "DEBUG: This is the most common cause of empty DB_UNIQUES"
        log "DEBUG: Check: ps -eo args | grep pmon_ — if processes exist but are invisible,"
        log "DEBUG: the agent may need to run as oracle or oracle sudo access must be granted"
    fi

    # ---- Step 2: PMON-based discovery ----
    sids=$(cluster_local_pmon_sids)
    log "DEBUG: cluster_local_pmon_sids returned: '$(echo "$sids" | tr '\n' ' ' | sed "s/ *$//")'"

    if [[ -n "$sids" ]]; then
        while IFS= read -r sid; do
            [[ -z "$sid" ]] && continue
            if [[ "$sid" == +ASM* || "$sid" == "MGMTDB" ]]; then
                log "DEBUG: skipping non-DB SID: $sid"
                continue
            fi

            home=$(cluster_get_db_home_for_sid "$sid")
            if [[ -z "$home" ]]; then
                log "DEBUG: SID=$sid — could not determine ORACLE_HOME, skipping"
                continue
            fi
            if [[ ! -d "$home" ]]; then
                log "DEBUG: SID=$sid — home='$home' does not exist on disk, skipping"
                continue
            fi
            log "DEBUG: SID=$sid — ORACLE_HOME=$home"

            db_name=""
            if [[ -x "$home/bin/sqlplus" ]]; then
                log "DEBUG: SID=$sid — querying v\$database via sqlplus"
                raw=$(
                    sudo -u "$ORACLE_USER" bash -c "
                        ORACLE_HOME=\"$home\"
                        ORACLE_SID=\"$sid\"
                        PATH=\"$home/bin:\$PATH\"
                        \"$home/bin/sqlplus\" -s / as sysdba 2>&1 <<'EOF'
set heading off feedback off pages 0 verify off echo off termout off
whenever sqlerror exit 1
select name from v\$database;
exit
EOF
                    "
                ) || true

                db_name=$(printf '%s\n' "$raw" | tr -d '\r' | sed '/^[[:space:]]*$/d' | grep -Ev '^(SQL\*Plus|Copyright|(Connected to)|(Disconnected from)|ERROR:|ORA-|SP2-|SP-)[[:space:]]' | sed -n '1p' | xargs)
                log "DEBUG: SID=$sid — sqlplus returned db_name='$db_name'  (raw: $(printf '%s' "$raw" | head -3 | tr '\n' '|'))"
            else
                log "DEBUG: SID=$sid — sqlplus not found at $home/bin/sqlplus, deriving name from SID"
            fi

            if ! is_valid_cluster_db_name "$db_name"; then
                log "DEBUG: SID=$sid — db_name='$db_name' failed validation, deriving from SID"
                if [[ "$sid" =~ ^(.+)_([0-9]+)$ ]]; then
                    db_name="${BASH_REMATCH[1]}"
                else
                    db_name="$sid"
                fi
                log "DEBUG: SID=$sid — derived db_name='$db_name'"
            fi

            if ! is_valid_cluster_db_name "$db_name"; then
                log "INFO: Skipping invalid cluster DB candidate derived from SID '$sid': '$db_name'"
                continue
            fi

            already=false
            for existing in "${DB_UNIQUES[@]}"; do
                [[ "$existing" == "$db_name" ]] && already=true && break
            done
            if [[ "$already" != true ]]; then
                DB_UNIQUES+=( "$db_name" )
                log "DEBUG: added '$db_name' to DB_UNIQUES"
            fi

            _add_sid_mapping_cluster "$sid"
            DB_NAME_TO_SID_MAP+="${DB_NAME_TO_SID_MAP:+ }${db_name}=${sid}"
        done <<< "$sids"
    fi

    # ---- Step 3: oratab fallback — if PMON gave nothing, trust oratab ----
    if [[ ${#DB_UNIQUES[@]} -eq 0 ]]; then
        log "DEBUG: PMON discovery found nothing — trying /etc/oratab fallback"
        if [[ -f "${ORATAB_FILE:-/etc/oratab}" ]]; then
            while IFS=: read -r ot_sid ot_home _rest; do
                [[ "$ot_sid" =~ ^[[:space:]]*# ]] && continue
                [[ -z "$ot_sid" || -z "$ot_home" ]] && continue
                ot_sid=$(printf '%s' "$ot_sid" | xargs)
                ot_home=$(printf '%s' "$ot_home" | xargs)
                [[ "$ot_sid" == "*" || "$ot_sid" == "+ASM"* || "$ot_sid" == "MGMTDB" ]] && continue
                is_valid_cluster_db_name "$ot_sid" || continue
                if [[ -d "$ot_home" ]]; then
                    log "DEBUG: oratab fallback: adding SID=$ot_sid HOME=$ot_home"
                    DB_UNIQUES+=( "$ot_sid" )
                    DB_NAME_TO_SID_MAP+="${DB_NAME_TO_SID_MAP:+ }${ot_sid}=${ot_sid}"
                else
                    log "DEBUG: oratab fallback: SID=$ot_sid home '$ot_home' not on disk, skipping"
                fi
            done < "${ORATAB_FILE:-/etc/oratab}"
        fi
    fi

    # ---- Step 4: srvctl fallback ----
    if [[ ${#DB_UNIQUES[@]} -eq 0 && -n "${SRVCTL_BIN:-}" ]]; then
        log "DEBUG: trying srvctl fallback via $SRVCTL_BIN"
        local gi_home_for_srvctl srvctl_out db
        gi_home_for_srvctl="$(cd "$(dirname "$SRVCTL_BIN")/.." && pwd 2>/dev/null || echo "")"
        if [[ -n "$gi_home_for_srvctl" && -d "$gi_home_for_srvctl" ]]; then
            srvctl_out=$(ORACLE_HOME="$gi_home_for_srvctl" "$SRVCTL_BIN" config database 2>&1 || true)
            log "DEBUG: srvctl config database output: $(printf '%s' "$srvctl_out" | head -5 | tr '\n' '|')"
            while IFS= read -r db; do
                db=$(echo "$db" | xargs)
                is_valid_cluster_db_name "$db" || continue
                already=false
                for existing2 in "${DB_UNIQUES[@]}"; do
                    [[ "$existing2" == "$db" ]] && already=true && break
                done
                [[ "$already" == true ]] && continue
                DB_UNIQUES+=( "$db" )
                DB_NAME_TO_SID_MAP+="${DB_NAME_TO_SID_MAP:+ }${db}=${db}"
            done <<< "$srvctl_out"
        fi
    fi

    log "INFO: discover_databases_for_cluster: final DB_UNIQUES=(${DB_UNIQUES[*]:-<empty>})"
    if [[ ${#DB_UNIQUES[@]} -eq 0 ]]; then
        log "WARN: No databases discovered. Checked: PMON processes, /etc/oratab, srvctl config database."
        log "WARN: If a database is running, verify the agent runs as root or oracle, and /etc/oratab is populated."
    fi
}

package_manager_health_check_html() {
    local phase_log_dir pm_log mgr=""
    phase_log_dir="$(current_phase_log_dir)"
    pm_log="${phase_log_dir}/package_manager_health_$(date +%F_%H%M%S).log"
    local warn=false
    {
        echo "==== package manager health check ===="
        date
        echo
        if command -v dnf >/dev/null 2>&1; then
            mgr="dnf"
        elif command -v yum >/dev/null 2>&1; then
            mgr="yum"
        elif command -v apt-get >/dev/null 2>&1; then
            mgr="apt"
        else
            mgr="unknown"
        fi
        echo "[tool] $mgr"

        if [[ -e /var/lib/rpm/.rpm.lock ]]; then
            echo "WARN: /var/lib/rpm/.rpm.lock present"
            warn=true
        fi
        ps -ef | egrep 'dnf|yum|rpm|apt|dpkg' | grep -v grep || true
        echo
        if command -v dnf >/dev/null 2>&1; then
            dnf history list 2>&1 | head -40 || true
        elif command -v yum >/dev/null 2>&1; then
            yum history list 2>&1 | head -40 || true
        elif command -v apt-get >/dev/null 2>&1; then
            ls -l /var/lib/dpkg/lock* 2>/dev/null || true
        fi
    } > "$pm_log"
    add_attachment "$pm_log"
    log_file_content "$pm_log" "OS: package manager health"
    if [[ "$warn" == true ]]; then
        add_html_row "Package manager health" "WARN" "Potential package manager lock/activity detected. See $(basename "$pm_log")."
    else
        add_html_row "Package manager health" "INFO" "Captured package manager health snapshot. See $(basename "$pm_log")."
    fi
}

cluster_get_open_mode_for_sid() {
    local sid="$1" home="$2" mode="UNKNOWN"
    [[ -z "$sid" || -z "$home" || ! -x "$home/bin/sqlplus" ]] && { printf '%s' "$mode"; return; }
    mode=$(sudo -u "$ORACLE_USER" bash -c "ORACLE_HOME="$home" ORACLE_SID="$sid" PATH="$home/bin:\$PATH" "$home/bin/sqlplus" -s / as sysdba <<'EOF'
set heading off feedback off pages 0 verify off echo off termout off
select open_mode from v\$database;
exit
EOF" 2>/dev/null | tr -d '
' | sed '/^[[:space:]]*$/d' | sed -n '1p' | xargs) || true
    [[ -z "$mode" ]] && mode="UNKNOWN"
    printf '%s' "$mode"
}

cluster_get_role_for_sid() {
    local sid="$1" home="$2" role="UNKNOWN"
    [[ -z "$sid" || -z "$home" || ! -x "$home/bin/sqlplus" ]] && { printf '%s' "$role"; return; }
    role=$(sudo -u "$ORACLE_USER" bash -c "ORACLE_HOME="$home" ORACLE_SID="$sid" PATH="$home/bin:\$PATH" "$home/bin/sqlplus" -s / as sysdba <<'EOF'
set heading off feedback off pages 0 verify off echo off termout off
select database_role from v\$database;
exit
EOF" 2>/dev/null | tr -d '
' | sed '/^[[:space:]]*$/d' | sed -n '1p' | xargs) || true
    [[ -z "$role" ]] && role="UNKNOWN"
    printf '%s' "$role"
}

report_reboot_required_html() {
    local running defaultk required="NO"
    running=$(uname -r 2>/dev/null || echo unknown)
    defaultk=$(command -v grubby >/dev/null 2>&1 && grubby --default-kernel 2>/dev/null || echo unknown)
    if [[ -f /var/run/reboot-required || -f /run/reboot-required ]]; then
        required="YES"
    fi
    if [[ "$defaultk" != "unknown" && "$defaultk" != *"$running"* ]]; then
        required="YES"
    fi
    add_html_row "Reboot required" "INFO" "Running kernel: <code>${running}</code><br/>Default boot kernel: <code>${defaultk}</code><br/>Reboot required: <b>${required}</b>"
}

cluster_precheck() {
    reset_html_report
    LOG_FILE="${CLUSTER_LOG_DIR}/cluster_precheck_$(date +%F_%H%M%S).log"
    log "CLUSTER PRECHECK (OS + DB snapshot)"

    add_attachment "$LOG_FILE"
    local role
    role=$(get_node_role)
    add_html_row "Node role" "INFO" "Role from /etc/oracle-node-role: <code>${role}</code>"

    os_precheck_html || log "WARN: os_precheck_html returned non-zero (continuing)."
    os_repo_snapshot_html || log "WARN: os_repo_snapshot_html returned non-zero (continuing)."
    package_manager_health_check_html || log "WARN: package_manager_health_check_html returned non-zero (continuing)."

    check_mount_if_present_html "/app"  30 || log "WARN: check_mount_if_present_html(/app) non-zero."
    check_mount_if_present_html "/grid" 20 || log "WARN: check_mount_if_present_html(/grid) non-zero."
    check_mount_if_present_html "/boot" 5  || log "WARN: check_mount_if_present_html(/boot) non-zero."
    check_mount_if_present_html "/boot/efi" 1 || log "WARN: check_mount_if_present_html(/boot/efi) non-zero."

    init_srvctl || log "WARN: init_srvctl returned non-zero (continuing)."
    discover_databases_for_cluster || log "WARN: discover_databases_for_cluster returned non-zero (continuing)."
    log "INFO: discover_databases_for_cluster: final DB_UNIQUES=(${DB_UNIQUES[*]:-})"

    if [[ ${#DB_UNIQUES[@]} -gt 0 ]]; then
        local summary=""
        local db sid home running_here sid_list open_mode db_role p_sids role_mode_parts

        p_sids=$(cluster_local_pmon_sids)

        for db in "${DB_UNIQUES[@]}"; do
            home=""
            running_here="NO"
            sid_list=""
            open_mode="UNKNOWN"
            db_role="UNKNOWN"
            role_mode_parts=""

            while IFS= read -r sid; do
                [[ -z "$sid" ]] && continue

                if [[ -z "$home" ]]; then
                    home=$(cluster_get_db_home_for_sid "$sid")
                fi

                if echo "$p_sids" | grep -qx "$sid" 2>/dev/null; then
                    running_here="YES (PMON)"
                    sid_list+="${sid_list:+, }$sid"

                    local sid_home sid_role sid_mode
                    sid_home=$(cluster_get_db_home_for_sid "$sid")
                    [[ -z "$sid_home" ]] && sid_home="$home"
                    sid_role=$(cluster_get_role_for_sid "$sid" "$sid_home")
                    sid_mode=$(cluster_get_open_mode_for_sid "$sid" "$sid_home")
                    role_mode_parts+="${role_mode_parts:+; }${sid}: ${sid_role}/${sid_mode}"

                    if [[ "$db_role" == "UNKNOWN" && "$sid_role" != "UNKNOWN" ]]; then
                        db_role="$sid_role"
                    fi
                    if [[ "$open_mode" == "UNKNOWN" && "$sid_mode" != "UNKNOWN" ]]; then
                        open_mode="$sid_mode"
                    fi
                fi
            done <<< "$(cluster_get_sids_for_db_name "$db")"

            [[ -z "$home" ]] && home="${OLD_DB_HOME:-UNKNOWN}"

            summary+="<b>${db}</b> (home: ${home:-UNKNOWN}, running_here: ${running_here}"
            if [[ -n "$sid_list" ]]; then
                summary+=", SID(s): ${sid_list}"
                if [[ -n "$role_mode_parts" ]]; then
                    summary+=", details: ${role_mode_parts}"
                else
                    summary+=", role: ${db_role}, open_mode: ${open_mode}"
                fi
            fi
            summary+=")<br/>"
        done

        add_html_row "Local databases (pre-maintenance)" "INFO" "$summary"
        echo "Cluster precheck DB summary on $(hostname -s):"
        plain_summary=$(printf '%s\n' "$summary" | perl -0pe 's|<br/>|\n|g; s|<[^>]*>||g')
        printf '%s\n' "$plain_summary"
    else
        add_html_row "Local databases (pre-maintenance)" "INFO" "No PMON-detected databases on this node at precheck time."
        echo "Cluster precheck: no local databases detected on $(hostname -s)."
    fi

    report_reboot_required_html

    log "DEBUG: cluster_precheck: about to send_html_report"
    set +e
    send_html_report "Cluster Precheck - $HOST" "Cluster Precheck"
    local rc_send=$?
    set -e
    log "DEBUG: cluster_precheck: send_html_report returned rc=${rc_send}"

    if (( rc_send != 0 )); then
        log "WARN: send_html_report for Cluster Precheck returned non-zero (${rc_send}); email/report may have failed."
    fi

    log "DEBUG: cluster_precheck: completed successfully"
}

cluster_stop_dbs() {
    reset_html_report
    LOG_FILE="${CLUSTER_LOG_DIR}/cluster_stop_dbs_$(date +%F_%H%M%S).log"
    STATE_FILE="${CLUSTER_LOG_DIR}/cluster_state_$(date +%F_%H%M%S).txt"
    CLUSTER_STOPPED_DBS_FILE="${CLUSTER_LOG_DIR}/cluster_stopped_dbs.list"
    : > "$CLUSTER_STOPPED_DBS_FILE"    # truncate for this run

    log "CLUSTER MAINTENANCE - STOP DBS (LOCAL NODE)"

    init_srvctl
    cluster_stop_local_dbs "Cluster maintenance"
    send_html_report "Cluster DB Stop - $HOST" "Cluster DB Stop"
}

enable_and_patch_kernel_html() {
    local phase_log_dir
    phase_log_dir="$(current_phase_log_dir)"
    local klog="${phase_log_dir}/kernel_update_$(date +%F_%H%M%S).log"
    local os_id="" os_version_id="" PKG_MGR=""

    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        os_id="${ID:-}"
        os_version_id="${VERSION_ID:-}"
    fi

    {
        echo "==== /etc/os-release ===="
        cat /etc/os-release 2>/dev/null || echo "N/A"
        echo
        echo "Detected ID=${os_id}, VERSION_ID=${os_version_id}"
        echo

        if [[ "$os_id" == "ol" || "$os_id" == "oraclelinux" ]]; then
            if command -v dnf >/dev/null 2>&1; then
                PKG_MGR="dnf"
            elif command -v yum >/dev/null 2>&1; then
                PKG_MGR="yum"
            else
                echo "WARN: No dnf/yum found; cannot manage UEK repos."
                return 0
            fi

            local major
            major="${os_version_id%%.*}"
            echo "==== Detecting UEK repositories dynamically for OL${major} ===="
            local UEK_REPOS
            UEK_REPOS=$(timeout 60 $PKG_MGR repolist all 2>/dev/null |                 awk '{print $1}' | grep -E "^ol${major}.*[Uu][Ee][Kk][Rr]" | sort -u)

            if [[ -z "$UEK_REPOS" ]]; then
                echo "WARN: No UEK repos detected."
            else
                echo "$UEK_REPOS"
            fi
            echo

            local LATEST_UEK repo rc_install=0
            LATEST_UEK=$(echo "$UEK_REPOS" | tr '[:upper:]' '[:lower:]' | grep -oE 'uekr[0-9]+' | sort -V | tail -1)
            if [[ -n "$LATEST_UEK" ]]; then
                echo "Latest UEK detected: $LATEST_UEK"
                for repo in $UEK_REPOS; do
                    if [[ "$(echo "$repo" | tr '[:upper:]' '[:lower:]')" == *"$LATEST_UEK"* ]]; then
                        $PKG_MGR config-manager --enable "$repo" 2>&1 || echo "WARN: failed to enable $repo"
                    fi
                done
            fi
            echo "==== Installing / Updating latest kernel-uek via $PKG_MGR ===="
            timeout "${KERNEL_PATCH_TIMEOUT:-3600}" $PKG_MGR -y install kernel-uek --nobest 2>&1 || rc_install=$?
            if (( rc_install != 0 )); then
                echo "WARN: kernel-uek install/update returned RC=${rc_install}"
            fi
            echo
            echo "==== Installed kernel packages (rpm) ===="
            rpm -qa | grep -Ei 'kernel(|-core|-uek)' | sort || true
            echo
            echo "==== Current running kernel (uname -r) ===="
            uname -r
            echo
            echo "==== Default boot kernel (grubby) ===="
            if command -v grubby >/dev/null 2>&1; then
                grubby --default-kernel 2>&1 || echo "WARN: grubby returned non-zero."
            else
                echo "grubby not installed"
            fi
            echo
        else
            echo "Non-Oracle Linux system detected (ID=${os_id}); UEK-specific handling skipped."
            uname -a
            echo
        fi
    } > "$klog"

    add_attachment "$klog"
    local running_kernel default_kernel
    running_kernel=$(uname -r 2>/dev/null || echo unknown)
    default_kernel=$(command -v grubby >/dev/null 2>&1 && grubby --default-kernel 2>/dev/null || echo unknown)
    add_html_row "Kernel UEK update (dynamic)" "INFO" "Dynamic UEK repo detection + latest kernel-uek install/upgrade executed.<br/>Running kernel: <code>${running_kernel}</code><br/>Default boot kernel: <code>${default_kernel}</code><br/>See $(basename "$klog")."
}

cluster_os_patch() {
    reset_html_report
    LOG_FILE="${CLUSTER_LOG_DIR}/cluster_os_patch_$(date +%F_%H%M%S).log"
    log "CLUSTER MAINTENANCE - OS PATCH (LOCAL NODE)"

    add_attachment "$LOG_FILE"
    package_manager_health_check_html || log "WARN: package_manager_health_check_html returned non-zero (continuing)."
    enable_and_patch_kernel_html
    os_patch_html
    report_reboot_required_html

    send_html_report "Cluster OS Patch - $HOST" "Cluster OS Patch"
}


start_cluster_reboot_watchdog() {
    local timeout_secs="${CLUSTER_REBOOT_WATCHDOG_TIMEOUT:-900}"
    local watchdog_dir="/var/lib/insight-maint"
    local watchdog_script="${watchdog_dir}/cluster_reboot_watchdog.sh"

    mkdir -p "$watchdog_dir"

    cat > "$watchdog_script" <<EOF
#!/usr/bin/env bash
sleep ${timeout_secs}
logger -t cluster-reboot-watchdog "Cluster reboot watchdog triggered after ${timeout_secs}s; forcing reboot"
sync
systemctl --force --force reboot || /sbin/reboot -f || /usr/sbin/reboot -f || echo b > /proc/sysrq-trigger
EOF
    chmod 700 "$watchdog_script"

    nohup bash "$watchdog_script" >/dev/null 2>&1 &
    log "Started cluster reboot watchdog with ${timeout_secs}s fallback."
}

schedule_postreboot_startup_and_cluster_phase() {
    local wrapper="/var/lib/insight-maint/cluster_postreboot_wrapper.sh"
    local unit="/etc/systemd/system/cluster-postreboot.service"
    mkdir -p /var/lib/insight-maint

    cat > "$wrapper" <<EOF
#!/usr/bin/env bash
set -e
if [[ -x /etc/patching/startup.sh ]]; then
    /etc/patching/startup.sh || echo "WARN: insight_startup-osgidb.sh failed (non-zero exit code)" >&2
else
    echo "INFO: /home/oracle/insight_startup-osgidb.sh not found; skipping." >&2
fi
INSIGHT_SUPPRESS_MAIL=1 "$SCRIPT_PATH" cluster_postreboot_db || echo "WARN: cluster_postreboot_db failed (non-zero RC)" >&2
EOF
    chmod 700 "$wrapper"

    cat > "$unit" <<EOF
[Unit]
Description=Cluster post-reboot startup wrapper
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$wrapper
RemainAfterExit=no
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable cluster-postreboot.service >/dev/null 2>&1 || true

    log "Enabled systemd unit cluster-postreboot.service for post-reboot startup."
    add_html_row "Post-reboot scheduling" "INFO" "Enabled <code>cluster-postreboot.service</code> to run insight startup and cluster_postreboot_db after reboot."
}

cluster_reboot() {
    reset_html_report
    LOG_FILE="${CLUSTER_LOG_DIR}/cluster_reboot_$(date +%F_%H%M%S).log"
    log "CLUSTER MAINTENANCE - REBOOT (LOCAL NODE)"

    local role
    role=$(get_node_role)
    add_html_row "Node role" "INFO" "Role from /etc/oracle-node-role: <code>${role}</code>"

    if [[ -x /etc/patching/shutdown.sh ]]; then
        add_html_row "Insight shutdown + reboot" "INFO" \
            "Executing INSIGHT_NO_BG=1 INSIGHT_REBOOT=1 INSIGHT_NODE_ROLE=${role} /home/oracle/insight_shutdown-osgidb.sh. This script will perform shutdown and schedule reboot/startup according to node role (DB vs APP)."

        if [[ "$DRYRUN" == true ]]; then
            log "[DRYRUN] Would run: INSIGHT_NO_BG=1 INSIGHT_REBOOT=1 INSIGHT_NODE_ROLE=${role} /home/oracle/insight_shutdown-osgidb.sh"
        else
            start_cluster_reboot_watchdog
            add_html_row "Reboot watchdog" "INFO" \
                "Started force-reboot watchdog with timeout <code>${CLUSTER_REBOOT_WATCHDOG_TIMEOUT:-900}s</code> in case graceful reboot hangs."
            INSIGHT_NO_BG=1 INSIGHT_REBOOT=1 INSIGHT_NODE_ROLE="${role}" /etc/patching/shutdown.sh >>"$LOG_FILE" 2>&1 || \
                add_html_row "Insight shutdown + reboot" "WARN" \
                    "insight_shutdown-osgidb.sh returned non-zero; check $(basename "$LOG_FILE"). Reboot may or may not have been scheduled."
        fi
    else
        add_html_row "Insight shutdown + reboot" "WARN" \
            "/etc/patching/shutdown.sh not found or not executable; no shutdown or reboot scheduled by orchestrator."
    fi

    add_html_row "Orchestrator reboot scheduling" "INFO" \
        "Reboot timing delegated to Insight shutdown script based on INSIGHT_NODE_ROLE (DB: immediate, APP: delayed). Orchestrator itself does not call shutdown."

    add_attachment "$LOG_FILE"
    send_html_report "Cluster Reboot - $HOST" "Cluster Reboot"
}

cluster_postreboot_db() {
    reset_html_report
    LOG_FILE="${CLUSTER_LOG_DIR}/cluster_postreboot_db_$(date +%F_%H%M%S).log"
    log "CLUSTER MAINTENANCE - POST-REBOOT VALIDATION (LOCAL NODE)"

    add_html_row "Post-reboot phase" "INFO" \
        "Validation-only post-reboot phase. Startup is expected to be handled by <code>/home/oracle/insight_startup-osgidb.sh</code> before this step in the normal wrapper path."

    if [[ -f /var/log/insight_startup.log ]]; then
        add_attachment "/var/log/insight_startup.log"
        local startup_marker
        startup_marker=$(grep 'STARTUP_SCRIPT_COMPLETED_' /var/log/insight_startup.log | tail -n1 || true)
        if [[ -n "$startup_marker" ]]; then
            add_html_row "Startup completion marker" "INFO" "<code>${startup_marker}</code>"
        else
            add_html_row "Startup completion marker" "WARN" \
                "No final STARTUP_SCRIPT_COMPLETED_* marker found yet in <code>/var/log/insight_startup.log</code>."
        fi
    else
        add_html_row "Startup log" "WARN" \
            "<code>/var/log/insight_startup.log</code> not found at post-reboot validation time."
    fi

    local wait_secs=180
    local interval=5
    local elapsed=0
    local pmon_ok=false

    while (( elapsed < wait_secs )); do
        if ps -ef | grep -q '[o]ra_pmon_'; then
            pmon_ok=true
            break
        fi
        sleep "$interval"
        elapsed=$(( elapsed + interval ))
    done

    if [[ "$pmon_ok" == true ]]; then
        add_html_row "Post-reboot DB PMON check" "PASS" \
            "At least one Oracle PMON (ora_pmon_*) detected within ~${elapsed}s after startup."
    else
        add_html_row "Post-reboot DB PMON check" "WARN" \
            "No Oracle PMON (ora_pmon_*) detected within ${wait_secs}s after startup. ASM may be up but DB instances were not started by the startup flow."
    fi

    init_srvctl || log "WARN: init_srvctl returned non-zero (continuing)."
    discover_databases_for_cluster || log "WARN: discover_databases_for_cluster returned non-zero (continuing)."

    if [[ ${#DB_UNIQUES[@]} -gt 0 ]]; then
        local summary=""
        local db sid home running_here sid_list open_mode db_role p_sids role_mode_parts

        p_sids=$(cluster_local_pmon_sids)

        for db in "${DB_UNIQUES[@]}"; do
            home=""
            running_here="NO"
            sid_list=""
            open_mode="UNKNOWN"
            db_role="UNKNOWN"
            role_mode_parts=""

            while IFS= read -r sid; do
                [[ -z "$sid" ]] && continue

                if [[ -z "$home" ]]; then
                    home=$(cluster_get_db_home_for_sid "$sid")
                fi

                if echo "$p_sids" | grep -qx "$sid" 2>/dev/null; then
                    running_here="YES (PMON)"
                    sid_list+="${sid_list:+, }$sid"

                    local sid_home sid_role sid_mode
                    sid_home=$(cluster_get_db_home_for_sid "$sid")
                    [[ -z "$sid_home" ]] && sid_home="$home"
                    sid_role=$(cluster_get_role_for_sid "$sid" "$sid_home")
                    sid_mode=$(cluster_get_open_mode_for_sid "$sid" "$sid_home")
                    role_mode_parts+="${role_mode_parts:+; }${sid}: ${sid_role}/${sid_mode}"

                    if [[ "$db_role" == "UNKNOWN" && "$sid_role" != "UNKNOWN" ]]; then
                        db_role="$sid_role"
                    fi
                    if [[ "$open_mode" == "UNKNOWN" && "$sid_mode" != "UNKNOWN" ]]; then
                        open_mode="$sid_mode"
                    fi
                fi
            done <<< "$(cluster_get_sids_for_db_name "$db")"

            [[ -z "$home" ]] && home="${OLD_DB_HOME:-UNKNOWN}"

            summary+="<b>${db}</b> (home: ${home:-UNKNOWN}, running_here: ${running_here}"
            if [[ -n "$sid_list" ]]; then
                summary+=", SID(s): ${sid_list}"
                if [[ -n "$role_mode_parts" ]]; then
                    summary+=", details: ${role_mode_parts}"
                else
                    summary+=", role: ${db_role}, open_mode: ${open_mode}"
                fi
            fi
            summary+=")<br/>"
        done

        add_html_row "Local databases (post-reboot)" "INFO" "$summary"
        plain_summary=$(printf '%s\n' "$summary" | perl -0pe 's|<br/>|\n|g; s|<[^>]*>||g')
        printf '%s\n' "$plain_summary"
    else
        add_html_row "Local databases (post-reboot)" "INFO" "No PMON-detected databases on this node at post-reboot validation time."
    fi

    add_attachment "$LOG_FILE"

    if [[ "${INSIGHT_SUPPRESS_MAIL:-0}" == "1" ]]; then
        log "INSIGHT_SUPPRESS_MAIL=1; suppressing orchestrator post-reboot email."
    else
        send_html_report "Cluster Post-Reboot Validation - $HOST" "Cluster Post-Reboot Validation"
    fi
}

# ============================================================
# SSH REMOTE ORCHESTRATION (opt-in, DB VM only)
# ============================================================
# Design:
#   - ENABLE_SSH_REMOTE_ORCHESTRATION=false by default → script works on any platform
#   - Scripts at /etc/patching/shutdown_services.sh and /etc/patching/startup_services.sh
#     are TOOL-AGNOSTIC (EPC today, SCCM tomorrow, any tool)
#   - No cron, no emails from SSH functions — logs only, EPC controls timing
#   - Proper EPC exit codes: 0=success, 100-124=specific failures
#   - Timeouts on every SSH call + global script timeout
#   - Scripts must NOT block patching — non-zero exit → EPC can force-patch
#
# EPC ERROR CODES:
#   0   = Success
#   100 = APP hosts file not found/empty
#   101 = SSH connection test failed
#   102 = Remote shutdown failed/timed out
#   103 = Remote startup failed/timed out
#   110 = Local DB shutdown failed
#   111 = Local DB startup failed
#   124 = Global script timeout
# ============================================================

ENABLE_SSH_REMOTE_ORCHESTRATION="${ENABLE_SSH_REMOTE_ORCHESTRATION:-false}"

if [[ "$ENABLE_SSH_REMOTE_ORCHESTRATION" == true ]]; then
    APP_HOSTS_FILE="${APP_HOSTS_FILE:-/etc/patching/app_vm_hosts.txt}"
    SSH_USER="${SSH_USER:-patchuser}"
    SSH_KEY="${SSH_KEY:-/home/patchuser/.ssh/id_ed25519_patch}"
    SSH_OPTS="-i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=no"

    SSH_BATCH_SIZE="${SSH_BATCH_SIZE:-3}"

    # Tool-agnostic paths — /etc/patching/ works with EPC, SCCM, or any tool
    REMOTE_SHUTDOWN_SCRIPT="${REMOTE_SHUTDOWN_SCRIPT:-/etc/patching/shutdown_services.sh}"
    REMOTE_STARTUP_SCRIPT="${REMOTE_STARTUP_SCRIPT:-/etc/patching/startup_services.sh}"

    SSH_CMD_TIMEOUT="${SSH_CMD_TIMEOUT:-1800}"
    MAX_REMOTE_EXECUTION_TIME="${MAX_REMOTE_EXECUTION_TIME:-3600}"
    REMOTE_START_TIME=$(date +%s)
fi

# ============================================================
# PATCHUSER SETUP (run once per environment, like stage_software)
#
# What it does:
#   1. Creates patchgrp group + patchuser on LOCAL (DB) VM
#   2. Generates SSH key pair
#   3. Deploys /etc/patching/shutdown_services.sh and startup_services.sh locally
#   4. Installs restricted sudoers locally
#   5. Populates APP VM inventory (manual or dynamic)
#   6. Creates patchgrp + patchuser on each REMOTE APP VM via SSH (as patchuser)
#   7. Distributes SSH public key + scripts + sudoers to all APP VMs
#   8. Validates end-to-end SSH connectivity
# ============================================================
setup_patchuser() {
    # Disable set -e for entire function to prevent silent deaths — ensures report always sends
    set +e

    reset_html_report
    ensure_phase_log_dirs cluster
    LOG_FILE="${CLUSTER_LOG_DIR}/setup_patchuser_$(date +%F_%H%M%S).log"
    add_attachment "$LOG_FILE"
    log "PATCHUSER SETUP: Initialising SSH remote orchestration environment"

    local PATCH_USER="${SSH_USER:-patchuser}"
    local PATCH_GROUP="patchgrp"
    local PATCH_HOME="/home/${PATCH_USER}"
    local PATCH_SSH_DIR="${PATCH_HOME}/.ssh"
    local PATCH_KEY="${PATCH_SSH_DIR}/id_ed25519_patch"
    local HOSTS_FILE="${APP_HOSTS_FILE:-/etc/patching/app_vm_hosts.txt}"
    local PATCHING_DIR="/etc/patching"
    local SUDOERS_FILE="/etc/sudoers.d/patchuser-patching"

    # Source scripts to copy into /etc/patching/
    local SRC_SHUTDOWN="/home/oracle/insight_shutdown-osgidb.sh"
    local SRC_STARTUP="/home/oracle/insight_startup-osgidb.sh"
    local DST_SHUTDOWN="${PATCHING_DIR}/shutdown_services.sh"
    local DST_STARTUP="${PATCHING_DIR}/startup_services.sh"

    # -------------------------------------------------------
    # Step 1: Create patchgrp group + patchuser on LOCAL (DB) VM
    # -------------------------------------------------------
    add_html_row "Phase" "INFO" "<b>Step 1:</b> Create patchgrp group + patchuser on local DB VM"

    if ! getent group "$PATCH_GROUP" >/dev/null 2>&1; then
        groupadd "$PATCH_GROUP"
        add_html_row "Local group" "PASS" "Created group '$PATCH_GROUP'."
    else
        add_html_row "Local group" "INFO" "Group '$PATCH_GROUP' already exists."
    fi

    if id "$PATCH_USER" &>/dev/null; then
        add_html_row "Local patchuser" "INFO" "User '$PATCH_USER' already exists."
    else
        useradd -m -g "$PATCH_GROUP" -s /bin/bash "$PATCH_USER"
        passwd -l "$PATCH_USER"
        add_html_row "Local patchuser" "PASS" \
            "Created user '$PATCH_USER' in group '$PATCH_GROUP' with locked password (SSH key auth only)."
    fi

    mkdir -p "$PATCH_SSH_DIR"
    chmod 700 "$PATCH_SSH_DIR"
    chown -R "${PATCH_USER}:${PATCH_GROUP}" "$PATCH_SSH_DIR"

    # -------------------------------------------------------
    # Step 2: Generate SSH key pair (if not present)
    # -------------------------------------------------------
    add_html_row "Phase" "INFO" "<b>Step 2:</b> Generate SSH key pair"

    if [[ -f "$PATCH_KEY" ]]; then
        add_html_row "SSH key" "INFO" "Key already exists at $PATCH_KEY — skipping generation."
    else
        ssh-keygen -t ed25519 -f "$PATCH_KEY" -N "" -C "patchuser@$(hostname)" >/dev/null 2>&1
        chown "${PATCH_USER}:${PATCH_GROUP}" "$PATCH_KEY" "${PATCH_KEY}.pub"
        chmod 600 "$PATCH_KEY"
        add_html_row "SSH key" "PASS" "Generated Ed25519 key at $PATCH_KEY"
    fi

    # -------------------------------------------------------
    # Step 3: Deploy /etc/patching/ scripts on LOCAL VM
    # -------------------------------------------------------
    add_html_row "Phase" "INFO" "<b>Step 3:</b> Deploy patching scripts to /etc/patching/ (local)"

    mkdir -p "$PATCHING_DIR"
    chmod 755 "$PATCHING_DIR"

    if [[ -f "$SRC_SHUTDOWN" ]]; then
        cp -p "$SRC_SHUTDOWN" "$DST_SHUTDOWN"
        chmod 750 "$DST_SHUTDOWN"
        add_html_row "Local shutdown script" "PASS" "Copied to $DST_SHUTDOWN"
    else
        add_html_row "Local shutdown script" "WARN" \
            "Source not found: $SRC_SHUTDOWN — copy it manually to $DST_SHUTDOWN"
    fi

    if [[ -f "$SRC_STARTUP" ]]; then
        cp -p "$SRC_STARTUP" "$DST_STARTUP"
        chmod 750 "$DST_STARTUP"
        add_html_row "Local startup script" "PASS" "Copied to $DST_STARTUP"
    else
        add_html_row "Local startup script" "WARN" \
            "Source not found: $SRC_STARTUP — copy it manually to $DST_STARTUP"
    fi

    # -------------------------------------------------------
    # Step 4: Install restricted sudoers on LOCAL VM
    # -------------------------------------------------------
    add_html_row "Phase" "INFO" "<b>Step 4:</b> Install restricted sudoers (local)"

    cat > "$SUDOERS_FILE" <<EOF
# Patchuser restricted to patching scripts only
${PATCH_USER} ALL=(ALL) NOPASSWD: ${DST_SHUTDOWN}
${PATCH_USER} ALL=(ALL) NOPASSWD: ${DST_STARTUP}
${PATCH_USER} ALL=(ALL) NOPASSWD: /home/oracle/os-patching-auto-1.sh
EOF
    chmod 440 "$SUDOERS_FILE"
    if visudo -cf "$SUDOERS_FILE" >/dev/null 2>&1; then
        add_html_row "Local sudoers" "PASS" "Validated: $SUDOERS_FILE"
    else
        add_html_row "Local sudoers" "FAIL" "Syntax error in $SUDOERS_FILE — fix manually."
    fi

    # -------------------------------------------------------
    # Step 5: Populate APP VM inventory
    # -------------------------------------------------------
    add_html_row "Phase" "INFO" "<b>Step 5:</b> Populate APP VM inventory"

    mkdir -p "$(dirname "$HOSTS_FILE")"

    if [[ -f "$HOSTS_FILE" ]]; then
        local existing_count
        existing_count=$(grep -cvE '^\s*$|^\s*#' "$HOSTS_FILE" 2>/dev/null || echo 0)
        add_html_row "APP VM hosts file" "INFO" \
            "File already exists: $HOSTS_FILE (${existing_count} hosts). Skipping population."
    else
        add_html_row "APP VM hosts file" "INFO" \
            "File not found at $HOSTS_FILE — creating empty file."
        cat > "$HOSTS_FILE" <<'HOSTSEOF'
# APP VM Inventory for SSH Remote Orchestration
# One hostname or IP per line. Blank lines and # comments are ignored.
# VMs can be added or removed at any time — the orchestrator reads
# this file dynamically on every invocation.
#
# Populate this file using ONE of these methods:
#
# METHOD 1: Manual entry (add hostnames below)
#   zacptprsvmapp01
#   zacptprsvmapp02
#   zacptprsvmapp03
#
# METHOD 2: Dynamic scan (run from DB VM as root)
#   nmap -sn 172.17.36.0/24 | grep 'app' >> /etc/patching/app_vm_hosts.txt
#   # or
#   for i in $(seq 1 9); do echo "zacptprsvmapp0${i}"; done >> /etc/patching/app_vm_hosts.txt
#
# METHOD 3: Pull from CMDB/inventory tool
#   curl -s https://cmdb.example.com/api/vms?role=app | jq -r '.[]' >> /etc/patching/app_vm_hosts.txt

HOSTSEOF
        chmod 644 "$HOSTS_FILE"
        add_html_row "APP VM hosts file" "WARN" \
            "Created empty inventory at $HOSTS_FILE.<br/>\
Populate it with APP VM hostnames before running remote shutdown/startup.<br/>\
<b>Manual:</b> Edit the file and add one hostname per line.<br/>\
<b>Dynamic:</b> <code>for i in \$(seq 1 9); do echo \"zacptprsvmapp0\${i}\"; done >> $HOSTS_FILE</code>"
    fi

    # -------------------------------------------------------
    # Step 6: Setup patchuser on each REMOTE APP VM
    # -------------------------------------------------------
    add_html_row "Phase" "INFO" "<b>Step 6:</b> Setup patchgrp + patchuser on remote APP VMs"

    # FIX 1: SSH args as array — prevents word-splitting issues through sudo -u
    local SETUP_SSH_ARGS=()
    if [[ -f "$PATCH_KEY" ]]; then
        SETUP_SSH_ARGS+=( -i "$PATCH_KEY" )
    fi
    SETUP_SSH_ARGS+=( -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no )

    local hosts=()
    if [[ -f "$HOSTS_FILE" ]]; then
        while IFS= read -r line; do
            line=$(echo "$line" | xargs)
            [[ -z "$line" || "$line" == \#* ]] && continue
            hosts+=("$line")
        done < "$HOSTS_FILE"
    fi

    if (( ${#hosts[@]} == 0 )); then
        add_html_row "Remote setup" "WARN" \
            "No APP VMs in $HOSTS_FILE — populate it and re-run setup_patchuser."
    else
        add_html_row "Remote setup" "INFO" \
            "Setting up as '${PATCH_USER}' on ${#hosts[@]} APP VM(s): $(printf '%s ' "${hosts[@]}")"

        for host in "${hosts[@]}"; do
            local setup_log="${CLUSTER_LOG_DIR}/setup_patchuser_${host}_$(date +%F_%H%M%S).log"

            # Test SSH connectivity as patchuser
            if ! timeout 20s sudo -u "$PATCH_USER" ssh "${SETUP_SSH_ARGS[@]}" "${PATCH_USER}@${host}" "exit" >/dev/null 2>&1; then
                add_html_row "Remote setup ($host)" "FAIL" \
                    "Cannot SSH as ${PATCH_USER} to $host.<br/>\
Run the bootstrap script first as root:<br/>\
<code>sudo ./bootstrap_patchuser_remote.sh $HOSTS_FILE</code><br/>\
This creates patchuser, plants the SSH key, and grants temp sudo on all APP VMs."
                continue
            fi

            # Skip already-configured VMs (no sudo needed — /etc/patching/ is 755)
            local already_configured=""
            already_configured=$(sudo -u "$PATCH_USER" ssh "${SETUP_SSH_ARGS[@]}" "${PATCH_USER}@${host}" \
                "test -f /etc/patching/shutdown_services.sh && test -f /etc/patching/startup_services.sh && echo YES" 2>/dev/null) || true
            if [[ "$already_configured" == "YES" ]]; then
                add_html_row "Remote setup ($host)" "PASS" \
                    "Already configured — scripts in place. Skipping."
                continue
            fi

            # Test sudo access on remote VM BEFORE attempting setup
            local sudo_test=""
            sudo_test=$(sudo -u "$PATCH_USER" ssh "${SETUP_SSH_ARGS[@]}" "${PATCH_USER}@${host}" "sudo -n whoami" 2>&1) || true
            if [[ "$sudo_test" != "root" ]]; then
                add_html_row "Remote setup ($host)" "FAIL" \
                    "patchuser cannot sudo on $host. Create temp sudoers first:<br/>\
<code>echo \"patchuser ALL=(ALL) NOPASSWD:ALL\" > /etc/sudoers.d/patchuser-temp && chmod 440 /etc/sudoers.d/patchuser-temp</code>"
                continue
            fi

            # Create patchgrp + /etc/patching/ + sudoers on remote VM (via sudo)
            # FIX 3: Does NOT remove patchuser-temp — needed for script deployment below
            # FIX 4: || rc=$? prevents set -e from killing the script on failure
            local rc=0
            sudo -u "$PATCH_USER" ssh "${SETUP_SSH_ARGS[@]}" "${PATCH_USER}@${host}" sudo bash <<REMOTE_SETUP > "$setup_log" 2>&1 || rc=$?
set -e
PATCH_USER="${PATCH_USER}"
PATCH_GROUP="${PATCH_GROUP}"
PATCHING_DIR="/etc/patching"
SUDOERS_FILE="/etc/sudoers.d/patchuser-patching"

# Create dedicated patchgrp group if it doesn't exist
if ! getent group "\$PATCH_GROUP" >/dev/null 2>&1; then
    groupadd "\$PATCH_GROUP"
    echo "Created group \$PATCH_GROUP on \$(hostname)."
else
    echo "Group \$PATCH_GROUP already exists on \$(hostname)."
fi

# Ensure patchuser is in patchgrp
if id "\$PATCH_USER" &>/dev/null; then
    usermod -g "\$PATCH_GROUP" "\$PATCH_USER" 2>/dev/null || true
    echo "User \$PATCH_USER updated to group \$PATCH_GROUP on \$(hostname)."
else
    useradd -m -g "\$PATCH_GROUP" -s /bin/bash "\$PATCH_USER"
    passwd -l "\$PATCH_USER"
    echo "Created user \$PATCH_USER on \$(hostname)."
fi

# SSH dir
mkdir -p /home/\${PATCH_USER}/.ssh
chmod 700 /home/\${PATCH_USER}/.ssh
chown -R \${PATCH_USER}:\${PATCH_GROUP} /home/\${PATCH_USER}/.ssh

# /etc/patching/
mkdir -p "\$PATCHING_DIR"
chmod 755 "\$PATCHING_DIR"

# Install restricted sudoers (keeps patchuser-temp for now)
cat > "\$SUDOERS_FILE" <<SUDOEOF
\${PATCH_USER} ALL=(ALL) NOPASSWD: \${PATCHING_DIR}/shutdown_services.sh
\${PATCH_USER} ALL=(ALL) NOPASSWD: \${PATCHING_DIR}/startup_services.sh
\${PATCH_USER} ALL=(ALL) NOPASSWD: /home/oracle/os-patching-auto-1.sh
SUDOEOF
chmod 440 "\$SUDOERS_FILE"
visudo -cf "\$SUDOERS_FILE" && echo "Sudoers validated." || echo "WARN: Sudoers syntax error."

# Lock password (SSH key auth only from now on)
passwd -l "\$PATCH_USER" 2>/dev/null || true

echo "Setup complete on \$(hostname)."
REMOTE_SETUP
            add_attachment "$setup_log"

            if (( rc == 0 )); then
                add_html_row "Remote setup ($host)" "PASS" \
                    "patchgrp + patchuser + /etc/patching/ + sudoers created. See $(basename "$setup_log")"
            else
                add_html_row "Remote setup ($host)" "FAIL" \
                    "Setup failed (rc=$rc). See $(basename "$setup_log")"
            fi

            # FIX 2: scp runs as ROOT (no sudo -u) so it can read oracle-owned source files
            # Uses patchuser's SSH key for remote authentication via SETUP_SSH_ARGS
            # sudo mv works because patchuser-temp is still in place
            if [[ -f "$SRC_SHUTDOWN" ]]; then
                scp "${SETUP_SSH_ARGS[@]}" \
                    "$SRC_SHUTDOWN" "${PATCH_USER}@${host}:/tmp/shutdown_services.sh" >/dev/null 2>&1 && \
                sudo -u "$PATCH_USER" ssh "${SETUP_SSH_ARGS[@]}" "${PATCH_USER}@${host}" \
                    "sudo mv /tmp/shutdown_services.sh /etc/patching/shutdown_services.sh && sudo chmod 750 /etc/patching/shutdown_services.sh" 2>/dev/null && \
                add_html_row "Remote scripts ($host)" "PASS" "Deployed shutdown_services.sh" || \
                add_html_row "Remote scripts ($host)" "WARN" "Failed to deploy shutdown_services.sh"
            fi
            if [[ -f "$SRC_STARTUP" ]]; then
                scp "${SETUP_SSH_ARGS[@]}" \
                    "$SRC_STARTUP" "${PATCH_USER}@${host}:/tmp/startup_services.sh" >/dev/null 2>&1 && \
                sudo -u "$PATCH_USER" ssh "${SETUP_SSH_ARGS[@]}" "${PATCH_USER}@${host}" \
                    "sudo mv /tmp/startup_services.sh /etc/patching/startup_services.sh && sudo chmod 750 /etc/patching/startup_services.sh" 2>/dev/null && \
                add_html_row "Remote scripts ($host)" "PASS" "Deployed startup_services.sh" || \
                add_html_row "Remote scripts ($host)" "WARN" "Failed to deploy startup_services.sh"
            fi

            # Distribute SSH public key (via sudo)
            # FIX 4: || key_rc=$? prevents set -e from killing the script
            if [[ -f "${PATCH_KEY}.pub" ]]; then
                local pubkey
                pubkey=$(<"${PATCH_KEY}.pub")
                local key_rc=0
                sudo -u "$PATCH_USER" ssh "${SETUP_SSH_ARGS[@]}" "${PATCH_USER}@${host}" sudo bash <<KEYEOF >/dev/null 2>&1 || key_rc=$?
AUTH_FILE="/home/${PATCH_USER}/.ssh/authorized_keys"
mkdir -p "/home/${PATCH_USER}/.ssh"
touch "\$AUTH_FILE"
if ! grep -Fxq "$pubkey" "\$AUTH_FILE" 2>/dev/null; then
    echo "$pubkey" >> "\$AUTH_FILE"
fi
chmod 600 "\$AUTH_FILE"
chmod 700 "/home/${PATCH_USER}/.ssh"
chown -R ${PATCH_USER}:${PATCH_GROUP} "/home/${PATCH_USER}/.ssh"
KEYEOF
                if (( key_rc == 0 )); then
                    add_html_row "SSH key ($host)" "PASS" "Public key distributed."
                else
                    add_html_row "SSH key ($host)" "WARN" "Key distribution may have failed (rc=$key_rc)."
                fi
            fi

            # FIX 3: NOW remove temporary full-sudo (all deployment is done)
            # || true prevents set -e from killing the script
            sudo -u "$PATCH_USER" ssh "${SETUP_SSH_ARGS[@]}" "${PATCH_USER}@${host}" \
                "sudo rm -f /etc/sudoers.d/patchuser-temp" 2>/dev/null || true
            add_html_row "Cleanup ($host)" "PASS" "Removed temporary full-sudo (patchuser-temp)."
        done
    fi

    # -------------------------------------------------------
    # Step 7: Validate end-to-end connectivity
    # -------------------------------------------------------
    add_html_row "Phase" "INFO" "<b>Step 7:</b> Validate end-to-end SSH connectivity as patchuser"

    for host in "${hosts[@]}"; do
        local test_rc
        timeout 20s sudo -u "$PATCH_USER" ssh \
            -i "$PATCH_KEY" -o BatchMode=yes -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=no "${PATCH_USER}@${host}" \
            "echo 'SSH_OK from \$(hostname)'" >/dev/null 2>&1
        test_rc=$?
        if (( test_rc == 0 )); then
            add_html_row "SSH test ($host)" "PASS" "patchuser SSH connectivity confirmed."
        else
            add_html_row "SSH test ($host)" "FAIL" \
                "Cannot SSH as patchuser to $host (rc=$test_rc). Check key + sudoers."
        fi
    done

    # -------------------------------------------------------
    # Summary
    # -------------------------------------------------------
    add_html_row "Setup summary" "INFO" \
        "patchuser setup complete. ${#hosts[@]} APP VM(s) configured.<br/>\
Next: Enable SSH orchestration:<br/>\
<code>ENABLE_SSH_REMOTE_ORCHESTRATION=true ./os-patching-auto-1.sh remote_shutdown_apps_then_db</code>"

    send_html_report "Patchuser Setup - $HOST" "Patchuser Setup Report"

    # Re-enable strict mode
    set -e
}
# ------------------------------------------------------------
# SSH REMOTE ORCHESTRATION: Shutdown APPs first, then DB
# ------------------------------------------------------------
remote_shutdown_apps_then_db() {
    set +e

    reset_html_report
    ensure_phase_log_dirs cluster
    LOG_FILE="${CLUSTER_LOG_DIR}/remote_shutdown_$(date +%F_%H%M%S).log"
    add_attachment "$LOG_FILE"
    log "REMOTE SHUTDOWN: APP VMs first, then local DB VM"

    local PATCH_USER="${SSH_USER:-patchuser}"
    local PATCH_KEY="/home/${PATCH_USER}/.ssh/id_ed25519_patch"
    local HOSTS_FILE="${APP_HOSTS_FILE:-/etc/patching/app_vm_hosts.txt}"
    local SHUTDOWN_SCRIPT="/etc/patching/shutdown_services.sh"

    local SSH_ARGS=()
    if [[ -f "$PATCH_KEY" ]]; then
        SSH_ARGS+=( -i "$PATCH_KEY" )
    fi
    SSH_ARGS+=( -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no )

    # -------------------------------------------------------
    # Step 1: Read APP VM inventory
    # -------------------------------------------------------
    local hosts=()
    if [[ -f "$HOSTS_FILE" ]]; then
        while IFS= read -r line; do
            line=$(echo "$line" | xargs)
            [[ -z "$line" || "$line" == \#* ]] && continue
            hosts+=("$line")
        done < "$HOSTS_FILE"
    fi

    if (( ${#hosts[@]} == 0 )); then
        add_html_row "APP VM inventory" "WARN" \
            "No APP VMs in $HOSTS_FILE — nothing to shut down remotely."
    else
        add_html_row "APP VM inventory" "INFO" \
            "${#hosts[@]} APP VM(s): $(printf '%s ' "${hosts[@]}")"
    fi

    # -------------------------------------------------------
    # Step 2: SSH to each APP VM and run shutdown script
    # -------------------------------------------------------
    add_html_row "Phase" "INFO" "<b>Step 1:</b> Shutdown services on remote APP VMs"

    local app_failures=0

    for host in "${hosts[@]}"; do
        local remote_log="${CLUSTER_LOG_DIR}/remote_shutdown_${host}_$(date +%F_%H%M%S).log"

        # Test connectivity
        if ! timeout 20s sudo -u "$PATCH_USER" ssh "${SSH_ARGS[@]}" "${PATCH_USER}@${host}" "exit" >/dev/null 2>&1; then
            add_html_row "APP shutdown ($host)" "FAIL" \
                "Cannot SSH as ${PATCH_USER} to $host."
            (( app_failures++ ))
            continue
        fi

        # Test sudo access to shutdown script
        local sudo_test=""
        sudo_test=$(sudo -u "$PATCH_USER" ssh "${SSH_ARGS[@]}" "${PATCH_USER}@${host}" "sudo -n -l $SHUTDOWN_SCRIPT" 2>&1) || true
        if ! echo "$sudo_test" | grep -q "$SHUTDOWN_SCRIPT"; then
            add_html_row "APP shutdown ($host)" "FAIL" \
                "patchuser cannot sudo $SHUTDOWN_SCRIPT on $host. Check sudoers."
            (( app_failures++ ))
            continue
        fi

        add_html_row "APP shutdown ($host)" "INFO" \
            "Running $SHUTDOWN_SCRIPT on $host..."

        local rc=0
        sudo -u "$PATCH_USER" ssh "${SSH_ARGS[@]}" "${PATCH_USER}@${host}" \
            "sudo $SHUTDOWN_SCRIPT" > "$remote_log" 2>&1 || rc=$?

        add_attachment "$remote_log"

        if (( rc == 0 )); then
            add_html_row "APP shutdown ($host)" "PASS" \
                "Shutdown completed successfully. See $(basename "$remote_log")"
        else
            add_html_row "APP shutdown ($host)" "WARN" \
                "Shutdown returned rc=$rc. See $(basename "$remote_log")"
            (( app_failures++ ))
        fi
    done

    if (( app_failures > 0 )); then
        add_html_row "APP shutdown summary" "WARN" \
            "${app_failures} APP VM(s) had issues during shutdown."
    elif (( ${#hosts[@]} > 0 )); then
        add_html_row "APP shutdown summary" "PASS" \
            "All ${#hosts[@]} APP VM(s) shut down successfully."
    fi

    # -------------------------------------------------------
    # Step 3: Run local DB shutdown
    # -------------------------------------------------------
    add_html_row "Phase" "INFO" "<b>Step 2:</b> Shutdown services on local DB VM"

    local local_shutdown="/home/oracle/insight_shutdown-osgidb.sh"
    local local_log="${CLUSTER_LOG_DIR}/local_db_shutdown_$(date +%F_%H%M%S).log"

    if [[ -x "$local_shutdown" ]]; then
        add_html_row "DB shutdown (local)" "INFO" \
            "Running $local_shutdown on local DB VM..."

        local db_rc=0
        "$local_shutdown" > "$local_log" 2>&1 || db_rc=$?
        add_attachment "$local_log"

        if (( db_rc == 0 )); then
            add_html_row "DB shutdown (local)" "PASS" \
                "Local DB shutdown completed. See $(basename "$local_log")"
        else
            add_html_row "DB shutdown (local)" "WARN" \
                "Local DB shutdown returned rc=$db_rc. See $(basename "$local_log")"
        fi
    else
        add_html_row "DB shutdown (local)" "WARN" \
            "$local_shutdown not found or not executable."
    fi

    # -------------------------------------------------------
    # Summary
    # -------------------------------------------------------
    add_html_row "Remote shutdown summary" "INFO" \
        "Remote orchestration complete. ${#hosts[@]} APP VM(s) + local DB VM processed."

    send_html_report "Remote Shutdown - $HOST" "Remote Shutdown Report"

    set -e
}

# ------------------------------------------------------------
# SSH REMOTE ORCHESTRATION: Startup DB first, then APPs
# ------------------------------------------------------------
remote_startup_db_then_apps() {
    set +e

    reset_html_report
    ensure_phase_log_dirs cluster
    LOG_FILE="${CLUSTER_LOG_DIR}/remote_startup_$(date +%F_%H%M%S).log"
    add_attachment "$LOG_FILE"
    log "REMOTE STARTUP: Local DB VM first, then APP VMs"

    local PATCH_USER="${SSH_USER:-patchuser}"
    local PATCH_KEY="/home/${PATCH_USER}/.ssh/id_ed25519_patch"
    local HOSTS_FILE="${APP_HOSTS_FILE:-/etc/patching/app_vm_hosts.txt}"
    local STARTUP_SCRIPT="/etc/patching/startup_services.sh"

    local SSH_ARGS=()
    if [[ -f "$PATCH_KEY" ]]; then
        SSH_ARGS+=( -i "$PATCH_KEY" )
    fi
    SSH_ARGS+=( -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no )

    # -------------------------------------------------------
    # Step 1: Start local DB first
    # -------------------------------------------------------
    add_html_row "Phase" "INFO" "<b>Step 1:</b> Startup services on local DB VM"

    local local_startup="/home/oracle/insight_startup-osgidb.sh"
    local local_log="${CLUSTER_LOG_DIR}/local_db_startup_$(date +%F_%H%M%S).log"

    if [[ -x "$local_startup" ]]; then
        add_html_row "DB startup (local)" "INFO" \
            "Running $local_startup on local DB VM..."

        local db_rc=0
        "$local_startup" > "$local_log" 2>&1 || db_rc=$?
        add_attachment "$local_log"

        if (( db_rc == 0 )); then
            add_html_row "DB startup (local)" "PASS" \
                "Local DB startup completed. See $(basename "$local_log")"
        else
            add_html_row "DB startup (local)" "WARN" \
                "Local DB startup returned rc=$db_rc. See $(basename "$local_log")"
        fi
    else
        add_html_row "DB startup (local)" "WARN" \
            "$local_startup not found or not executable."
    fi

    # -------------------------------------------------------
    # Step 2: Read APP VM inventory and start services
    # -------------------------------------------------------
    local hosts=()
    if [[ -f "$HOSTS_FILE" ]]; then
        while IFS= read -r line; do
            line=$(echo "$line" | xargs)
            [[ -z "$line" || "$line" == \#* ]] && continue
            hosts+=("$line")
        done < "$HOSTS_FILE"
    fi

    add_html_row "Phase" "INFO" "<b>Step 2:</b> Startup services on remote APP VMs"

    if (( ${#hosts[@]} == 0 )); then
        add_html_row "APP VM inventory" "WARN" \
            "No APP VMs in $HOSTS_FILE — nothing to start remotely."
    else
        local app_failures=0

        for host in "${hosts[@]}"; do
            local remote_log="${CLUSTER_LOG_DIR}/remote_startup_${host}_$(date +%F_%H%M%S).log"

            if ! timeout 20s sudo -u "$PATCH_USER" ssh "${SSH_ARGS[@]}" "${PATCH_USER}@${host}" "exit" >/dev/null 2>&1; then
                add_html_row "APP startup ($host)" "FAIL" \
                    "Cannot SSH as ${PATCH_USER} to $host."
                (( app_failures++ ))
                continue
            fi

            add_html_row "APP startup ($host)" "INFO" \
                "Running $STARTUP_SCRIPT on $host..."

            local rc=0
            sudo -u "$PATCH_USER" ssh "${SSH_ARGS[@]}" "${PATCH_USER}@${host}" \
                "sudo $STARTUP_SCRIPT" > "$remote_log" 2>&1 || rc=$?

            add_attachment "$remote_log"

            if (( rc == 0 )); then
                add_html_row "APP startup ($host)" "PASS" \
                    "Startup completed successfully. See $(basename "$remote_log")"
            else
                add_html_row "APP startup ($host)" "WARN" \
                    "Startup returned rc=$rc. See $(basename "$remote_log")"
                (( app_failures++ ))
            fi
        done
    fi

    add_html_row "Remote startup summary" "INFO" \
        "Remote orchestration complete. Local DB + ${#hosts[@]} APP VM(s) processed."

    send_html_report "Remote Startup - $HOST" "Remote Startup Report"

    set -e
}

# ============================================================
# SSH REMOTE ORCHESTRATION FUNCTIONS
# Guarded by ENABLE_SSH_REMOTE_ORCHESTRATION
# ============================================================
if [[ "${ENABLE_SSH_REMOTE_ORCHESTRATION:-false}" == true ]]; then

check_remote_timeout() {
    local CURRENT_TIME ELAPSED
    CURRENT_TIME=$(date +%s)
    ELAPSED=$(( CURRENT_TIME - REMOTE_START_TIME ))
    if (( ELAPSED > MAX_REMOTE_EXECUTION_TIME )); then
        log "CRITICAL: Global timeout of ${MAX_REMOTE_EXECUTION_TIME}s reached after ${ELAPSED}s!"
        add_html_row "Global timeout" "FAIL" \
            "Timed out after ${ELAPSED}s (limit: ${MAX_REMOTE_EXECUTION_TIME}s). EPC code: 124"
        send_html_report "Remote Orchestration TIMEOUT - $HOST" "Remote Orchestration"
        exit 124
    fi
}

fail_with_epc_error() {
    local code="$1" msg="$2"
    log "EPC ERROR (code=$code): $msg"
    add_html_row "EPC Error" "FAIL" "Code: ${code} — ${msg}"
    send_html_report "Remote Orch FAILED (EPC $code) - $HOST" "Remote Orchestration"
    exit "$code"
}

load_app_hosts() {
    local hosts_file="${APP_HOSTS_FILE}" hosts=()
    [[ ! -f "$hosts_file" ]] && fail_with_epc_error 100 "APP hosts file not found: $hosts_file"
    while IFS= read -r line; do
        line=$(echo "$line" | xargs)
        [[ -z "$line" || "$line" == \#* ]] && continue
        hosts+=("$line")
    done < "$hosts_file"
    (( ${#hosts[@]} == 0 )) && fail_with_epc_error 100 "No hosts found in $hosts_file"
    printf '%s\n' "${hosts[@]}"
}

ssh_remote_exec() {
    local host="$1" remote_cmd="$2" label="${3:-remote_exec}" epc_code="${4:-102}"
    local log_file="${LOG_DIR}/ssh_${label}_${host}_$(date +%F_%H%M%S).log"
    check_remote_timeout
    log "SSH [$label] -> ${SSH_USER}@${host}: $remote_cmd"

    # Build SSH args as a proper array
    local SSH_ARGS_ARR=()
    if [[ -f "/home/${SSH_USER}/.ssh/id_ed25519_patch" ]]; then
        SSH_ARGS_ARR+=( -i "/home/${SSH_USER}/.ssh/id_ed25519_patch" )
    fi
    SSH_ARGS_ARR+=( -o BatchMode=yes )
    SSH_ARGS_ARR+=( -o ConnectTimeout=15 )
    SSH_ARGS_ARR+=( -o ServerAliveInterval=15 )
    SSH_ARGS_ARR+=( -o ServerAliveCountMax=3 )
    SSH_ARGS_ARR+=( -o StrictHostKeyChecking=no )

    # Test connection first
    if ! timeout 20s sudo -u "$SSH_USER" ssh "${SSH_ARGS_ARR[@]}" "${SSH_USER}@${host}" "exit" > /dev/null 2>&1; then
        add_html_row "SSH $label ($host)" "FAIL" "Connection test failed (unreachable or auth error). EPC: 101"
        return 101
    fi

    check_remote_timeout
    timeout "$SSH_CMD_TIMEOUT" sudo -u "$SSH_USER" ssh "${SSH_ARGS_ARR[@]}" \
        "${SSH_USER}@${host}" "$remote_cmd" > "$log_file" 2>&1
    local rc=$?
    add_attachment "$log_file"

    if (( rc == 0 )); then
        add_html_row "SSH $label ($host)" "PASS" "OK. See $(basename "$log_file")"
    elif (( rc == 124 )); then
        add_html_row "SSH $label ($host)" "FAIL" \
            "Timed out after ${SSH_CMD_TIMEOUT}s. EPC: ${epc_code}"
    else
        add_html_row "SSH $label ($host)" "FAIL" \
            "Failed rc=$rc. EPC: ${epc_code}. See $(basename "$log_file")"
    fi
    return $rc
}

fi  # end ENABLE_SSH_REMOTE_ORCHESTRATION guard for core functions

# ============================================================
# SHUTDOWN — APP VMs FIRST (SSH), THEN LOCAL DB
# ============================================================
if [[ "${ENABLE_SSH_REMOTE_ORCHESTRATION:-false}" == true ]]; then

remote_shutdown_apps_then_local_db() {
    REMOTE_START_TIME=$(date +%s)
    reset_html_report
    ensure_phase_log_dirs cluster
    LOG_FILE="${CLUSTER_LOG_DIR}/remote_shutdown_$(date +%F_%H%M%S).log"
    add_attachment "$LOG_FILE"
    log "REMOTE SHUTDOWN: APP VMs first (SSH), then local DB"

    local hosts_raw hosts=()
    hosts_raw=$(load_app_hosts) || return $?
    while IFS= read -r h; do [[ -n "$h" ]] && hosts+=("$h"); done <<< "$hosts_raw"
    add_html_row "APP VMs" "INFO" "Found ${#hosts[@]}: $(printf '%s ' "${hosts[@]}")"

    # ---- Step 1: SSH shutdown ALL APP VMs concurrently ----
    add_html_row "Phase" "INFO" "<b>Step 1:</b> Shutdown ${#hosts[@]} APP VM(s) via SSH"
    local pids=() host_for_pid=() rc_files=()
    for host in "${hosts[@]}"; do
        check_remote_timeout
        local rc_file="/tmp/ssh_rc_${host}_$$.tmp"
        rc_files+=("$rc_file")
        (
            ssh_remote_exec "$host" \
                "sudo ${REMOTE_SHUTDOWN_SCRIPT}" "shutdown" "102"
            echo $? > "$rc_file"
        ) &
        pids+=($!); host_for_pid+=("$host")
    done

    local app_ok=true
    for i in "${!pids[@]}"; do
        wait "${pids[$i]}" 2>/dev/null || true
        local vm_rc=0; [[ -f "${rc_files[$i]}" ]] && vm_rc=$(<"${rc_files[$i]}")
        rm -f "${rc_files[$i]}" 2>/dev/null
        (( vm_rc != 0 )) && app_ok=false
    done

    [[ "$app_ok" == true ]] && \
        add_html_row "APP shutdown" "PASS" "All ${#hosts[@]} APP VMs down." || \
        add_html_row "APP shutdown" "WARN" "Some APP VMs reported issues."

    # ---- Step 2: Shutdown local DB ----
    check_remote_timeout
    add_html_row "Phase" "INFO" "<b>Step 2:</b> Shutdown local DB"
    if [[ -x "$REMOTE_SHUTDOWN_SCRIPT" ]]; then
        local db_log="${CLUSTER_LOG_DIR}/local_db_shutdown_$(date +%F_%H%M%S).log"
        timeout "${SSH_CMD_TIMEOUT}" "$REMOTE_SHUTDOWN_SCRIPT" > "$db_log" 2>&1
        local db_rc=$?; add_attachment "$db_log"
        if (( db_rc == 0 )); then
            add_html_row "Local DB shutdown" "PASS" "rc=0"
        else
            add_html_row "Local DB shutdown" "FAIL" "rc=$db_rc. EPC: 110"
            app_ok=false
        fi
    else
        add_html_row "Local DB shutdown" "FAIL" \
            "Script not found: $REMOTE_SHUTDOWN_SCRIPT. EPC: 110"
        app_ok=false
    fi

    local elapsed=$(( $(date +%s) - REMOTE_START_TIME ))
    [[ "$app_ok" == true ]] && \
        add_html_row "Overall" "PASS" "All down. Elapsed: ${elapsed}s." || \
        add_html_row "Overall" "WARN" "Issues detected. Elapsed: ${elapsed}s."
    send_html_report "Remote Shutdown - $HOST" "Remote Shutdown (APPs then DB)"

    [[ "$app_ok" == true ]] && return 0 || return 1
}

fi
# ============================================================
# SSH REMOTE ORCHESTRATION — SHUTDOWN APPs FIRST, THEN LOCAL DB
# ============================================================
if [[ "${ENABLE_SSH_REMOTE_ORCHESTRATION:-false}" == true ]]; then

remote_shutdown_apps_then_local_db() {
    REMOTE_START_TIME=$(date +%s)
    set +e

    reset_html_report
    ensure_phase_log_dirs cluster
    LOG_FILE="${CLUSTER_LOG_DIR}/remote_shutdown_$(date +%F_%H%M%S).log"
    add_attachment "$LOG_FILE"
    log "REMOTE SHUTDOWN: APP VMs first, then local DB"

    # ---- Step 1: Read APP VM inventory ----
    local hosts_raw hosts=()
    hosts_raw=$(load_app_hosts) || {
        add_html_row "APP VM inventory" "FAIL" "Could not load $APP_HOSTS_FILE"
        send_html_report "Remote Shutdown - $HOST" "Remote Shutdown (APPs then DB)"
        set -e; return 1
    }
    while IFS= read -r h; do [[ -n "$h" ]] && hosts+=("$h"); done <<< "$hosts_raw"
    local total=${#hosts[@]}

    if (( total == 0 )); then
        add_html_row "APP VM inventory" "WARN" \
            "No APP VMs in $APP_HOSTS_FILE — skipping remote shutdown."
    else
        add_html_row "APP VM inventory" "INFO" \
            "${total} APP VM(s): $(printf '%s ' "${hosts[@]}")"
    fi

    # ---- Step 2: SSH to each APP VM and run shutdown script (batched) ----
    add_html_row "Phase" "INFO" \
        "<b>Step 1:</b> Shutdown services on ${total} remote APP VM(s) in batches of ${SSH_BATCH_SIZE}"

    local batch_num=0 app_failures=0 i=0
    while (( i < total )); do
        check_remote_timeout; ((++batch_num))
        local batch_hosts=("${hosts[@]:$i:$SSH_BATCH_SIZE}")
        add_html_row "Batch ${batch_num}" "INFO" \
            "Shutting down: $(printf '%s ' "${batch_hosts[@]}")"

        local pids=() host_for_pid=() rc_files=()
        for host in "${batch_hosts[@]}"; do
            local rc_file="/tmp/ssh_shutdown_rc_${host}_$$.tmp"
            rc_files+=("$rc_file")
            (
                ssh_remote_exec "$host" \
                    "sudo ${REMOTE_SHUTDOWN_SCRIPT}" \
                    "shutdown_b${batch_num}" "102"
                echo $? > "$rc_file"
            ) &
            pids+=($!); host_for_pid+=("$host")
        done

        local batch_ok=true
        for j in "${!pids[@]}"; do
            wait "${pids[$j]}" 2>/dev/null || true
            local vm_rc=0; [[ -f "${rc_files[$j]}" ]] && vm_rc=$(<"${rc_files[$j]}")
            rm -f "${rc_files[$j]}" 2>/dev/null
            if (( vm_rc != 0 )); then
                batch_ok=false
                (( app_failures++ ))
            fi
        done

        [[ "$batch_ok" == true ]] && \
            add_html_row "Batch ${batch_num}" "PASS" "All shut down." || \
            add_html_row "Batch ${batch_num}" "WARN" "Some issues in batch."

        i=$(( i + SSH_BATCH_SIZE ))
        (( i < total )) && { log "10s between batches..."; sleep 10; }
    done

    if (( app_failures > 0 )); then
        add_html_row "APP shutdown summary" "WARN" \
            "${app_failures} APP VM(s) had issues during shutdown."
    elif (( total > 0 )); then
        add_html_row "APP shutdown summary" "PASS" \
            "All ${total} APP VM(s) shut down successfully in ${batch_num} batch(es)."
    fi

    # ---- Step 3: Shutdown local DB ----
    add_html_row "Phase" "INFO" "<b>Step 2:</b> Shutdown services on local DB VM"

    if [[ -x "$REMOTE_SHUTDOWN_SCRIPT" ]]; then
        local db_log="${CLUSTER_LOG_DIR}/local_db_shutdown_$(date +%F_%H%M%S).log"
        add_html_row "DB shutdown (local)" "INFO" \
            "Running $REMOTE_SHUTDOWN_SCRIPT on local DB VM..."

        local db_rc=0
        timeout "${SSH_CMD_TIMEOUT}" "$REMOTE_SHUTDOWN_SCRIPT" > "$db_log" 2>&1 || db_rc=$?
        add_attachment "$db_log"

        if (( db_rc == 0 )); then
            add_html_row "DB shutdown (local)" "PASS" \
                "Local DB shutdown completed. See $(basename "$db_log")"
        else
            add_html_row "DB shutdown (local)" "WARN" \
                "Local DB shutdown returned rc=$db_rc. See $(basename "$db_log")"
        fi
    else
        add_html_row "DB shutdown (local)" "WARN" \
            "Script not found or not executable: $REMOTE_SHUTDOWN_SCRIPT"
    fi

    # ---- Summary ----
    local elapsed=$(( $(date +%s) - REMOTE_START_TIME ))
    local overall_status="PASS"
    (( app_failures > 0 )) && overall_status="WARN"

    add_html_row "Overall" "$overall_status" \
        "Remote shutdown complete. ${total} APP VM(s) + local DB. ${elapsed}s elapsed."

    send_html_report "Remote Shutdown - $HOST" "Remote Shutdown (APPs then DB)"

    set -e
    (( app_failures == 0 )) && return 0 || return 1
}

# ============================================================
# BATCHED STARTUP — DB FIRST, THEN APP VMs IN CONFIGURABLE BATCHES
# ============================================================
batched_startup_db_then_apps() {
    REMOTE_START_TIME=$(date +%s)
    reset_html_report
    ensure_phase_log_dirs cluster
    LOG_FILE="${CLUSTER_LOG_DIR}/batched_startup_$(date +%F_%H%M%S).log"
    add_attachment "$LOG_FILE"
    log "BATCHED STARTUP: DB first, then APPs in batches of ${SSH_BATCH_SIZE}"

    # ---- Step 1: Start local DB ----
    add_html_row "Phase" "INFO" "<b>Step 1:</b> Start local DB"
    if [[ -x "$REMOTE_STARTUP_SCRIPT" ]]; then
        local db_log="${CLUSTER_LOG_DIR}/local_db_startup_$(date +%F_%H%M%S).log"
        timeout "${SSH_CMD_TIMEOUT}" "$REMOTE_STARTUP_SCRIPT" > "$db_log" 2>&1
        local db_rc=$?; add_attachment "$db_log"
        (( db_rc == 0 )) && add_html_row "Local DB startup" "PASS" "rc=0" || \
            add_html_row "Local DB startup" "WARN" "rc=$db_rc. EPC: 111"
    else
        add_html_row "Local DB startup" "WARN" \
            "Script not found: $REMOTE_STARTUP_SCRIPT"
    fi
    check_remote_timeout
    log "Waiting 30s for DB services to stabilise..."
    sleep 30

    # ---- Step 2: APP VMs in batches ----
    local hosts_raw hosts=()
    hosts_raw=$(load_app_hosts) || return $?
    while IFS= read -r h; do [[ -n "$h" ]] && hosts+=("$h"); done <<< "$hosts_raw"
    local total=${#hosts[@]}
    add_html_row "Phase" "INFO" \
        "<b>Step 2:</b> ${total} APP VMs in batches of ${SSH_BATCH_SIZE}. \
Total batches: $(( (total + SSH_BATCH_SIZE - 1) / SSH_BATCH_SIZE ))"

    local batch_num=0 overall_ok=true i=0
    while (( i < total )); do
        check_remote_timeout; ((++batch_num))
        local batch_hosts=("${hosts[@]:$i:$SSH_BATCH_SIZE}")
        add_html_row "Batch ${batch_num}" "INFO" \
            "Starting: $(printf '%s ' "${batch_hosts[@]}")"

        local pids=() host_for_pid=() rc_files=()
        for host in "${batch_hosts[@]}"; do
            local rc_file="/tmp/ssh_startup_rc_${host}_$$.tmp"
            rc_files+=("$rc_file")
            (
                ssh_remote_exec "$host" \
                    "sudo ${REMOTE_STARTUP_SCRIPT}" \
                    "startup_b${batch_num}" "103"
                echo $? > "$rc_file"
            ) &
            pids+=($!); host_for_pid+=("$host")
        done

        local batch_ok=true
        for j in "${!pids[@]}"; do
            wait "${pids[$j]}" 2>/dev/null || true
            local vm_rc=0; [[ -f "${rc_files[$j]}" ]] && vm_rc=$(<"${rc_files[$j]}")
            rm -f "${rc_files[$j]}" 2>/dev/null
            (( vm_rc != 0 )) && { batch_ok=false; overall_ok=false; }
        done

        [[ "$batch_ok" == true ]] && \
            add_html_row "Batch ${batch_num}" "PASS" "All up." || \
            add_html_row "Batch ${batch_num}" "WARN" "Some issues."

        i=$(( i + SSH_BATCH_SIZE ))
        (( i < total )) && { log "10s between batches..."; sleep 10; }
    done

    local elapsed=$(( $(date +%s) - REMOTE_START_TIME ))
    [[ "$overall_ok" == true ]] && \
        add_html_row "Overall" "PASS" \
            "DB + ${total} APPs up in ${batch_num} batch(es). ${elapsed}s." || \
        add_html_row "Overall" "WARN" "Some issues. ${elapsed}s."
    send_html_report "Batched Startup - $HOST" "Batched Startup (DB + APPs)"

    [[ "$overall_ok" == true ]] && return 0 || return 1
}

fi   # end ENABLE_SSH_REMOTE_ORCHESTRATION guard

# ------------------------------------------------------------
# HELP / USAGE
# ------------------------------------------------------------
print_help() {
    cat <<EOF
Usage: $(basename "$0") [phase] [args...]

Phases (Software Staging):
  stage_software                   Validate & prepare all required software. Downtime: NO.

Phases (GI patching, 19c):
  gi_precheck                      GI Precheck. Downtime: NO.
  gi_install                       GI Install (OOP new GI home). Downtime: NO.
  gi_switch                        GI Switch to NEW_GI_HOME. Downtime: YES (GI/cluster restart).
  gi_rollback                      GI Rollback to OLD_GI_HOME. Downtime: YES (GI/cluster restart).

Phases (DB patching, 19c):
  db_precheck                      DB Precheck. Downtime: NO.
  db_install                       DB Install (OOP new DB home). Downtime: NO.
  db_switch <DB_UNIQUE_NAME>       DB Switch home to NEW_DB_HOME. Downtime: YES (DB outage for that DB).
  db_rollback <DB_UNIQUE_NAME>     DB Rollback home to OLD_DB_HOME. Downtime: YES (DB outage for that DB).
  db_ojvm_only                     Apply OJVM one-off via opatch to NEW_DB_HOME only. Downtime: NO.

Phases (GI UPGRADE 19c -> 23/26ai):
  gi_upgrade_precheck              GI Upgrade Precheck. Downtime: NO.
  gi_upgrade_install               GI Upgrade Install (23/26ai software). Downtime: NO.
  gi_upgrade_upgrade               GI Upgrade (gridSetup.sh -upgrade). Downtime: YES (GI restart).

Phases (DB UPGRADE 19c -> 23/26ai via AutoUpgrade):
  db_upgrade_precheck              DB Upgrade Precheck (AutoUpgrade ANALYZE). Downtime: NO.
  db_upgrade_install               DB Upgrade Install (23/26ai DB software). Downtime: NO.
  db_upgrade_upgrade               DB Upgrade Deploy (AutoUpgrade DEPLOY). Downtime: YES (DB outage).
  db_upgrade_rollback              DB Upgrade Rollback (placeholder).

Phases (Cluster maintenance / MEC-friendly, per node):
  cluster_precheck                 OS + DB snapshot (no changes). Downtime: NO.
  cluster_stop_dbs                 Graceful stop of local DBs (Postgres/Oracle). Downtime: YES for local DBs.
  cluster_os_patch                 Execute OS patch script (OS_PATCH_SCRIPT). Downtime: depends on patch.
  cluster_reboot                   Reboot this node. Downtime: YES.
  cluster_postreboot_db            After reboot on DB nodes: ensure ASM up and restart DBs.

Phases (SSH Remote Orchestration — opt-in, DB VM only):
  setup_patchuser                  Setup patchuser + SSH keys + /etc/patching/ scripts. Downtime: NO.
  remote_shutdown_apps_then_db     SSH shutdown APP VMs first, then local DB. Downtime: YES.
  batched_startup                  Start DB first, then APP VMs in batches. Downtime: NO.

Scheduling (run via 'at' or menu):
  gi_switch_scheduled              GI Switch scheduled via 'GI Switch (schedule via at)'.
  db_switch_scheduled <DB_UNIQUE>  DB Switch scheduled via 'DB Switch (schedule via at)'.
  gi_upgrade_upgrade_scheduled     GI Upgrade (gridSetup.sh -upgrade) scheduled via 'GI Upgrade (schedule switch)'.
  db_upgrade_upgrade_scheduled <DB_UNIQUE>
                                   DB Upgrade DEPLOY scheduled via 'DB Upgrade (schedule deploy)'.

Command line examples (Software Staging):
  $(basename "$0") stage_software

Command line examples (GI/DB patching):
  # GI from CLI (patching)
  $(basename "$0") gi_precheck
  $(basename "$0") gi_install
  $(basename "$0") gi_switch
  $(basename "$0") gi_rollback

  # DB from CLI (patching), example DB_UNIQUE_NAME=cdb_iacls01
  $(basename "$0") db_precheck
  $(basename "$0") db_install
  $(basename "$0") db_switch cdb_iacls01
  $(basename "$0") db_rollback cdb_iacls01

  # DB OJVM Only
  $(basename "$0") db_ojvm_only

Command line examples (GI/DB UPGRADE 19c -> 23/26ai):
  # GI upgrade
  $(basename "$0") gi_upgrade_precheck
  $(basename "$0") gi_upgrade_install
  $(basename "$0") gi_upgrade_upgrade

  # DB upgrade (AutoUpgrade) ? will prompt for DB if not specified
  $(basename "$0") db_upgrade_precheck
  $(basename "$0") db_upgrade_install
  $(basename "$0") db_upgrade_upgrade

Command line examples (SSH Remote Orchestration — opt-in):
  # One-time: setup patchuser + SSH keys + /etc/patching/ scripts
  $(basename "$0") setup_patchuser

  # Shutdown APP VMs first (SSH), then local DB
  ENABLE_SSH_REMOTE_ORCHESTRATION=true $(basename "$0") remote_shutdown_apps_then_db

  # Startup DB first, then APP VMs in batches of 3 (default)
  ENABLE_SSH_REMOTE_ORCHESTRATION=true $(basename "$0") batched_startup

  # Override batch size at runtime (5 at a time)
  ENABLE_SSH_REMOTE_ORCHESTRATION=true SSH_BATCH_SIZE=5 $(basename "$0") batched_startup

  # EPC integration (with global timeout wrapper)
  timeout 60m /home/oracle/epc_remote_shutdown_wrapper.sh

Scheduling examples (using 'at'):
  # Schedule GI switch for 23:00 today
  echo "\$PWD/$(basename "$0") gi_switch_scheduled" | at 23:00

  # Schedule DB switch for cdb_iacls01 at 22:30 today
  echo "\$PWD/$(basename "$0") db_switch_scheduled cdb_iacls01" | at 22:30

  # Schedule GI UPGRADE switch (gridSetup.sh -upgrade) for 01:00 today
  echo "\$PWD/$(basename "$0") gi_upgrade_upgrade_scheduled" | at 01:00

  # Schedule DB UPGRADE DEPLOY for cdb_iacls01 at 02:00 today
  echo "\$PWD/$(basename "$0") db_upgrade_upgrade_scheduled cdb_iacls01" | at 02:00

Other:
  -h, --help, -help, help          Show this help and exit.

Without arguments, the script starts in interactive menu mode, where each menu
option also shows the phase name and downtime impact.
EOF
}
# ------------------------------------------------------------
# CLI DISPATCH
# ------------------------------------------------------------
# init_srvctl already called at boot
if [[ $# -gt 0 ]]; then
    case "$1" in
        -h|-help|--help|help)
            print_help
            exit 0
            ;;

        stage_software)           stage_software;           exit $? ;;

        gi_precheck)              gi_precheck;              exit 0 ;;
        gi_install)               gi_install;               exit 0 ;;
        gi_switch)                phase_switch_home;        exit 0 ;;
        gi_rollback)              phase_rollback;           exit 0 ;;

        db_precheck)              db_precheck;              exit 0 ;;
        db_install)               db_install;               exit 0 ;;
        db_switch)
            shift
            if [[ $# -lt 1 ]]; then
                echo "Usage: $0 db_switch <DB_UNIQUE_NAME>"
                exit 1
            fi
            db_switch_core "$1"
            exit 0
            ;;
        db_rollback)
            shift
            if [[ $# -lt 1 ]]; then
                echo "Usage: $0 db_rollback <DB_UNIQUE_NAME>"
                exit 1
            fi
            DB_UNIQUE_NAME="$1"
            db_rollback
            exit 0
            ;;
        db_ojvm_only)             db_ojvm_only;             exit 0 ;;

        gi_switch_scheduled)      phase_switch_home;        exit 0 ;;
        db_switch_scheduled)
            shift
            if [[ $# -lt 1 ]]; then
                echo "db_switch_scheduled requires DB_UNIQUE_NAME argument"
                exit 1
            fi
            db_switch_core "$1"
            exit 0
            ;;

        gi_upgrade_precheck)      gi_upgrade_precheck;      exit 0 ;;
        gi_upgrade_install)       gi_upgrade_install;       exit 0 ;;
        gi_upgrade_upgrade)       gi_upgrade_upgrade;       exit 0 ;;
        gi_upgrade_upgrade_scheduled)
            gi_upgrade_upgrade
            exit 0
            ;;

        db_upgrade_precheck)
            shift
            if [[ $# -ge 1 ]]; then
                db_upgrade_precheck "$1"
            else
                db_upgrade_precheck
            fi
            exit 0
            ;;
        db_upgrade_install)       db_upgrade_install;       exit 0 ;;
        db_upgrade_upgrade)       db_upgrade_upgrade;       exit 0 ;;
        db_upgrade_upgrade_scheduled)
            shift
            if [[ $# -lt 1 ]]; then
                echo "db_upgrade_upgrade_scheduled requires DB_UNIQUE_NAME argument"
                exit 1
            fi
            db_upgrade_upgrade_core "$1"
            exit 0
            ;;
        db_upgrade_rollback)      db_upgrade_rollback;      exit 0 ;;

        cluster_precheck)         cluster_precheck;         exit 0 ;;
        cluster_stop_dbs)         cluster_stop_dbs;         exit 0 ;;
        cluster_os_patch)         cluster_os_patch;         exit 0 ;;
        cluster_reboot)           cluster_reboot;           exit 0 ;;
        cluster_postreboot_db)    cluster_postreboot_db;    exit 0 ;;

        setup_patchuser)          setup_patchuser;          exit 0 ;;
        remote_shutdown_apps_then_db)
            if [[ "${ENABLE_SSH_REMOTE_ORCHESTRATION:-false}" == true ]]; then
                remote_shutdown_apps_then_local_db; exit 0
            else
                echo "ERROR: SSH Remote Orchestration is not enabled."
                echo "  Run with: ENABLE_SSH_REMOTE_ORCHESTRATION=true $0 remote_shutdown_apps_then_db"
                exit 1
            fi ;;
        batched_startup)
            if [[ "${ENABLE_SSH_REMOTE_ORCHESTRATION:-false}" == true ]]; then
                batched_startup_db_then_apps; exit 0
            else
                echo "ERROR: SSH Remote Orchestration is not enabled."
                echo "  Run with: ENABLE_SSH_REMOTE_ORCHESTRATION=true $0 batched_startup"
                exit 1
            fi ;;
    esac
fi

# ------------------------------------------------------------
# CONFIGURATION MODE (MANUAL vs AUTOMATED)
# ------------------------------------------------------------
prompt_with_default() {
    local varname="$1"
    local prompt="$2"
    local current="${!varname:-}"
    read -rp "$prompt [$current]: " val
    if [[ -n "${val:-}" ]]; then
        printf -v "$varname" '%s' "$val"
    fi
}

run_manual_config() {
    echo "---------- MANUAL CONFIGURATION ----------"
    prompt_with_default "EMBED_RSP"         "Generate GI/DB response files from embedded templates (true/false)"
    prompt_with_default "ORACLE_USER"       "ORACLE user"
    prompt_with_default "GRID_USER"         "GRID user"
    prompt_with_default "OINSTALL"          "OINSTALL group"
    prompt_with_default "MAIL_TO"           "Mail TO address"
    prompt_with_default "MAIL_FROM"         "Mail FROM address"
    prompt_with_default "OLD_GI_HOME"       "OLD GI home"
    prompt_with_default "NEW_GI_HOME"       "NEW GI home"
    prompt_with_default "OLD_DB_HOME"       "OLD DB home"
    prompt_with_default "NEW_DB_HOME"       "NEW DB home"
    prompt_with_default "GI_BASE_ZIP"       "GI base ZIP"
    prompt_with_default "DB_BASE_ZIP"       "DB base ZIP"
    prompt_with_default "OPATCH_ZIP_DIR"    "OPatch ZIP directory"
    prompt_with_default "OPATCH_ZIP"        "OPatch ZIP file (full path or leave blank to use directory/pattern)"
    prompt_with_default "OPATCH_ZIP_PATTERN" "OPatch ZIP filename pattern"
    prompt_with_default "RU_DIR"            "RU directory"
    prompt_with_default "RU_README"         "RU README path"
    prompt_with_default "GI_RSP"            "GI response file path"
    prompt_with_default "DB_RSP"            "DB response file path"
    prompt_with_default "DB_AUTOCFG"        "DB AutoUpgrade config file path"
    prompt_with_default "APPLY_OJVM_DURING_DB_INSTALL" "Apply OJVM/one-off via runInstaller -applyOneOffs during DB install (true/false)"
    prompt_with_default "OJVM_ZIP_DIR"      "OJVM/one-off ZIP directory for DB install"
    prompt_with_default "OJVM_ZIP_PATTERN"  "OJVM/one-off ZIP filename pattern"
    prompt_with_default "OJVM_ONEOFF_DIR"   "OJVM extracted directory (used for -applyOneOffs)"
    prompt_with_default "APPLY_OJVM_ON_DB_INSTALL" "Apply OJVM via opatch to NEW_DB_HOME after DB install (true/false)"
    prompt_with_default "OJVM_PATCH_DIR"    "OJVM opatch directory (for APPLY_OJVM_ON_DB_INSTALL)"
    prompt_with_default "GI_SCAN_NAME"      "GI SCAN name"
    prompt_with_default "GI_SCAN_PORT"      "GI SCAN port"
    prompt_with_default "GI_CLUSTER_NAME"   "GI cluster name"
    prompt_with_default "GI_CLUSTER_NODES"  "GI clusterNodes tuple"
    prompt_with_default "DB_CLUSTER_NODES"  "DB CLUSTER_NODES"

    # Upgrade-specific
    prompt_with_default "GI_UPGRADE_NEW_HOME"    "GI 23/26ai upgrade home"
    prompt_with_default "GI_UPGRADE_BASE_ZIP"    "GI 23/26ai base ZIP"
    prompt_with_default "DB_UPGRADE_NEW_HOME"    "DB 23/26ai upgrade home"
    prompt_with_default "DB_UPGRADE_BASE_ZIP"    "DB 23/26ai base ZIP"
    prompt_with_default "DB_UPGRADE_JAR"         "AutoUpgrade JAR path for DB upgrade"
    prompt_with_default "GI_USE_SUDO_FOR_ROOT"   "Use passwordless sudo & automatic root.sh for GI upgrade (true/false)"

    echo "------------------------------------------"
    echo "Summary of key paths:"
    echo "  OLD_GI_HOME          = $OLD_GI_HOME"
    echo "  NEW_GI_HOME          = $NEW_GI_HOME"
    echo "  GI_UPGRADE_NEW_HOME  = $GI_UPGRADE_NEW_HOME"
    echo "  OLD_DB_HOME          = $OLD_DB_HOME"
    echo "  NEW_DB_HOME          = $NEW_DB_HOME"
    echo "  DB_UPGRADE_NEW_HOME  = $DB_UPGRADE_NEW_HOME"
    echo "  GI_USE_SUDO_FOR_ROOT = $GI_USE_SUDO_FOR_ROOT"
    echo
    while true; do
        read -rp "Accept this configuration? (y=continue, r=redo manual config, b=go back to mode selection) [y]: " ans
        ans=${ans:-y}
        case "$ans" in
            y|Y)  return 0 ;;
            r|R)  run_manual_config; return 0 ;;
            b|B)  CONFIG_MODE="AUTO"; return 1 ;;
            *)    echo "Please answer y, r, or b." ;;
        esac
    done
}

select_config_mode() {
    while true; do
        clear
        echo "========================================"
        echo " Configuration Mode"
        echo "========================================"
        echo "1) Automated (use defaults in script)"
        echo "2) Manual (prompt for all key variables)"
        echo "========================================"
        read -rp "Select: " cmode
        case "$cmode" in
            1) CONFIG_MODE="AUTO"; return ;;
            2) CONFIG_MODE="MANUAL"
               if run_manual_config; then
                   return
               else
                   continue
               fi ;;
        esac
    done
}

# ------------------------------------------------------------
# MENUS (GI/DB/UPGRADE/CLUSTER)
# ------------------------------------------------------------
gi_menu() {
    while true; do
        clear
        echo "====== GI OPERATIONS (19c patching) ======"
        echo "1) GI Precheck           [gi_precheck]  (Downtime: NO)"
        echo "2) GI Install            [gi_install]   (Downtime: NO)"
        echo "3) GI Switch (immediate) [gi_switch]    (Downtime: YES - GI/cluster restart)"
        echo "4) GI Switch (schedule)  [gi_switch_scheduled] (Downtime: YES - GI/cluster restart)"
        echo "5) List/Cancel scheduled GI/DB switch jobs"
        echo "6) GI Rollback           [gi_rollback]  (Downtime: YES - GI/cluster restart)"
        echo "b) Back"
        read -rp "Select GI option: " gopt
        case "$gopt" in
            1) gi_precheck ;;
            2) gi_install  ;;
            3) phase_switch_home ;;
            4) schedule_gi_switch ;;
            5) list_orchestrator_jobs ;;
            6) phase_rollback ;;
            b|B) break ;;
        esac
        read -rp "Press Enter..." _
    done
}
db_menu() {
    while true; do
        clear
        echo "====== DB OPERATIONS (19c patching) ======"
        echo "1) DB Precheck           [db_precheck]   (Downtime: NO)"
        echo "2) DB Install            [db_install]    (Downtime: NO)"
        echo "3) DB Switch (immediate) [db_switch]     (Downtime: YES - DB outage)"
        echo "4) DB Switch (schedule)  [db_switch_scheduled] (Downtime: YES - DB outage)"
        echo "5) DB OJVM Only          [db_ojvm_only]  (Downtime: NO - opatch on NEW_DB_HOME only)"
        echo "6) List/Cancel scheduled GI/DB switch jobs"
        echo "7) DB Rollback           [db_rollback]   (Downtime: YES - DB outage)"
        echo "b) Back"
        read -rp "Select DB option: " dopt
        case "$dopt" in
            1) db_precheck ;;
            2) db_install  ;;
            3) db_switch   ;;
            4) schedule_db_switch ;;
            5) db_ojvm_only ;;
            6) list_orchestrator_jobs ;;
            7) db_rollback ;;
            b|B) break ;;
        esac
        read -rp "Press Enter..." _
    done
}
gi_upgrade_menu() {
    while true; do
        clear
        echo "====== GI UPGRADE (19c -> 23/26ai) ======"
        echo "1) GI Upgrade Precheck           [gi_upgrade_precheck]           (Downtime: NO)"
        echo "2) GI Upgrade Install            [gi_upgrade_install]            (Downtime: NO)"
        echo "3) GI Upgrade (switch now)       [gi_upgrade_upgrade]            (Downtime: YES - GI restart)"
        echo "4) GI Upgrade (schedule switch)  [gi_upgrade_upgrade_scheduled]  (Downtime: YES - GI restart)"
        echo "   (No GI rollback supported 19c->23ai per Oracle)"
        echo "b) Back"
        read -rp "Select GI UPGRADE option: " gopt
        case "$gopt" in
            1) gi_upgrade_precheck ;;
            2) gi_upgrade_install  ;;
            3) gi_upgrade_upgrade  ;;
            4) schedule_gi_upgrade ;;
            b|B) break ;;
        esac
        read -rp "Press Enter..." _
    done
}
db_upgrade_menu() {
    while true; do
        clear
        echo "====== DB UPGRADE (19c -> 23/26ai) ======"
        echo "1) DB Upgrade Precheck           [db_upgrade_precheck]          (Downtime: NO)"
        echo "2) DB Upgrade Install            [db_upgrade_install]           (Downtime: NO)"
        echo "3) DB Upgrade (deploy now)       [db_upgrade_upgrade]           (Downtime: YES for that DB)"
        echo "4) DB Upgrade (schedule deploy)  [db_upgrade_upgrade_scheduled] (Downtime: YES for that DB)"
        echo "5) DB Upgrade Rollback           [db_upgrade_rollback]          (Downtime: YES; placeholder)"
        echo "b) Back"
        read -rp "Select DB UPGRADE option: " dopt
        case "$dopt" in
            1) db_upgrade_precheck ;;
            2) db_upgrade_install  ;;
            3) db_upgrade_upgrade  ;;
            4) schedule_db_upgrade ;;
            5) db_upgrade_rollback ;;
            b|B) break ;;
        esac
        read -rp "Press Enter..." _
    done
}
upgrade_menu() {
    while true; do
        clear
        echo "====== UPGRADE OPERATIONS (19c -> 23/26ai) ======"
        echo "1) GI Upgrade           (submenu)"
        echo "2) DB Upgrade           (submenu)"
        echo "b) Back"
        read -rp "Select Upgrade option: " uopt
        case "$uopt" in
            1) gi_upgrade_menu ;;
            2) db_upgrade_menu ;;
            b|B) break ;;
        esac
        read -rp "Press Enter..." _
    done
}
cluster_menu() {
    while true; do
        clear
        echo "====== CLUSTER MAINTENANCE (Per-node) ======"
        echo "1) Cluster Precheck         [cluster_precheck]              (Downtime: NO)"
        echo "2) Stop local DBs           [cluster_stop_dbs]              (Downtime: YES - local DBs)"
        echo "3) OS Patch (local node)    [cluster_os_patch]              (Downtime: AS PER PATCH)"
        echo "4) Reboot node              [cluster_reboot]                (Downtime: YES)"
        echo "5) Post-reboot DB start     [cluster_postreboot_db]         (Downtime: NO - brings DBs up)"
        echo "6) Setup patchuser (SSH)    [setup_patchuser]               (Downtime: NO)"
        echo "7) Remote shutdown APPs→DB  [remote_shutdown_apps_then_db]  (Downtime: YES)"
        echo "8) Batched startup (DB+APPs)[batched_startup]               (Downtime: NO)"
        echo "b) Back"
        read -rp "Select CLUSTER option: " copt
        case "$copt" in
            1) cluster_precheck ;;
            2) cluster_stop_dbs ;;
            3) cluster_os_patch ;;
            4) cluster_reboot ;;
            5) cluster_postreboot_db ;;
            6) setup_patchuser ;;
            7)  if [[ "${ENABLE_SSH_REMOTE_ORCHESTRATION:-false}" == true ]]; then
                    remote_shutdown_apps_then_local_db
                else
                    echo "ERROR: SSH Remote Orchestration is not enabled."
                    echo "  export ENABLE_SSH_REMOTE_ORCHESTRATION=true"
                    echo "  Then re-run the script."
                fi ;;
            8)  if [[ "${ENABLE_SSH_REMOTE_ORCHESTRATION:-false}" == true ]]; then
                    batched_startup_db_then_apps
                else
                    echo "ERROR: SSH Remote Orchestration is not enabled."
                    echo "  export ENABLE_SSH_REMOTE_ORCHESTRATION=true"
                    echo "  Then re-run the script."
                fi ;;
            b|B) break ;;
        esac
        read -rp "Press Enter..." _
    done
}

menu_loop() {
    while true; do
        clear
        echo "========================================"
        echo "  GI + DB OOP Patch & Upgrade Orchestrator"
        echo "========================================"
        echo "1) GI Operations (19c patching)"
        echo "2) DB Operations (19c patching)"
        echo "3) Upgrade Operations (19c -> 23/26ai)"
        echo "4) Cluster Maintenance (OS + DB stop/start)"
        echo "5) Software Staging Check  [stage_software] (Downtime: NO)"
        echo "6) Toggle dry-run (current: $DRYRUN)"
        echo "h) Help (-h)"
        echo "q) Quit"
        echo "========================================"
        read -rp "Select: " opt
        case "$opt" in
            1) gi_menu ;;
            2) db_menu ;;
            3) upgrade_menu ;;
            4) cluster_menu ;;
            5) stage_software; read -rp "Press Enter..." _ ;;
            6) DRYRUN=$([[ "$DRYRUN" == true ]] && echo false || echo true) ;;
            h|H) print_help; read -rp "Press Enter..." _ ;;
            q|Q) exit 0 ;;
        esac
    done
}

# ------------------------------------------------------------
# INTERACTIVE ENTRY POINT
# ------------------------------------------------------------
select_config_mode
menu_loop
# ============================================================
# 🔼 END OF YOUR SCRIPT
# ============================================================