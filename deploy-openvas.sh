#!/bin/bash
# =============================================================================
# Greenbone Community Edition (OpenVAS) — Full Deployment Script
# =============================================================================
# Lessons learned from production deployment on Debian 11 (Hyper-V):
#
#  1. Docker MTU must be 1450 on Hyper-V (1500 causes unexpected EOF on pulls)
#  2. registry.community.greenbone.net has an HTTP/2 CDN bug on specific blobs
#     — ospd-openvas:stable must be pulled via a pinned amd64 tag and retagged
#  3. Large images need per-image retry loops (network drops mid-stream)
#  4. cert-bund-data can be transiently unhealthy on first start, breaking the
#     dependency chain — a second `docker compose up -d` always fixes it
#  5. Port 9392 is plain HTTP redirecting to HTTPS 443 — always use https://host
#  6. ConnectWise Control has a broken dependency (java5-runtime) that blocks apt
#  7. Port binding changes require container recreation, not just restart
#
# Usage:  sudo ./deploy-openvas.sh
#         ./deploy-openvas.sh     (will re-exec with sudo automatically)
#
# Environment overrides:
#   ADMIN_PASSWORD          OpenVAS web UI admin password (default: Pr04ct1v3)
#   CURRENT_ADMIN_PASSWORD  Current password if already changed from default
#   SMB_CREDENTIAL_PASSWORD Password for scan credentials on reimport (no default —
#                           if unset, credentials are created with placeholder password
#                           and must be updated in the web UI after deployment)
# =============================================================================

set -euo pipefail

# --- Re-exec as root if not already ------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo "This script requires root privileges. Enter your password to continue:"
    exec sudo -E bash "$0" "$@"
fi

# --- Configuration -----------------------------------------------------------
# Detect the invoking user so COMPOSE_DIR lands in the right home regardless
# of whether the script was called as `sudo ./deploy` or directly as root.
DEPLOY_USER="${SUDO_USER:-${USER:-sysadmin}}"
DEPLOY_HOME=$(getent passwd "$DEPLOY_USER" | cut -d: -f6)
if [ -z "$DEPLOY_HOME" ]; then
    echo "ERROR: Cannot determine home directory for user '$DEPLOY_USER'. Aborting." >&2
    exit 1
fi

COMPOSE_DIR="${DEPLOY_HOME}/greenbone-community-container"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"
COMPOSE_URL="https://greenbone.github.io/docs/latest/_static/docker-compose.yml"
MAINTAIN_SCRIPT="/usr/local/bin/openvas-maintain.sh"
BACKUP_SCRIPT="/usr/local/bin/openvas-backup.sh"
LOG_FILE="/var/log/openvas-deploy.log"
DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
SCAN_CONFIG_BACKUP="/var/backups/openvas/scan-config-backup.json"

# SSL certificate identity — override before running if deploying elsewhere
DEPLOY_HOSTNAME="${DEPLOY_HOSTNAME:-$(hostname)}"
DEPLOY_ORG="${DEPLOY_ORG:-$(hostname)}"

# Default passwords — override via environment variable before running
ADMIN_PASSWORD="${ADMIN_PASSWORD:-Pr04ct1v3}"
# Current password (used to export scan config before teardown).
# Set this if you previously changed the admin password from the default.
CURRENT_ADMIN_PASSWORD="${CURRENT_ADMIN_PASSWORD:-${ADMIN_PASSWORD}}"
# SMB credential password for scan config reimport.
# Set this before running if you have an existing scan configuration to restore.
# If not set, credentials are created with a placeholder password — update them
# in the web UI after deployment (Configuration → Credentials).
# Example: SMB_CREDENTIAL_PASSWORD='YourPass' sudo -E bash deploy-openvas.sh
SMB_CREDENTIAL_PASSWORD="${SMB_CREDENTIAL_PASSWORD:-}"

# ospd-openvas:stable CDN blob is broken (TLS close_notify, no body).
# Update this tag when a newer working stable tag becomes available.
OSPD_FALLBACK_TAG="v22.9.1-amd64"

MAX_PULL_ATTEMPTS=5
PULL_RETRY_WAIT=5
STARTUP_WAIT=60       # seconds after first `up -d` before health check
SECOND_UP_WAIT=90     # seconds after second `up -d` before final check

# --- Helpers -----------------------------------------------------------------
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'

log()     { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓ $*${NC}" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ! $*${NC}" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[$(date '+%H:%M:%S')] ✗ $*${NC}" | tee -a "$LOG_FILE"; exit 1; }
section() {
    echo -e "\n${CYAN}══════════════════════════════════════${NC}"
    log "$*"
    echo -e "${CYAN}══════════════════════════════════════${NC}"
}

compose() { docker compose -f "$COMPOSE_FILE" "$@"; }

parse_ndjson() {
    python3 -W ignore -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if line:
        try: print(json.dumps(json.loads(line)))
        except Exception: pass
" 2>/dev/null
}

# --- Pin working directory to /tmp -------------------------------------------
# Step 1 deletes $COMPOSE_DIR. If the invoking shell's cwd is inside that
# directory (e.g. when run from the greenbone-community-container folder),
# docker compose will fail with "getwd: no such file or directory" on every
# subsequent call because the process's cwd inode is gone. Pinning to /tmp
# ensures cwd is always valid for the lifetime of the script.
cd /tmp

# --- Init log file -----------------------------------------------------------
touch "$LOG_FILE"
chmod 640 "$LOG_FILE"

# --- Preflight ---------------------------------------------------------------
section "Preflight checks"

if ! grep -qi "debian\|ubuntu" /etc/os-release 2>/dev/null; then
    warn "Tested on Debian/Ubuntu only. Proceeding with caution."
fi

log "Deploying as root; invoking user: $DEPLOY_USER (home: $DEPLOY_HOME)"
log "Compose directory: $COMPOSE_DIR"
success "Preflight OK"

# --- STEP 1: Remove conflicts, export scan config, clean up ------------------
section "STEP 1: Removing conflicts and old installations"

# 1a. Remove ConnectWise Control if present.
#     It depends on java5-runtime (doesn't exist), which blocks all apt operations.
if dpkg -l 'connectwisecontrol-*' 2>/dev/null | grep -q "^ii"; then
    CW_PKG=$(dpkg -l 'connectwisecontrol-*' 2>/dev/null | awk '/^ii/{print $2}' | head -1)
    log "Removing broken ConnectWise Control package: $CW_PKG"
    dpkg --remove "$CW_PKG" 2>&1 | tee -a "$LOG_FILE" || true
    success "ConnectWise Control removed — apt unblocked"
else
    success "ConnectWise Control not present — skipping"
fi

# 1b. Export scan config (targets, tasks, schedules, credentials) before wipe.
#     Saved to $SCAN_CONFIG_BACKUP and reimported at end of deploy.
mkdir -p /var/backups/openvas
if docker info &>/dev/null && [ -f "$COMPOSE_FILE" ]; then
    GVMD_RUNNING=$(docker compose -f "$COMPOSE_FILE" ps --format json 2>/dev/null \
        | parse_ndjson | python3 -c "
import json,sys
for l in sys.stdin:
    s=json.loads(l)
    if s.get('Service')=='gvmd' and s.get('State','').lower()=='running':
        print('yes'); break
" 2>/dev/null || true)

    if [ "$GVMD_RUNNING" = "yes" ]; then
        # Test authentication before attempting export.
        # If CURRENT_ADMIN_PASSWORD is wrong (password was changed), warn clearly
        # rather than silently failing inside the Python exporter.
        AUTH_TEST=$(docker compose -f "$COMPOSE_FILE" run --rm gvm-tools \
            gvm-cli --gmp-username admin --gmp-password "$CURRENT_ADMIN_PASSWORD" \
            socket --socketpath /run/gvmd/gvmd.sock --xml "<get_version/>" 2>/dev/null || true)
        if ! echo "$AUTH_TEST" | grep -q 'status="200"'; then
            warn "gvmd auth failed — CURRENT_ADMIN_PASSWORD may be wrong."
            warn "Set CURRENT_ADMIN_PASSWORD=<existing_password> to export scan config."
            warn "Skipping scan config export — continuing with fresh deployment."
        else
        log "gvmd is running and authenticated — exporting scan configuration..."
        export GVM_COMPOSE_FILE="$COMPOSE_FILE"
        export GVM_ADMIN_PASS="$CURRENT_ADMIN_PASSWORD"
        export GVM_CONFIG_OUTPUT="$SCAN_CONFIG_BACKUP"

        python3 << 'EXPORT_EOF' 2>&1 | tee -a "$LOG_FILE" || true
import subprocess, json, xml.etree.ElementTree as ET, os, sys

CF = os.environ['GVM_COMPOSE_FILE']
AP = os.environ['GVM_ADMIN_PASS']
OUT = os.environ['GVM_CONFIG_OUTPUT']

def gvm(cmd):
    r = subprocess.run(
        ['docker','compose','-f',CF,'run','--rm','gvm-tools',
         'gvm-cli','--gmp-username','admin','--gmp-password',AP,
         'socket','--socketpath','/run/gvmd/gvmd.sock','--xml',cmd],
        capture_output=True, text=True, timeout=120)
    return r.stdout.strip()

def xt(e, tag, d=''):
    n = e.find(tag)
    return (n.text or '').strip() if n is not None else d

try:
    cr = ET.fromstring(gvm('<get_credentials/>'))
    cid2nm = {}; creds = []
    for c in cr.findall('credential'):
        cid = c.get('id',''); nm = xt(c,'name')
        cid2nm[cid] = nm
        creds.append({'name':nm,'type':xt(c,'type'),'login':xt(c,'login'),'password':'__NEED_PASSWORD__'})

    pl = ET.fromstring(gvm('<get_port_lists/>'))
    plid2nm = {p.get('id',''): xt(p,'name') for p in pl.findall('port_list')}

    tr = ET.fromstring(gvm('<get_targets/>'))
    tid2nm = {}; targets = []
    for t in tr.findall('target'):
        tid = t.get('id',''); nm = xt(t,'name'); tid2nm[tid] = nm
        smb = t.find('smb_credential')
        smb_nm = cid2nm.get(smb.get('id','') if smb is not None else '', '')
        ple = t.find('port_list')
        pl_nm = plid2nm.get(ple.get('id','') if ple is not None else '', '')
        targets.append({'name':nm,'hosts':xt(t,'hosts'),'exclude_hosts':xt(t,'exclude_hosts'),
                        'port_list_name':pl_nm,'smb_credential_name':smb_nm,
                        'alive_tests':xt(t,'alive_tests')})

    sr = ET.fromstring(gvm('<get_schedules/>'))
    sid2nm = {}; scheds = []
    for s in sr.findall('schedule'):
        sid = s.get('id',''); nm = xt(s,'name'); sid2nm[sid] = nm
        scheds.append({'name':nm,'icalendar':xt(s,'icalendar'),'timezone':xt(s,'timezone')})

    tk = ET.fromstring(gvm('<get_tasks/>'))
    tasks = []
    for t in tk.findall('task'):
        tgt = t.find('target'); sch = t.find('schedule')
        cfg = t.find('config'); scn = t.find('scanner')
        tasks.append({
            'name': xt(t,'name'),
            'target_name': tid2nm.get(tgt.get('id','') if tgt is not None else '',''),
            'schedule_name': sid2nm.get(sch.get('id','') if sch is not None else '',''),
            'config_name': xt(cfg,'name') if cfg is not None else '',
            'scanner_name': xt(scn,'name') if scn is not None else '',
        })

    result = {'credentials':creds,'targets':targets,'schedules':scheds,'tasks':tasks}
    with open(OUT,'w') as f: json.dump(result, f, indent=2)
    print(f"Scan config exported: {len(creds)} creds, {len(targets)} targets, "
          f"{len(scheds)} schedules, {len(tasks)} tasks → {OUT}")
except Exception as e:
    print(f"WARNING: scan config export failed: {e}"); sys.exit(0)
EXPORT_EOF

        if [ -s "$SCAN_CONFIG_BACKUP" ]; then
            success "Scan configuration backed up to $SCAN_CONFIG_BACKUP"
        else
            warn "Scan config export produced no output — will skip reimport"
        fi
        fi  # end auth-ok block
    else
        warn "gvmd not running — no scan config to export"
    fi
else
    log "Docker/compose not available — no scan config to export"
fi

# 1c. Tear down existing Greenbone stack and remove all related resources.
if docker info &>/dev/null; then
    if [ -f "$COMPOSE_FILE" ]; then
        log "Bringing down existing Greenbone compose stack (--volumes)..."
        docker compose -f "$COMPOSE_FILE" down --volumes --remove-orphans >> "$LOG_FILE" 2>&1 || true
        success "Existing stack removed"
    fi

    OLD_CONTAINERS=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -iE "openvas|greenbone" || true)
    if [ -n "$OLD_CONTAINERS" ]; then
        log "Removing stray containers: $(echo "$OLD_CONTAINERS" | tr '\n' ' ')"
        echo "$OLD_CONTAINERS" | xargs docker rm -f >> "$LOG_FILE" 2>&1 || true
    fi

    OLD_IMAGES=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -iE "greenbone|openvas" || true)
    if [ -n "$OLD_IMAGES" ]; then
        log "Removing old images..."
        echo "$OLD_IMAGES" | xargs docker rmi -f >> "$LOG_FILE" 2>&1 || true
    fi

    OLD_VOLUMES=$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -iE "greenbone|openvas" || true)
    if [ -n "$OLD_VOLUMES" ]; then
        log "Removing old volumes: $(echo "$OLD_VOLUMES" | tr '\n' ' ')"
        echo "$OLD_VOLUMES" | xargs docker volume rm >> "$LOG_FILE" 2>&1 || true
    fi

    success "Old OpenVAS/Greenbone resources cleaned up"
else
    log "Docker not installed yet — skipping container/image cleanup"
fi

if [ -d "$COMPOSE_DIR" ]; then
    # Boundary check: refuse to rm -rf if path resolves outside DEPLOY_HOME
    # (guards against DEPLOY_HOME being empty or resolving unexpectedly)
    if [ -z "$COMPOSE_DIR" ] || [ "$COMPOSE_DIR" = "/" ] || \
       [[ "$COMPOSE_DIR" != "${DEPLOY_HOME}/"* ]]; then
        warn "COMPOSE_DIR '$COMPOSE_DIR' is outside DEPLOY_HOME — skipping rm -rf"
    else
        log "Removing old compose directory: $COMPOSE_DIR"
        rm -rf "$COMPOSE_DIR"
    fi
fi
success "Step 1 complete"

# --- STEP 2: System update ---------------------------------------------------
section "STEP 2: System update"

log "Running apt-get update..."
apt-get update -qq >> "$LOG_FILE" 2>&1 || warn "apt-get update returned warnings"
log "Running apt-get upgrade..."
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    >> "$LOG_FILE" 2>&1 || warn "apt-get upgrade returned warnings"
apt-get autoremove -y >> "$LOG_FILE" 2>&1 || true
success "System packages up to date"

# --- STEP 3: Docker install --------------------------------------------------
section "STEP 3: Checking Docker installation"

if ! command -v docker &>/dev/null; then
    log "Docker not found — installing..."
    apt-get install -y ca-certificates curl gnupg lsb-release >> "$LOG_FILE" 2>&1

    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
        | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq >> "$LOG_FILE" 2>&1
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin >> "$LOG_FILE" 2>&1
    success "Docker installed"
else
    success "Docker already installed: $(docker --version)"
fi

if ! docker compose version &>/dev/null; then
    error "docker compose (v2 plugin) not found. Install docker-compose-plugin."
fi

# Add invoking user to docker group (effective after re-login)
if ! groups "$DEPLOY_USER" | grep -q docker; then
    usermod -aG docker "$DEPLOY_USER"
    success "Added $DEPLOY_USER to docker group (effective after re-login)"
fi

# --- STEP 4: Docker daemon configuration (MTU) -------------------------------
section "STEP 4: Configuring Docker daemon"

# Detect hypervisor to set correct MTU.
# Hyper-V: 1450 (default 1500 causes packet fragmentation / unexpected EOF)
# VMware/bare metal: 1500 (standard, no fragmentation issues)
detect_hypervisor() {
    # Hyper-V
    if [ -d /sys/bus/vmbus ] 2>/dev/null || \
       grep -qi "microsoft\|hyper-v" /sys/class/dmi/id/sys_vendor 2>/dev/null || \
       grep -qi "hyper-v\|hyperv" /proc/version 2>/dev/null; then
        echo "hyperv"; return
    fi
    # VMware
    if grep -qi "vmware" /sys/class/dmi/id/sys_vendor 2>/dev/null || \
       grep -qi "vmware" /proc/version 2>/dev/null; then
        echo "vmware"; return
    fi
    echo "bare"
}

HYPERVISOR=$(detect_hypervisor)
log "Detected hypervisor: $HYPERVISOR"

case "$HYPERVISOR" in
    hyperv)  TARGET_MTU=1450 ;;
    vmware)  TARGET_MTU=1500 ;;
    *)       TARGET_MTU=1500 ;;
esac

CURRENT_MTU=$(python3 -c "import json; d=json.load(open('$DOCKER_DAEMON_JSON')); print(d.get('mtu',1500))" 2>/dev/null || echo "1500")

if [ "$CURRENT_MTU" != "$TARGET_MTU" ]; then
    log "Setting Docker MTU to $TARGET_MTU ($HYPERVISOR)"
    if [ -f "$DOCKER_DAEMON_JSON" ]; then
        python3 -c "
import json
with open('$DOCKER_DAEMON_JSON') as f: d = json.load(f)
d['mtu'] = $TARGET_MTU
with open('$DOCKER_DAEMON_JSON', 'w') as f: json.dump(d, f, indent=2)
"
    else
        echo "{\"mtu\": $TARGET_MTU}" > "$DOCKER_DAEMON_JSON"
    fi
    systemctl restart docker
    sleep 3
    success "Docker MTU set to $TARGET_MTU and daemon restarted"
else
    success "Docker MTU already $TARGET_MTU — no change needed"
fi

# --- Download docker-compose.yml ---------------------------------------------
section "Downloading docker-compose file"

mkdir -p "$COMPOSE_DIR"
log "Fetching $COMPOSE_URL"
curl -fsSL -o "$COMPOSE_FILE" "$COMPOSE_URL"
success "docker-compose.yml saved to $COMPOSE_FILE"

# --- Pull images with retry --------------------------------------------------
section "Pulling container images"

pull_image_with_retry() {
    local image="$1"
    local attempt
    for attempt in $(seq 1 $MAX_PULL_ATTEMPTS); do
        log "  Pulling $image (attempt $attempt/$MAX_PULL_ATTEMPTS)..."
        if docker pull "$image" >> "$LOG_FILE" 2>&1; then
            success "  $image pulled"
            return 0
        fi
        warn "  Pull failed (attempt $attempt)"
        sleep $PULL_RETRY_WAIT
    done
    return 1
}

IMAGES=$(grep '^\s*image:' "$COMPOSE_FILE" | awk '{print $2}' | sort -u)
PULL_FAILED=""

for img in $IMAGES; do
    [[ "$img" != *:* ]] && img="${img}:latest"

    if [[ "$img" == *"ospd-openvas:stable"* ]]; then
        BASE_IMG="${img%%:*}"
        FALLBACK="${BASE_IMG}:${OSPD_FALLBACK_TAG}"
        log "ospd-openvas:stable has known CDN blob issue — using $FALLBACK"
        if pull_image_with_retry "$FALLBACK"; then
            docker tag "$FALLBACK" "$img"
            success "  Tagged $FALLBACK → $img"
        else
            PULL_FAILED="$PULL_FAILED $img"
        fi
        continue
    fi

    pull_image_with_retry "$img" || PULL_FAILED="$PULL_FAILED $img"
done

if [ -n "$PULL_FAILED" ]; then
    warn "Failed to pull (after $MAX_PULL_ATTEMPTS attempts):$PULL_FAILED"
    warn "Continuing — stack may start if images were previously cached"
fi
success "Image pull phase complete"

# --- Start containers (pass 1) -----------------------------------------------
section "Starting containers (pass 1 of 2)"

log "Running docker compose up -d..."
compose up -d >> "$LOG_FILE" 2>&1 || true
# Non-zero exit is expected: cert-bund-data is transiently unhealthy on first
# start, causing downstream services to stay in "created". Pass 2 fixes this.

log "Waiting ${STARTUP_WAIT}s for initial startup..."
sleep "$STARTUP_WAIT"

log "Container state after pass 1:"
compose ps -a 2>/dev/null | tee -a "$LOG_FILE" || true

# --- Start containers (pass 2 — dependency chain fix) ------------------------
section "Starting containers (pass 2 — dependency chain fix)"

log "Running docker compose up -d (pass 2)..."
compose up -d >> "$LOG_FILE" 2>&1 || true

log "Waiting ${SECOND_UP_WAIT}s for services to stabilise..."
sleep "$SECOND_UP_WAIT"

# --- Verify deployment -------------------------------------------------------
section "Verifying deployment"

RUNNING=$(compose ps --format json 2>/dev/null | parse_ndjson | python3 -W ignore -c "
import json, sys
total = running = 0
for line in sys.stdin:
    s = json.loads(line)
    total += 1
    if s.get('State','').lower() == 'running': running += 1
print(f'{running}/{total}')
" 2>/dev/null)
log "Services running: $RUNNING"

UNHEALTHY=$(compose ps --format json 2>/dev/null | parse_ndjson | python3 -W ignore -c "
import json, sys
for line in sys.stdin:
    s = json.loads(line)
    if s.get('Health','').lower() == 'unhealthy': print(s.get('Service',''))
" 2>/dev/null || true)

if [ -n "$UNHEALTHY" ]; then
    warn "Unhealthy services: $UNHEALTHY — attempting restart..."
    for svc in $UNHEALTHY; do
        compose restart "$svc" >> "$LOG_FILE" 2>&1
    done
    sleep 30
fi

compose ps 2>/dev/null | tee -a "$LOG_FILE"
success "Container stack is up"

# --- Install maintenance script ----------------------------------------------
section "Installing maintenance script"

# Write with placeholder for compose file path (single-quoted heredoc won't expand vars)
tee "$MAINTAIN_SCRIPT" > /dev/null << 'MAINTAIN_EOF'
#!/bin/bash
# OpenVAS maintenance — modes: health | update
COMPOSE_FILE="__COMPOSE_FILE__"
LOG_FILE="/var/log/openvas-maintain.log"
MAX_RESTART_ATTEMPTS=3
RESTART_WAIT=30

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
compose() { docker compose -f "$COMPOSE_FILE" "$@"; }

parse_ndjson() {
    python3 -W ignore -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if line:
        try: print(json.dumps(json.loads(line)))
        except Exception: pass
" 2>/dev/null
}

get_services_by_state() {
    local _state="$1"
    compose ps -a --format json 2>/dev/null | parse_ndjson | _GVM_STATE="$_state" python3 -W ignore -c "
import json, sys, os
state = os.environ.get('_GVM_STATE','')
for line in sys.stdin:
    s = json.loads(line.strip())
    if s.get('State','').lower() == state:
        print(s.get('Service',''))
" 2>/dev/null
}

get_unhealthy() {
    compose ps --format json 2>/dev/null | parse_ndjson | python3 -W ignore -c "
import json, sys
for line in sys.stdin:
    s = json.loads(line.strip())
    if s.get('Health','').lower() == 'unhealthy': print(s.get('Service',''))
" 2>/dev/null
}

get_health() {
    local _svc="$1"
    compose ps --format json 2>/dev/null | parse_ndjson | _GVM_SVC="$_svc" python3 -W ignore -c "
import json, sys, os
svc = os.environ.get('_GVM_SVC','')
for line in sys.stdin:
    s = json.loads(line.strip())
    if s.get('Service') == svc:
        h = s.get('Health','').strip()
        print(h if h else s.get('State','unknown')); sys.exit(0)
print('unknown')
" 2>/dev/null
}

do_health() {
    log "=== Health check started ==="
    STOPPED=""
    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        EXIT_CODE=$(compose ps -a --format json 2>/dev/null | parse_ndjson | _GVM_SVC="$svc" python3 -W ignore -c "
import json, sys, os
svc = os.environ.get('_GVM_SVC','')
for line in sys.stdin:
    s = json.loads(line.strip())
    if s.get('Service') == svc: print(s.get('ExitCode',-1)); break
" 2>/dev/null)
        [ "$EXIT_CODE" != "0" ] && STOPPED="$STOPPED $svc"
    done < <({ get_services_by_state exited; get_services_by_state created; } | sort -u)

    if [ -n "$STOPPED" ]; then
        log "Stopped services:$STOPPED — bringing up"
        compose up -d >> "$LOG_FILE" 2>&1
        sleep "$RESTART_WAIT"
    fi

    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        log "Service '$svc' unhealthy — restarting (1/$MAX_RESTART_ATTEMPTS)"
        compose restart "$svc" >> "$LOG_FILE" 2>&1
        sleep "$RESTART_WAIT"
        RECOVERED=false
        for attempt in $(seq 2 $MAX_RESTART_ATTEMPTS); do
            HEALTH=$(get_health "$svc")
            if [ "$HEALTH" = "healthy" ] || [ "$HEALTH" = "running" ]; then
                log "Service '$svc' recovered"; RECOVERED=true; break
            fi
            [ "$attempt" -lt "$MAX_RESTART_ATTEMPTS" ] && \
                compose restart "$svc" >> "$LOG_FILE" 2>&1 && sleep "$RESTART_WAIT"
        done
        [ "$RECOVERED" = "false" ] && log "ERROR: '$svc' failed to recover after $MAX_RESTART_ATTEMPTS attempts"
    done < <(get_unhealthy)

    COUNTS=$(compose ps --format json 2>/dev/null | parse_ndjson | python3 -W ignore -c "
import json, sys
total=running=0
for line in sys.stdin:
    s=json.loads(line.strip()); total+=1
    running += (1 if s.get('State','').lower()=='running' else 0)
print(f'{running}/{total}')
" 2>/dev/null)
    log "Health check complete: $COUNTS running"
    log "=== Health check done ==="
}

do_update() {
    log "=== Update started ==="
    compose pull >> "$LOG_FILE" 2>&1 || log "WARNING: pull returned non-zero"
    compose up -d --remove-orphans >> "$LOG_FILE" 2>&1
    sleep 30
    do_health
    log "=== Update done ==="
}

# Acquire exclusive lock to prevent concurrent cron invocations from overlapping
# (health runs every 5 min; update can take several minutes)
LOCK_FILE="/var/run/openvas-maintain.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "Another instance is running — skipping this tick"
    exit 0
fi

case "${1:-health}" in
    health) do_health ;;
    update) do_update ;;
    *) echo "Usage: $0 {health|update}"; exit 1 ;;
esac
MAINTAIN_EOF

# Substitute actual compose file path into the script
sed -i "s|__COMPOSE_FILE__|${COMPOSE_FILE}|g" "$MAINTAIN_SCRIPT"
chmod +x "$MAINTAIN_SCRIPT"
success "Maintenance script installed: $MAINTAIN_SCRIPT"

tee /etc/logrotate.d/openvas-maintain > /dev/null << 'EOF'
/var/log/openvas-maintain.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 0640 root root
}
EOF

tee /etc/cron.d/openvas-maintain > /dev/null << 'EOF'
# OpenVAS health check every 5 minutes
*/5 * * * * root /usr/local/bin/openvas-maintain.sh health
# OpenVAS image update daily at 2am
0 2 * * * root /usr/local/bin/openvas-maintain.sh update
EOF
chmod 644 /etc/cron.d/openvas-maintain
success "Maintenance cron installed (health: every 5min, update: daily 2am)"

# --- Set admin password ------------------------------------------------------
section "Setting admin password"

log "Using admin password from ADMIN_PASSWORD (default: Pr04ct1v3)."
log "Override before running: ADMIN_PASSWORD=newpass sudo ./deploy-openvas.sh"
log "Or change after deploy via: docker compose exec -u gvmd gvmd gvmd --user=admin --new-password='newpass'"

log "Waiting for gvmd to accept connections (up to 15 minutes — gvmd loads VTs before accepting password changes)..."
PW_SET=false
for i in $(seq 1 90); do
    if compose exec -u gvmd gvmd gvmd --user=admin --new-password="$ADMIN_PASSWORD" >> "$LOG_FILE" 2>&1; then
        success "Admin password set"
        PW_SET=true; break
    fi
    [ "$i" -lt 90 ] && sleep 10
done
if [ "$PW_SET" = "false" ]; then
    warn "Could not set admin password automatically — set it manually (command above)"
fi

# Verify GMP socket accepts the admin password before proceeding.
# gvmd --new-password succeeds via internal API but GMP socket may still be
# initializing — this probe confirms gvm-cli can authenticate successfully.
log "Verifying GMP socket authentication..."
GMP_AUTH_OK=false
for i in $(seq 1 36); do
    resp=$(compose run --rm gvm-tools gvm-cli \
        --gmp-username admin --gmp-password "$ADMIN_PASSWORD" \
        socket --socketpath /run/gvmd/gvmd.sock \
        --xml '<get_version/>' 2>/dev/null || true)
    if echo "$resp" | grep -q 'status="200"'; then
        success "GMP socket authenticated"
        GMP_AUTH_OK=true; break
    fi
    [ "$i" -lt 36 ] && sleep 10
done
if [ "$GMP_AUTH_OK" = "false" ]; then
    warn "GMP socket did not authenticate within 6 minutes — reimport may fail"
fi

# --- System auto-update (apt) ------------------------------------------------
section "Installing system auto-update"

tee /usr/local/bin/auto-update.sh > /dev/null << 'EOF'
#!/bin/bash
# Automatic system update — runs daily at 3am, no reboot.
LOG_FILE="/var/log/auto-update.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
log "=== Auto-update started ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >> "$LOG_FILE" 2>&1
apt-get upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    >> "$LOG_FILE" 2>&1
apt-get autoremove -y >> "$LOG_FILE" 2>&1
apt-get autoclean -y >> "$LOG_FILE" 2>&1
if [ -f /var/run/reboot-required ]; then
    PKGS="(unknown)"
    [ -f /var/run/reboot-required.pkgs ] && PKGS=$(tr '\n' ' ' < /var/run/reboot-required.pkgs)
    log "NOTICE: Reboot required for: ${PKGS}"
else
    log "No reboot required."
fi
log "=== Auto-update done ==="
EOF
chmod 755 /usr/local/bin/auto-update.sh

tee /etc/cron.d/auto-update > /dev/null << 'EOF'
# System apt upgrade — daily at 3am
0 3 * * * root /usr/local/bin/auto-update.sh
EOF
chmod 644 /etc/cron.d/auto-update

tee /etc/logrotate.d/auto-update > /dev/null << 'EOF'
/var/log/auto-update.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
EOF

tee /etc/profile.d/99-reboot-required.sh > /dev/null << 'EOF'
#!/bin/bash
if [ -f /var/run/reboot-required ]; then
    PKGS=""
    [ -f /var/run/reboot-required.pkgs ] && PKGS=$(tr '\n' ' ' < /var/run/reboot-required.pkgs)
    echo ""
    echo "  +---------------------------------------------------+"
    echo "  |        *** SYSTEM REBOOT REQUIRED ***             |"
    echo "  |                                                   |"
    echo "  |  A recent update requires a reboot to apply.     |"
    [ -n "$PKGS" ] && printf "  |  Packages: %-37s|\n" "$PKGS"
    echo "  |                                                   |"
    echo "  |  When ready, run: sudo reboot                    |"
    echo "  +---------------------------------------------------+"
    echo ""
fi
EOF
chmod 755 /etc/profile.d/99-reboot-required.sh
success "System auto-update configured (daily 3am, login notification if reboot required)"

# --- Swap space --------------------------------------------------------------
section "Configuring swap space"

# Get total swap in bytes for a reliable numeric comparison
CURRENT_SWAP_BYTES=$(swapon --show=SIZE --noheadings --bytes 2>/dev/null | awk '{sum+=$1} END{printf "%d\n", sum}')
FOUR_GB=4294967296

if [ "$CURRENT_SWAP_BYTES" -lt "$FOUR_GB" ] && [ ! -f /swapfile ]; then
    log "Adding 4 GB swapfile..."
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >> "$LOG_FILE" 2>&1
    swapon /swapfile
    if ! grep -q '/swapfile' /etc/fstab; then
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi
    success "4 GB swapfile created and enabled"
else
    success "Sufficient swap already present ($(( CURRENT_SWAP_BYTES / 1073741824 ))GB) — skipping"
fi

# --- Expose web UI on all interfaces -----------------------------------------
section "Configuring web UI network access"

# Change nginx port binding from 127.0.0.1:443 to 0.0.0.0:443.
# Port binding changes require container recreation — use `up -d`, not `restart`.
if grep -Fq '127.0.0.1:443:443' "$COMPOSE_FILE"; then
    sed -i 's/127\.0\.0\.1:443:443/0.0.0.0:443:443/' "$COMPOSE_FILE"
    success "nginx port binding updated to 0.0.0.0:443"
    log "Recreating nginx container to apply port binding change..."
    compose up -d nginx >> "$LOG_FILE" 2>&1
    success "nginx recreated with new port binding"
else
    success "nginx already bound to 0.0.0.0:443"
fi

# --- SSL certificate with SAN ------------------------------------------------
section "Generating SSL certificate with SAN"

CERT_DIR=$(docker volume inspect greenbone-community-edition_nginx_certificates_vol \
    --format '{{.Mountpoint}}' 2>/dev/null || true)
HOST_IP=$(hostname -I | awk '{print $1}')

if [ -d "$CERT_DIR" ]; then
    log "Generating self-signed cert: CN=${DEPLOY_HOSTNAME}, SAN: $HOST_IP, 127.0.0.1, localhost"
    [ -f "${CERT_DIR}/server.cert.pem" ] && cp "${CERT_DIR}/server.cert.pem" "${CERT_DIR}/server.cert.pem.bak"
    [ -f "${CERT_DIR}/server.key" ]      && cp "${CERT_DIR}/server.key"      "${CERT_DIR}/server.key.bak"

    openssl req -x509 -nodes -newkey rsa:4096 \
        -keyout "${CERT_DIR}/server.key" \
        -out    "${CERT_DIR}/server.cert.pem" \
        -days 825 \
        -subj "/CN=${DEPLOY_HOSTNAME}/O=${DEPLOY_ORG}/C=US" \
        -addext "subjectAltName=IP:${HOST_IP},IP:127.0.0.1,DNS:localhost,DNS:${DEPLOY_HOSTNAME}" \
        >> "$LOG_FILE" 2>&1

    # Verify the generated key and cert are a matched pair (catches partial-write failures)
    CERT_MOD=$(openssl x509 -noout -modulus -in "${CERT_DIR}/server.cert.pem" 2>/dev/null | md5sum)
    KEY_MOD=$(openssl rsa  -noout -modulus -in "${CERT_DIR}/server.key"       2>/dev/null | md5sum)
    if [ "$CERT_MOD" != "$KEY_MOD" ] || [ -z "$CERT_MOD" ]; then
        warn "SSL cert/key mismatch detected — restoring backup copies"
        [ -f "${CERT_DIR}/server.cert.pem.bak" ] && cp "${CERT_DIR}/server.cert.pem.bak" "${CERT_DIR}/server.cert.pem"
        [ -f "${CERT_DIR}/server.key.bak" ]      && cp "${CERT_DIR}/server.key.bak"      "${CERT_DIR}/server.key"
    else
        # SSL cert is on a volume — nginx re-reads it on restart (no recreation needed)
        compose restart nginx >> "$LOG_FILE" 2>&1
        EXPIRY=$(openssl x509 -in "${CERT_DIR}/server.cert.pem" -noout -enddate 2>/dev/null | cut -d= -f2)
        success "SSL cert generated (expires: $EXPIRY) — nginx restarted"
    fi
else
    warn "nginx certificates volume not found — skipping SSL cert generation"
    warn "Run manually after first startup: see DEPLOYMENT_NOTES.txt section 3"
fi

# --- UFW firewall ------------------------------------------------------------
section "Configuring firewall (UFW)"

if ! command -v ufw &>/dev/null; then
    log "ufw not found — installing..."
    apt-get install -y --no-install-recommends ufw >> "$LOG_FILE" 2>&1
    success "ufw installed"
fi

# Docker manages its own iptables rules for published container ports (443).
# UFW protects native host services (SSH). Both can coexist.
ufw default deny incoming  >> "$LOG_FILE" 2>&1
ufw default allow outgoing >> "$LOG_FILE" 2>&1
ufw default allow routed   >> "$LOG_FILE" 2>&1
ufw allow 22/tcp           >> "$LOG_FILE" 2>&1
ufw allow 443/tcp          >> "$LOG_FILE" 2>&1
ufw --force enable         >> "$LOG_FILE" 2>&1
success "UFW enabled: default deny inbound, SSH + HTTPS allowed"

# --- Automated backup --------------------------------------------------------
section "Installing backup script"

mkdir -p /var/backups/openvas

# Write with placeholder for compose file path
tee "$BACKUP_SCRIPT" > /dev/null << 'BACKUP_EOF'
#!/bin/bash
# OpenVAS backup — PostgreSQL dump + GVM volumes. 14-day retention.
COMPOSE_FILE="__COMPOSE_FILE__"
ADMIN_PASS="__ADMIN_PASS__"
BACKUP_DIR="/var/backups/openvas"
LOG_FILE="/var/log/openvas-backup.log"
RETAIN_DAYS=14
TIMESTAMP=$(date '+%Y-%m-%d_%H%M%S')

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

log "=== Backup started ==="
mkdir -p "$BACKUP_DIR"
DEST="${BACKUP_DIR}/${TIMESTAMP}"
mkdir -p "$DEST"

log "Dumping pg-gvm database..."
docker compose -f "$COMPOSE_FILE" exec -T -u postgres pg-gvm \
    pg_dump -Fc gvmd > "${DEST}/gvmd.pgdump" 2>> "$LOG_FILE"
if [ $? -eq 0 ] && [ -s "${DEST}/gvmd.pgdump" ]; then
    SIZE=$(du -sh "${DEST}/gvmd.pgdump" | cut -f1)
    log "Database dump complete: ${SIZE}"
else
    log "ERROR: Database dump failed or empty"
fi

log "Backing up GVM config volumes..."
for VOL in \
    greenbone-community-edition_gvmd_data_vol \
    greenbone-community-edition_vt_data_vol \
    greenbone-community-edition_notus_data_vol; do
    VOLPATH="/var/lib/docker/volumes/${VOL}/_data"
    if [ -d "$VOLPATH" ]; then
        VOLNAME="${VOL##*_}"
        log "  Archiving ${VOL}..."
        tar -czf "${DEST}/${VOLNAME}.tar.gz" -C "$VOLPATH" . 2>> "$LOG_FILE"
        log "  ${VOLNAME}.tar.gz: $(du -sh "${DEST}/${VOLNAME}.tar.gz" | cut -f1)"
    fi
done

log "Backing up compose file and SSL cert..."
cp "$COMPOSE_FILE" "${DEST}/docker-compose.yml"
CERT_VOL="/var/lib/docker/volumes/greenbone-community-edition_nginx_certificates_vol/_data"
[ -d "$CERT_VOL" ] && tar -czf "${DEST}/nginx_certs.tar.gz" -C "$CERT_VOL" . 2>> "$LOG_FILE"

log "Exporting GVM reports as XML..."
ok_count=0
fail_count=0
_probe=$(docker compose -f "$COMPOSE_FILE" run --rm gvm-tools \
    gvm-cli --gmp-username admin --gmp-password "$ADMIN_PASS" \
    socket --socketpath /run/gvmd/gvmd.sock \
    --xml '<get_version/>' 2>/dev/null || true)
if echo "$_probe" | grep -q 'status="200"'; then
    mkdir -p "${DEST}/reports" || { log "ERROR: cannot create ${DEST}/reports"; exit 1; }
    _ids=$(docker compose -f "$COMPOSE_FILE" run --rm gvm-tools \
        gvm-cli --gmp-username admin --gmp-password "$ADMIN_PASS" \
        socket --socketpath /run/gvmd/gvmd.sock \
        --xml '<get_reports filter="rows=-1" details="0"/>' 2>/dev/null \
        | grep -oP '(?<=<report id=")[^"]+' || true)
    if [ -z "$_ids" ]; then
        log "  0 reports found — skipping"
    else
        while IFS= read -r _rid; do
            [ -z "$_rid" ] && continue
            _out="${DEST}/reports/${_rid}.xml"
            docker compose -f "$COMPOSE_FILE" run --rm gvm-tools \
                gvm-cli --gmp-username admin --gmp-password "$ADMIN_PASS" \
                socket --socketpath /run/gvmd/gvmd.sock \
                --xml "<get_reports report_id=\"${_rid}\" details=\"1\" ignore_pagination=\"1\" format_id=\"a994b278-1f62-11e1-96ac-406186ea4fc5\"/>" \
                > "$_out" 2>>"$LOG_FILE" || true
            if grep -q 'status="200"' "$_out" 2>/dev/null && [ -s "$_out" ]; then
                ok_count=$((ok_count + 1))
            else
                log "  WARNING: failed to export report ${_rid}"
                rm -f "$_out"
                fail_count=$((fail_count + 1))
            fi
        done <<< "$_ids"
        log "  Exported ${ok_count} report(s) to reports/ (${fail_count} failed)"
    fi
else
    log "  WARNING: gvmd not reachable — skipping report export"
fi

log "Compressing backup..."
tar -czf "${BACKUP_DIR}/openvas-backup-${TIMESTAMP}.tar.gz" -C "$BACKUP_DIR" "$TIMESTAMP" 2>> "$LOG_FILE"
rm -rf "$DEST"
log "Backup archive: openvas-backup-${TIMESTAMP}.tar.gz ($(du -sh "${BACKUP_DIR}/openvas-backup-${TIMESTAMP}.tar.gz" | cut -f1))"

PRUNED=$(find "$BACKUP_DIR" -name "openvas-backup-*.tar.gz" -mtime "+${RETAIN_DAYS}" -print -delete | wc -l)
[ "$PRUNED" -gt 0 ] && log "Pruned ${PRUNED} backup(s) older than ${RETAIN_DAYS} days"
log "=== Backup done ==="
BACKUP_EOF

# Substitute placeholders — validate no '|' in values (sed delimiter)
if [[ "$ADMIN_PASSWORD" == *'|'* ]]; then
    warn "ADMIN_PASSWORD contains '|' — cannot safely substitute into backup script"
    warn "Report export will NOT work. Re-run with a password that does not contain '|'."
fi
sed -i "s|__COMPOSE_FILE__|${COMPOSE_FILE}|g" "$BACKUP_SCRIPT"
sed -i "s|__ADMIN_PASS__|${ADMIN_PASSWORD}|g"  "$BACKUP_SCRIPT"
chmod 750 "$BACKUP_SCRIPT"

tee /etc/cron.d/openvas-backup > /dev/null << 'EOF'
# OpenVAS daily backup at 1am (before image update at 2am)
0 1 * * * root /usr/local/bin/openvas-backup.sh
EOF
chmod 644 /etc/cron.d/openvas-backup

tee /etc/logrotate.d/openvas-backup > /dev/null << 'EOF'
/var/log/openvas-backup.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
EOF
success "Backup script installed (daily 1am, 14-day retention → /var/backups/openvas/)"

# --- Install GVM reimport helper ---------------------------------------------
# gvm-reimport.py lets admins re-run scan config import after NVT feed loads.
cat > /usr/local/bin/gvm-reimport.py << 'REIMPORT_PY_EOF'
import subprocess, json, xml.etree.ElementTree as ET, os, sys, time
from xml.sax.saxutils import escape as xe

CF = os.environ['GVM_COMPOSE_FILE']
AP = os.environ['GVM_ADMIN_PASS']
INP = os.environ['GVM_CONFIG_INPUT']
try:
    pw_map = json.loads(os.environ.get('GVM_CRED_PASSWORDS','{}'))
except Exception:
    pw_map = {}

with open(INP) as f:
    cfg = json.load(f)

def gvm(cmd, retries=3):
    last = ''
    for attempt in range(retries):
        try:
            r = subprocess.run(
                ['docker','compose','-f',CF,'run','--rm','gvm-tools',
                 'gvm-cli','--gmp-username','admin','--gmp-password',AP,
                 'socket','--socketpath','/run/gvmd/gvmd.sock','--xml',cmd],
                capture_output=True, text=True, timeout=120)
            out = r.stdout.strip()
        except subprocess.TimeoutExpired:
            out = ''
        # Valid GMP XML always starts with '<'; retry on empty or gvm-cli error output
        if out and out.startswith('<'):
            return out
        last = out
        if attempt < retries - 1:
            time.sleep(10)
    return last  # return last response (even if bad); caller handles gracefully

def xt(e, tag, d=''):
    n = e.find(tag); return (n.text or '').strip() if n is not None else d

def get_id(xml_str, item_tag, name):
    try:
        for item in ET.fromstring(xml_str).findall(item_tag):
            if xt(item,'name') == name: return item.get('id','')
    except Exception: pass
    return ''

# Credentials (skip if already exist)
cred_xml = gvm('<get_credentials/>')
existing_creds = {}
try:
    for c in ET.fromstring(cred_xml).findall('credential'):
        n = xt(c, 'name'); existing_creds[n] = c.get('id','')
except Exception: pass

cred_name2id = dict(existing_creds)
for c in cfg.get('credentials', []):
    if c['name'] in existing_creds:
        print(f"  Credential: {c['name']} (already exists)")
        continue
    pw = pw_map.get(c.get('login',''), pw_map.get('_default', '__NEED_PASSWORD__'))
    placeholder = False
    if pw == '__NEED_PASSWORD__':
        pw = 'CHANGE_ME_IN_WEBUI'
        placeholder = True
    cname = xe(c['name']); ctype = xe(c['type'])
    clogin = xe(c['login']); cpw = xe(pw)
    resp = gvm(f"<create_credential><name>{cname}</name><type>{ctype}</type>"
               f"<login>{clogin}</login><password>{cpw}</password></create_credential>")
    try:
        nid = ET.fromstring(resp).get('id','')
        if nid:
            cred_name2id[c['name']] = nid
            msg = "PLACEHOLDER set — update in web UI" if placeholder else "created"
            print(f"  Credential: {c['name']} — {msg}")
        else: print(f"  WARN credential {c['name']}: {resp[:200]}")
    except Exception as e: print(f"  ERROR cred: {e}")

# Port lists
pl_xml = gvm('<get_port_lists/>')

# Targets (skip if already exist)
tgt_xml = gvm('<get_targets/>')
existing_tgts = {}
try:
    for t in ET.fromstring(tgt_xml).findall('target'):
        n = xt(t, 'name'); existing_tgts[n] = t.get('id','')
except Exception: pass

tgt_name2id = dict(existing_tgts)
for t in cfg.get('targets', []):
    if t['name'] in existing_tgts:
        print(f"  Target: {t['name']} (already exists)")
        continue
    sname = t.get('smb_credential_name','')
    smb_e = f'<smb_credential id="{cred_name2id[sname]}"/>' if sname and sname in cred_name2id else ''
    pl_id = get_id(pl_xml,'port_list',t.get('port_list_name',''))
    pl_e = f'<port_list id="{pl_id}"/>' if pl_id else ''
    ex_e = f'<exclude_hosts>{xe(t["exclude_hosts"])}</exclude_hosts>' if t.get('exclude_hosts') else ''
    al_e = f'<alive_tests>{xe(t["alive_tests"])}</alive_tests>' if t.get('alive_tests') else ''
    tname = xe(t['name']); thosts = xe(t['hosts'])
    resp = gvm(f"<create_target><name>{tname}</name><hosts>{thosts}</hosts>"
               f"{ex_e}{pl_e}{smb_e}{al_e}</create_target>")
    try:
        nid = ET.fromstring(resp).get('id','')
        if nid: tgt_name2id[t['name']] = nid; print(f"  Target: {t['name']} — created")
        else: print(f"  WARN target {t['name']}: {resp[:200]}")
    except Exception as e: print(f"  ERROR target: {e}")

# Schedules (skip if already exist)
sched_xml = gvm('<get_schedules/>')
existing_scheds = {}
try:
    for s in ET.fromstring(sched_xml).findall('schedule'):
        n = xt(s, 'name'); existing_scheds[n] = s.get('id','')
except Exception: pass

sched_name2id = dict(existing_scheds)
for s in cfg.get('schedules', []):
    if s['name'] in existing_scheds:
        print(f"  Schedule: {s['name']} (already exists)")
        continue
    ical = s.get('icalendar','').strip()
    if not ical: continue
    sname = xe(s['name']); stz = xe(s.get('timezone','UTC')); sical = xe(ical)
    resp = gvm(f"<create_schedule><name>{sname}</name>"
               f"<icalendar>{sical}</icalendar><timezone>{stz}</timezone></create_schedule>")
    try:
        nid = ET.fromstring(resp).get('id','')
        if nid: sched_name2id[s['name']] = nid; print(f"  Schedule: {s['name']} — created")
        else: print(f"  WARN schedule {s['name']}: {resp[:200]}")
    except Exception as e: print(f"  ERROR sched: {e}")

# Scanners + configs
sc_xml = gvm('<get_scanners/>'); cf_xml = gvm('<get_configs/>')

# Tasks (skip if already exist)
task_xml = gvm('<get_tasks/>')
existing_tasks = set()
try:
    for t in ET.fromstring(task_xml).findall('task'):
        n = xt(t, 'name'); existing_tasks.add(n)
except Exception: pass

for t in cfg.get('tasks', []):
    if t['name'] in existing_tasks:
        print(f"  Task: {t['name']} (already exists)")
        continue
    tid = tgt_name2id.get(t.get('target_name',''),'')
    sid = sched_name2id.get(t.get('schedule_name',''),'')
    scn_id = get_id(sc_xml,'scanner',t.get('scanner_name',''))
    cfg_id = get_id(cf_xml,'config',t.get('config_name',''))
    if not tid or not scn_id or not cfg_id:
        print(f"  SKIP task '{t['name']}' — missing deps "
              f"(target={bool(tid)} scanner={bool(scn_id)} config={bool(cfg_id)})"); continue
    sc_e = f'<schedule id="{sid}"/>' if sid else ''
    tname = xe(t['name'])
    resp = gvm(f"<create_task><name>{tname}</name><config id=\"{cfg_id}\"/>"
               f"<target id=\"{tid}\"/><scanner id=\"{scn_id}\"/>{sc_e}</create_task>")
    try:
        nid = ET.fromstring(resp).get('id','')
        if nid: print(f"  Task: {t['name']} — created")
        else: print(f"  WARN task {t['name']}: {resp[:200]}")
    except Exception as e: print(f"  ERROR task: {e}")

print("Scan config reimport complete.")
REIMPORT_PY_EOF
chmod 755 /usr/local/bin/gvm-reimport.py

# --- Harden Desktop file permissions -----------------------------------------
section "Hardening file permissions"

chmod 600 \
    "${DEPLOY_HOME}/Desktop/README.txt" \
    "${DEPLOY_HOME}/Desktop/DEPLOYMENT_NOTES.txt" \
    "${DEPLOY_HOME}/Desktop/deploy-openvas.sh" 2>/dev/null || true
success "Desktop credential files restricted to owner-only (chmod 600)"

# --- Deferred task creation (cron fallback) -----------------------------------
# install_task_cron() is called when NVT feed scan configs are not yet loaded
# after the inline 5-minute poll. Installs a self-deleting cron that retries
# every 5 minutes for up to 8 hours, then removes itself.
install_task_cron() {
    local compose_file="$1"
    local admin_pass="$2"
    local config_input="$3"

    cat > /usr/local/bin/openvas-create-tasks.sh << 'TASK_SCRIPT_EOF'
#!/bin/bash
# OpenVAS deferred task creation — self-deletes on success or timeout.
# Written by deploy-openvas.sh. chmod 700 — contains plaintext credentials.
GVM_COMPOSE_FILE="__GVM_COMPOSE_FILE__"
GVM_ADMIN_PASS="__GVM_ADMIN_PASS__"
GVM_CONFIG_INPUT="__GVM_CONFIG_INPUT__"

LOG_FILE="/var/log/openvas-task-import.log"
STATE_FILE="/var/lib/openvas-task-import.attempts"
LOCK_FILE="/var/run/openvas-task-import.lock"
MAX_ATTEMPTS=96

log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE"; }

cleanup() {
    rm -f /etc/cron.d/openvas-task-import
    rm -f "$STATE_FILE"
    rm -f "$LOCK_FILE"
    log "Removing /etc/cron.d/openvas-task-import. No further action required."
    rm -f -- "$0"
}

# Acquire exclusive lock — skip tick if previous invocation still running
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

# Initialise attempt counter
if [ ! -f "$STATE_FILE" ]; then
    echo 0 > "$STATE_FILE"
fi

# Check if all expected tasks already exist in GVM
expected_tasks=$(python3 -c "
import json, sys
try:
    d = json.load(open('$GVM_CONFIG_INPUT'))
    print('\n'.join(t['name'] for t in d.get('tasks',[])))
except Exception as e:
    sys.exit(1)
" 2>/dev/null)

if [ -n "$expected_tasks" ]; then
    actual_tasks=$(docker compose -f "$GVM_COMPOSE_FILE" run --rm gvm-tools \
        gvm-cli --gmp-username admin --gmp-password "$GVM_ADMIN_PASS" \
        socket --socketpath /run/gvmd/gvmd.sock \
        --xml '<get_tasks/>' 2>/dev/null \
        | grep -oP '(?<=<name>)[^<]+' || true)
    all_present=true
    while IFS= read -r tname; do
        [ -z "$tname" ] && continue
        echo "$actual_tasks" | grep -qF "$tname" || { all_present=false; break; }
    done <<< "$expected_tasks"
    if [ "$all_present" = "true" ]; then
        log "All tasks already present — nothing to do"
        cleanup
        exit 0
    fi
fi

# Increment attempt counter
attempts=$(cat "$STATE_FILE")
attempts=$((attempts + 1))
echo "$attempts" > "$STATE_FILE"

# Check timeout ceiling
if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
    log "ERROR: Tasks not created after 8 hours — manual intervention required"
    log "Run manually: GVM_COMPOSE_FILE=$GVM_COMPOSE_FILE GVM_ADMIN_PASS=<password> GVM_CONFIG_INPUT=$GVM_CONFIG_INPUT python3 /usr/local/bin/gvm-reimport.py"
    cleanup
    exit 1
fi

# Validate backup file
if ! python3 -c "import json; json.load(open('$GVM_CONFIG_INPUT'))" 2>/dev/null; then
    log "ERROR: Backup file missing or invalid at $GVM_CONFIG_INPUT — cannot create tasks"
    cleanup
    exit 1
fi

# GMP liveness check
resp=$(docker compose -f "$GVM_COMPOSE_FILE" run --rm gvm-tools \
    gvm-cli --gmp-username admin --gmp-password "$GVM_ADMIN_PASS" \
    socket --socketpath /run/gvmd/gvmd.sock \
    --xml '<get_version/>' 2>/dev/null || true)
if ! echo "$resp" | grep -q 'status="200"'; then
    log "Attempt $attempts/$MAX_ATTEMPTS — gvmd not ready"
    exit 0
fi

# Check if scan configs are loaded
config_count=$(docker compose -f "$GVM_COMPOSE_FILE" run --rm gvm-tools \
    gvm-cli --gmp-username admin --gmp-password "$GVM_ADMIN_PASS" \
    socket --socketpath /run/gvmd/gvmd.sock \
    --xml '<get_configs/>' 2>/dev/null \
    | grep -c '<config id=' || echo 0)
config_count=${config_count//[^0-9]/}
if [ "${config_count:-0}" -eq 0 ]; then
    log "Attempt $attempts/$MAX_ATTEMPTS — waiting for NVT feed (0 scan configs loaded)"
    exit 0
fi

log "Attempt $attempts/$MAX_ATTEMPTS — scan configs loaded ($config_count found). Running reimport..."

# Run reimport
GVM_COMPOSE_FILE="$GVM_COMPOSE_FILE" \
GVM_ADMIN_PASS="$GVM_ADMIN_PASS" \
GVM_CONFIG_INPUT="$GVM_CONFIG_INPUT" \
python3 /usr/local/bin/gvm-reimport.py >> "$LOG_FILE" 2>&1

# Re-check by name — same method as early-exit check
expected_tasks=$(python3 -c "
import json, sys
try:
    d = json.load(open('$GVM_CONFIG_INPUT'))
    print('\n'.join(t['name'] for t in d.get('tasks',[])))
except Exception as e:
    sys.exit(1)
" 2>/dev/null)
actual_tasks=$(docker compose -f "$GVM_COMPOSE_FILE" run --rm gvm-tools \
    gvm-cli --gmp-username admin --gmp-password "$GVM_ADMIN_PASS" \
    socket --socketpath /run/gvmd/gvmd.sock \
    --xml '<get_tasks/>' 2>/dev/null \
    | grep -oP '(?<=<name>)[^<]+' || true)
expected_count=$(echo "$expected_tasks" | grep -c .)
found_count=0
all_present=true
while IFS= read -r tname; do
    [ -z "$tname" ] && continue
    if echo "$actual_tasks" | grep -qF "$tname"; then
        found_count=$((found_count + 1))
    else
        all_present=false
    fi
done <<< "$expected_tasks"

if [ "$all_present" = "true" ] && [ "$expected_count" -gt 0 ]; then
    log "All $expected_count tasks created successfully. Deferred deployment complete."
    cleanup
    exit 0
else
    log "Partial success ($found_count/$expected_count tasks present by name) — will retry"
    exit 0
fi
TASK_SCRIPT_EOF

    chmod 700 /usr/local/bin/openvas-create-tasks.sh
    # sed uses '|' as delimiter — validate none of the substituted values contain '|'
    # (a '|' in admin_pass would silently corrupt the installed script)
    if [[ "$admin_pass" == *'|'* ]] || [[ "$compose_file" == *'|'* ]] || [[ "$config_input" == *'|'* ]]; then
        warn "ADMIN_PASSWORD or path contains '|' — cannot safely substitute into cron script"
        warn "Deferred task creation cron NOT installed. Re-run with a password that does not contain '|'."
        rm -f /usr/local/bin/openvas-create-tasks.sh
        return 1
    fi
    sed -i "s|__GVM_COMPOSE_FILE__|${compose_file}|g" /usr/local/bin/openvas-create-tasks.sh
    sed -i "s|__GVM_ADMIN_PASS__|${admin_pass}|g"    /usr/local/bin/openvas-create-tasks.sh
    sed -i "s|__GVM_CONFIG_INPUT__|${config_input}|g" /usr/local/bin/openvas-create-tasks.sh

    tee /etc/cron.d/openvas-task-import > /dev/null << 'CRON_EOF'
# OpenVAS deferred task creation — auto-removes on completion
*/5 * * * * root /usr/local/bin/openvas-create-tasks.sh >> /var/log/openvas-task-import.log 2>&1
CRON_EOF
    chmod 644 /etc/cron.d/openvas-task-import

    success "Deferred task creation cron installed (every 5min, max 8 hours)"
    log "Monitor progress: tail -f /var/log/openvas-task-import.log"
}

# --- Reimport scan configuration ---------------------------------------------
section "Reimporting scan configuration"

TASKS_DEFERRED=false
TASKS_CREATED=false

if [ -s "$SCAN_CONFIG_BACKUP" ]; then
    log "Waiting for gvmd to be ready for scan config import..."
    GVMD_READY=false
    for i in $(seq 1 18); do
        # Probe the GMP socket directly — proves the socket is up AND the
        # admin password is accepted. --get-users only proves the DB is alive.
        resp=$(compose run --rm gvm-tools gvm-cli \
            --gmp-username admin --gmp-password "$ADMIN_PASSWORD" \
            socket --socketpath /run/gvmd/gvmd.sock \
            --xml '<get_version/>' 2>/dev/null || true)
        if echo "$resp" | grep -q 'status="200"'; then
            GVMD_READY=true; break
        fi
        [ "$i" -lt 18 ] && sleep 10
    done

    if [ "$GVMD_READY" = "true" ]; then
        log "Reimporting credentials, targets, schedules..."
        export GVM_COMPOSE_FILE="$COMPOSE_FILE"
        export GVM_ADMIN_PASS="$ADMIN_PASSWORD"
        export GVM_CONFIG_INPUT="$SCAN_CONFIG_BACKUP"
        export GVM_CRED_PASSWORDS
        GVM_CRED_PASSWORDS=$(python3 -c "
import json, os
pw = os.environ.get('SMB_CREDENTIAL_PASSWORD', '')
print(json.dumps({'_default': pw} if pw else {}))" 2>>"$LOG_FILE" || echo '{}')

        # timeout 300: gvmd can stall on GMP socket responses while loading VTs;
        # a hung reimport blocks the whole deploy indefinitely without this guard.
        # Partial creates (creds/targets/schedules done before hang) are preserved
        # because reimport is idempotent. Tasks fall through to deferred cron.
        # set +o pipefail: required so PIPESTATUS[0] captures timeout's exit code
        # (124 = timed out) before set -e can abort; || true would clobber it.
        set +o pipefail
        timeout 300 python3 /usr/local/bin/gvm-reimport.py 2>&1 | tee -a "$LOG_FILE"
        REIMPORT1_EXIT=${PIPESTATUS[0]}
        set -o pipefail
        if [ "$REIMPORT1_EXIT" -eq 124 ]; then
            warn "gvm-reimport.py timed out after 5 min — partial reimport preserved; tasks deferred"
        fi

        # --- Inline 5-minute poll for scan configs ----------------------------
        log "Polling for scan configs (NVT feed may still be loading)..."
        CONFIGS_FOUND=false
        for i in $(seq 1 30); do
            config_count=$(compose run --rm gvm-tools gvm-cli \
                --gmp-username admin --gmp-password "$ADMIN_PASSWORD" \
                socket --socketpath /run/gvmd/gvmd.sock \
                --xml '<get_configs/>' 2>/dev/null \
                | grep -c '<config id=' || echo 0)
            config_count=${config_count//[^0-9]/}
            if [ "${config_count:-0}" -gt 0 ]; then
                CONFIGS_FOUND=true
                log "Scan configs available ($config_count found) — running task creation..."
                break
            fi
            log "Attempt $i/30 — waiting for NVT feed ($config_count configs)..."
            [ "$i" -lt 30 ] && sleep 10
        done

        if [ "$CONFIGS_FOUND" = "true" ]; then
            # Second reimport call — idempotent; creates tasks now that configs exist
            set +o pipefail
            timeout 300 python3 /usr/local/bin/gvm-reimport.py 2>&1 | tee -a "$LOG_FILE"
            REIMPORT2_EXIT=${PIPESTATUS[0]}
            set -o pipefail
            if [ "$REIMPORT2_EXIT" -eq 124 ]; then
                warn "gvm-reimport.py (task creation) timed out — falling back to deferred cron"
            fi
            # Unset credential env vars now that both reimport calls are done
            unset GVM_COMPOSE_FILE GVM_ADMIN_PASS GVM_CONFIG_INPUT GVM_CRED_PASSWORDS

            # Verify all expected tasks exist by name (name-based, not count-based,
            # to avoid false-positive when pre-existing tasks inflate the count)
            expected_tasks=$(GVM_CONFIG_INPUT="$SCAN_CONFIG_BACKUP" python3 -c "
import json, os
d = json.load(open(os.environ['GVM_CONFIG_INPUT']))
print('\n'.join(t['name'] for t in d.get('tasks', [])))" 2>>"$LOG_FILE" || echo '')
            actual_tasks=$(compose run --rm gvm-tools gvm-cli \
                --gmp-username admin --gmp-password "$ADMIN_PASSWORD" \
                socket --socketpath /run/gvmd/gvmd.sock \
                --xml '<get_tasks/>' 2>/dev/null \
                | grep -oP '(?<=<name>)[^<]+' || true)
            TASKS_ALL_PRESENT=true
            while IFS= read -r tname; do
                [ -z "$tname" ] && continue
                echo "$actual_tasks" | grep -qF "$tname" || { TASKS_ALL_PRESENT=false; break; }
            done <<< "$expected_tasks"

            if [ "$TASKS_ALL_PRESENT" = "true" ] && [ -n "$expected_tasks" ]; then
                TASKS_CREATED=true
                SCAN_CONFIG_SUMMARY=$(GVM_CONFIG_INPUT="$SCAN_CONFIG_BACKUP" python3 -c "
import json, os
d=json.load(open(os.environ['GVM_CONFIG_INPUT']))
print(f\"{len(d.get('credentials',[]))} cred, {len(d.get('targets',[]))} targets, {len(d.get('schedules',[]))} schedules, {len(d.get('tasks',[]))} tasks\")" 2>>"$LOG_FILE" || echo 'reimported')
                success "Scan config: $SCAN_CONFIG_SUMMARY"
            else
                log "Not all expected tasks present by name — falling back to deferred cron"
            fi
        fi

        if [ "$TASKS_CREATED" = "false" ]; then
            install_task_cron "$COMPOSE_FILE" "$ADMIN_PASSWORD" "$SCAN_CONFIG_BACKUP"
            TASKS_DEFERRED=true
        fi
    else
        warn "gvmd not ready for reimport after 3 minutes — installing deferred task cron"
        install_task_cron "$COMPOSE_FILE" "$ADMIN_PASSWORD" "$SCAN_CONFIG_BACKUP"
        TASKS_DEFERRED=true
    fi
else
    log "No scan config backup found — skipping reimport (fresh deployment)"
fi

# --- Done --------------------------------------------------------------------
section "Deployment complete"

HOST_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║        OpenVAS / Greenbone CE  — Ready                 ║${NC}"
echo -e "${GREEN}╠════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Web UI:     https://${HOST_IP}                        ${NC}"
echo -e "${GREEN}║              https://127.0.0.1                         ║${NC}"
echo -e "${GREEN}║  Username:   admin                                     ║${NC}"
echo -e "${GREEN}║  Password:   (as configured — see README.txt)          ║${NC}"
echo -e "${GREEN}║                                                         ${NC}"
echo -e "${GREEN}║  NOTE: Always use https:// on port 443 (not 9392).    ║${NC}"
echo -e "${GREEN}║  Accept the self-signed certificate warning.           ║${NC}"
echo -e "${GREEN}║                                                         ${NC}"
echo -e "${GREEN}║  Feed data loads in background (30–60 min).           ║${NC}"
echo -e "${GREEN}║  Scans show limited results until feed load complete.  ║${NC}"
if [ "$TASKS_DEFERRED" = "true" ]; then
echo -e "${YELLOW}║  ⚠  Tasks: auto-creating in background (NVT feed loading)  ║${NC}"
echo -e "${YELLOW}║     Monitor: tail -f /var/log/openvas-task-import.log       ║${NC}"
else
# $SCAN_CONFIG_SUMMARY is set by Task 5 when inline tasks succeed; skip if no backup
[ -n "$SCAN_CONFIG_SUMMARY" ] && echo -e "${GREEN}║  ✓  Scan config: $SCAN_CONFIG_SUMMARY           ║${NC}"
fi
echo -e "${GREEN}╠════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Maintenance (auto-installed):                         ║${NC}"
echo -e "${GREEN}║    Backup:        daily 1am → /var/backups/openvas/   ║${NC}"
echo -e "${GREEN}║    Image update:  daily 2am                            ║${NC}"
echo -e "${GREEN}║    System update: daily 3am (apt, no reboot)          ║${NC}"
echo -e "${GREEN}║    Health check:  every 5 minutes                      ║${NC}"
echo -e "${GREEN}║    Logs: /var/log/openvas-{maintain,backup}.log        ║${NC}"
echo -e "${GREEN}║          /var/log/auto-update.log                      ║${NC}"
echo -e "${GREEN}╠════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Hypervisor: ${HYPERVISOR} — Docker MTU: ${TARGET_MTU}              ${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

log "Deployment finished. Log: $LOG_FILE"
