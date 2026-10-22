#!/bin/bash
set -euo pipefail

# Grafito onboarding wizard — the install.sh experience expanded into a
# full-machine setup for a fresh (or willing) Linux host.
#
# It assumes the machine is open to modification, asks for consent with
# a concrete plan, and then:
#
#   * installs grafito as a systemd service (native binary, dedicated
#     system user, hardened unit) with access to the journal, and —
#     if you use docker — the docker socket;
#   * installs vector and the grafito log pipeline (honest severities
#     for container logs, re-emitted into journald) when docker is in
#     use;
#   * creates the folders grafito needs to know about (data dir,
#     homepage config dir, compose stacks dir), with prompts;
#   * optionally sets docker's log driver to json-file with rotation,
#     makes the journal persistent, installs a polkit rule so unit
#     actions work, and generates an MCP token.
#
# Everything grafito can configure at runtime — the login, timezone, AI
# keys, homepage contents, gotify — is left to the browser onboarding
# wizard you get on first visit. This script only does host-level setup.
#
# Usage:
#   curl -sSL https://grafito.ralsina.me/onboard.sh | sudo bash
#   sudo ./onboard.sh [options]
#
# Options:
#   --yes              Accept all defaults without prompting (scripted)
#   --port=N           Web UI port                        [default: 1111]
#   --bind=ADDR        Bind address                       [default: 127.0.0.1]
#   --no-vector        Skip the vector log pipeline
#   --enable-actions   Enable privileged actions (also needs a login)
#   --with-mcp-token   Enable the MCP endpoint with a generated token
#   --stacks-dir=PATH  Compose stacks directory
#   --dry-run          Show the plan and what would be done, touch nothing
#   -h, --help         This help
#
# Prompts read from /dev/tty so `curl ... | sudo bash` stays
# interactive; set ONBOARD_TTY=/path to feed answers from a file
# instead (handy for testing or scripted runs).
#
# Re-runs are safe: existing configs are kept or backed up
# (*.grafito-bak-<timestamp>), never silently overwritten.

# --- Configuration ---
REPO="ralsina/grafito"
GRAFITO_BIN="/usr/local/bin/grafito"
GRAFITO_USER="grafito"
GRAFITO_GROUP="grafito"
SERVICE_DIR="/etc/systemd/system"
DATA_DIR="/var/lib/grafito"
ETC_DIR="/etc/grafito"
VECTOR_CONFIG="/etc/vector/vector.yml"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT
trap 'echo; echo "Aborted." >&2; exit 130' INT TERM

# --- Options ---
ASSUME_YES=0
DRY_RUN=0
OPT_PORT=""
OPT_BIND=""
OPT_NO_VECTOR=0
OPT_ACTIONS=0
OPT_MCP=0
OPT_STACKS_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y)        ASSUME_YES=1 ;;
        --port)          OPT_PORT="${2-}"; shift ;;
        --port=*)        OPT_PORT="${1#*=}" ;;
        --bind)          OPT_BIND="${2-}"; shift ;;
        --bind=*)        OPT_BIND="${1#*=}" ;;
        --no-vector)     OPT_NO_VECTOR=1 ;;
        --enable-actions) OPT_ACTIONS=1 ;;
        --with-mcp-token) OPT_MCP=1 ;;
        --stacks-dir)    OPT_STACKS_DIR="${2-}"; shift ;;
        --stacks-dir=*)  OPT_STACKS_DIR="${1#*=}" ;;
        --dry-run)       DRY_RUN=1 ;;
        -h|--help)       grep '^#' "$0" | sed -n '2,40p'; exit 0 ;;
        *) echo "Unknown option: $1 (see --help)" >&2; exit 64 ;;
    esac
    shift
done

# --- Output helpers ---
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_B=$'\e[1m'; C_C=$'\e[36m'; C_0=$'\e[0m'
else
    C_G=""; C_Y=""; C_R=""; C_B=""; C_C=""; C_0=""
fi
info()  { echo "${C_G}==>${C_0} $*" >&2; }
warn()  { echo "${C_Y}warning:${C_0} $*" >&2; }
err()   { echo "${C_R}error:${C_0} $*" >&2; }
step()  { echo >&2; echo "${C_B}${C_C}=== $* ===${C_0}" >&2; }

die() { err "$*"; exit 1; }

# --- Prompt plumbing ---
# Answers come from a terminal (not the curl pipe stdin).
TTY_FILE="${ONBOARD_TTY:-/dev/tty}"
HAVE_TTY=0
# Open read-write on terminals, read-only on answer files. A present
# but unopenable /dev/tty (sudo with no controlling terminal) just
# means no prompts: --yes still works.
if { exec 3<>"$TTY_FILE"; } 2>/dev/null || { exec 3<"$TTY_FILE"; } 2>/dev/null; then
    HAVE_TTY=1
fi

# ask_value PROMPT DEFAULT -> echoes the answer (default when empty)
ask_value() {
    local prompt="$1" default="$2" answer=""
    if [[ $HAVE_TTY == 1 && $ASSUME_YES == 0 ]]; then
        printf '%s [%s]: ' "$prompt" "$default" >&2
        IFS= read -r -u 3 answer || answer=""
    fi
    printf '%s' "${answer:-$default}"
}

# ask_yes PROMPT DEFAULT(y|n) -> return 0 for yes
ask_yes() {
    local prompt="$1" default="$2" hint answer=""
    if [[ $default == "y" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
    if [[ $HAVE_TTY == 1 && $ASSUME_YES == 0 ]]; then
        printf '%s %s ' "$prompt" "$hint" >&2
        IFS= read -r -u 3 answer || answer=""
    fi
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# --- Dry-run-aware actions ---
execute() {
    echo "++ $*" >&2
    if [[ $DRY_RUN == 1 ]]; then return 0; fi
    "$@"
}

# write_file PATH MODE  (content on stdin)
write_file() {
    local path="$1" mode="$2"
    if [[ $DRY_RUN == 1 ]]; then
        echo "++ write $path (mode $mode):" >&2
        sed 's/^/    /' >&2
        return 0
    fi
    mkdir -p "$(dirname "$path")"
    cat > "$path"
    chmod "$mode" "$path"
}

download() { # URL DEST
    echo "++ curl -fsSL -o $2 $1" >&2
    if [[ $DRY_RUN == 1 ]]; then return 0; fi
    curl -fsSL -o "$2" "$1"
}

backup_if_exists() {
    local path="$1" stamp
    [[ -e "$path" ]] || return 0
    stamp="$(date +%Y%m%d-%H%M%S)"
    echo "++ cp -a $path $path.grafito-bak-$stamp (backup)" >&2
    if [[ $DRY_RUN == 1 ]]; then return 0; fi
    cp -a "$path" "$path.grafito-bak-$stamp"
}

# --- Preflight ---
[[ $EUID -ne 0 ]] && die "must run as root (try: sudo bash onboard.sh)"
command -v curl > /dev/null || die "curl is required"
command -v tar > /dev/null || die "tar is required"
command -v systemctl > /dev/null || die "systemctl is required (systemd host)"
[[ -d /run/systemd/system ]] || die "systemd is not running; see README for docker instructions"
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  GRAFITO_ARCH="amd64"; VECTOR_ARCH="x86_64" ;;
    aarch64) GRAFITO_ARCH="arm64";  VECTOR_ARCH="aarch64" ;;
    *) die "unsupported architecture '$ARCH' (x86_64 and aarch64 only)" ;;
esac
NOLOGIN="/usr/sbin/nologin"; [[ -x $NOLOGIN ]] || NOLOGIN="/bin/false"

DOCKER_PRESENT=0
command -v docker > /dev/null 2>&1 && DOCKER_PRESENT=1
# Units must not name a missing group (systemd refuses to start them),
# so group existence is checked once and used everywhere.
DOCKER_GROUP=0
getent group docker > /dev/null 2>&1 && DOCKER_GROUP=1
JOURNAL_PERSISTENT=1
[[ -d /var/log/journal ]] || JOURNAL_PERSISTENT=0

echo "${C_B}Grafito onboarding wizard${C_0} (arch: $ARCH, dry-run: $DRY_RUN)" >&2

if [[ $HAVE_TTY == 0 && $ASSUME_YES == 0 ]]; then
    die "no terminal available for prompts. Re-run interactively, or use --yes (plus flags) for a scripted install."
fi

# --- Questions ---
step "Questions (Enter accepts the [default])"

# Port
PORT="${OPT_PORT:-1111}"
while true; do
    PORT="$(ask_value "Port for grafito's web UI" "$PORT")"
    if [[ $PORT =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )); then break; fi
    warn "'$PORT' is not a valid port"
    [[ $ASSUME_YES == 1 ]] && die "invalid --port"
done
if [[ $DRY_RUN == 0 ]]; then
    probe="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${PORT}/" 2>/dev/null || true)"
    if [[ $probe =~ ^[0-9]{3}$ ]]; then
        warn "something already answers on port $PORT; make sure that is not another grafito"
    fi
fi

# Bind address
BIND="${OPT_BIND:-127.0.0.1}"
BIND="$(ask_value "Bind address (127.0.0.1 keeps it local; 0.0.0.0 exposes it to the network)" "$BIND")"
case "$BIND" in
    127.0.0.1|localhost|::1) ;;
    *) warn "non-loopback bind without a login exposes all logs to the network until you create one (the first-visit wizard does)" ;;
esac

# Docker integration
DOCKER_INTEGRATION=0
VECTOR=0
if [[ $OPT_NO_VECTOR == 1 ]]; then
    info "vector skipped (--no-vector)"
elif [[ $DOCKER_PRESENT == 1 ]]; then
    if ask_yes "This machine runs docker. Wire the compose view (docker group for grafito) and the vector log pipeline?" "y"; then
        DOCKER_INTEGRATION=1
        VECTOR=1
    fi
else
    info "docker not found: compose view and vector pipeline skipped (install docker and re-run to add them)"
fi

# Docker default log driver (json-file + rotation) — the vector pipeline
# works best when containers don't ALSO write to journald themselves.
DOCKER_LOG_DRIVER=0
if [[ $DOCKER_INTEGRATION == 1 ]]; then
    if [[ -f /etc/docker/daemon.json ]]; then
        info "/etc/docker/daemon.json exists: left untouched (vector works best when containers use a file log driver, e.g. json-file)"
    elif ask_yes "Set docker's default log driver to json-file with rotation (applies to containers created after the next docker restart)?" "y"; then
        DOCKER_LOG_DRIVER=1
    fi
fi

# Actions (unit/stack/process buttons)
ENABLE_ACTIONS=$OPT_ACTIONS
if [[ $ENABLE_ACTIONS == 0 ]]; then
    if ask_yes "Enable actions (start/stop/restart units, stacks and processes from the UI)? Also installs a polkit rule; needs a login (first-visit wizard)" "n"; then
        ENABLE_ACTIONS=1
    fi
fi

# MCP endpoint
ENABLE_MCP=$OPT_MCP
MCP_TOKEN=""
if [[ $ENABLE_MCP == 0 ]] && ask_yes "Enable the MCP endpoint for LLM clients (a bearer token is generated and shown at the end)?" "n"; then
    ENABLE_MCP=1
fi

# Stacks directory
STACKS_DEFAULT="/srv/stacks"
[[ -d /data ]] && STACKS_DEFAULT="/data/stacks"
STACKS_DIR="${OPT_STACKS_DIR:-$STACKS_DEFAULT}"
while true; do
    STACKS_DIR="$(ask_value "Compose stacks directory ('-' to skip: stacks on disk show up in the compose view as stopped)" "$STACKS_DIR")"
    if [[ $STACKS_DIR == "-" ]]; then STACKS_DIR=""; break; fi
    if [[ $STACKS_DIR == /* && $STACKS_DIR != */..* ]]; then break; fi
    warn "'$STACKS_DIR' must be an absolute path"
    [[ $ASSUME_YES == 1 ]] && die "invalid --stacks-dir"
done

# Persistent journal (fresh debian/ubuntu boxes default to volatile)
MAKE_JOURNAL_PERSISTENT=0
if [[ $JOURNAL_PERSISTENT == 0 ]]; then
    if ask_yes "/var/log/journal is missing: the journal is volatile (logs lost on reboot). Make it persistent (restarts journald)?" "y"; then
        MAKE_JOURNAL_PERSISTENT=1
    fi
fi

# Existing installs
REINSTALL_GRAFITO=1
if [[ -x $GRAFITO_BIN ]]; then
    current_version="$($GRAFITO_BIN --version 2>/dev/null || echo unknown)"
    if ! ask_yes "grafito $current_version is already installed. Reinstall/upgrade to latest release?" "y"; then
        REINSTALL_GRAFITO=0
    fi
fi
VECTOR_BIN="$(command -v vector 2>/dev/null || true)"
REPLACE_VECTOR_CONFIG=0
if [[ -n $VECTOR_BIN && -f $VECTOR_CONFIG && $VECTOR == 1 ]]; then
    if ask_yes "$VECTOR_CONFIG already exists. Replace it with the grafito pipeline (the old one is backed up)?" "n"; then
        REPLACE_VECTOR_CONFIG=1
    fi
fi

# --- Plan + consent ---
WILL=""
WILL+="  - system user 'grafito' (groups: systemd-journal"
[[ $DOCKER_INTEGRATION == 1 && $DOCKER_GROUP == 1 ]] && WILL+=" docker"
WILL+=")\n"
WILL+="  - folders: $DATA_DIR (data, settings), $ETC_DIR (homepage.yml)"
[[ -n $STACKS_DIR ]] && WILL+=", $STACKS_DIR (compose stacks)"
WILL+="\n"
if [[ $REINSTALL_GRAFITO == 1 ]]; then
    WILL+="  - grafito binary ($GRAFITO_BIN, latest release) and $SERVICE_DIR/grafito.service (port $PORT, bind $BIND"
    [[ $ENABLE_ACTIONS == 1 ]] && WILL+=", actions enabled"
    [[ $ENABLE_MCP == 1 ]] && WILL+=", MCP token"
    WILL+="), enabled and started\n"
fi
if [[ $VECTOR == 1 ]]; then
    if [[ -z $VECTOR_BIN ]]; then
        WILL+="  - vector (release tarball) and $VECTOR_CONFIG (the grafito log pipeline), enabled and started\n"
    else
        WILL+="  - vector already installed ($VECTOR_BIN): only the config/unit wiring is touched\n"
    fi
    [[ $REPLACE_VECTOR_CONFIG == 1 ]] && WILL+="  - $VECTOR_CONFIG replaced (old one backed up)\n"
fi
[[ $DOCKER_LOG_DRIVER == 1 ]] && WILL+="  - /etc/docker/daemon.json (json-file driver + rotation; docker is NOT restarted)\n"
[[ $MAKE_JOURNAL_PERSISTENT == 1 ]] && WILL+="  - /var/log/journal created, journald restarted (persistent journal)\n"
[[ $ENABLE_ACTIONS == 1 ]] && WILL+="  - /etc/polkit-1/rules.d/49-grafito.rules (grafito user may manage units)\n"
WILL+="\nNOT touched: docker (no restart), existing configs (kept or backed up),\nyour login (created by the browser wizard on first visit).\n"

step "Plan"
printf '%b' "$WILL" >&2
if [[ $ASSUME_YES == 0 ]]; then
    if ! ask_yes "Proceed with everything above?" "n"; then
        echo "Nothing was changed." >&2
        exit 0
    fi
fi

# --- Step: persistent journal ---
if [[ $MAKE_JOURNAL_PERSISTENT == 1 ]]; then
    step "Making the journal persistent"
    execute install -d -o root -g systemd-journal -m 2755 /var/log/journal
    execute systemd-tmpfiles --create --prefix /var/log/journal
    execute systemctl restart systemd-journald
fi

# --- Step: user and folders ---
step "User and folders"
if ! id -u "$GRAFITO_USER" > /dev/null 2>&1; then
    getent group "$GRAFITO_GROUP" > /dev/null 2>&1 || execute groupadd --system "$GRAFITO_GROUP"
    execute useradd --system --gid "$GRAFITO_GROUP" --home-dir "$DATA_DIR" --no-create-home --shell "$NOLOGIN" "$GRAFITO_USER"
else
    info "user $GRAFITO_USER already exists"
fi
if getent group systemd-journal > /dev/null 2>&1; then
    execute usermod -a -G systemd-journal "$GRAFITO_USER"
else
    warn "group systemd-journal not found: grafito may not see system-wide logs"
fi
if [[ $DOCKER_INTEGRATION == 1 ]]; then
    if [[ $DOCKER_GROUP == 1 ]]; then
        execute usermod -a -G docker "$GRAFITO_USER"
        warn "the docker group is root-equivalent: anyone who can use grafito can control docker"
    else
        warn "group docker not found: the compose view will not work until docker is set up"
    fi
fi
if [[ $DOCKER_PRESENT == 1 && $DRY_RUN == 0 ]]; then
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx grafito; then
        warn "a docker container named 'grafito' is running: this native install will clash with it (stop one of them)"
    fi
fi
execute install -d -o "$GRAFITO_USER" -g "$GRAFITO_GROUP" -m 0750 "$DATA_DIR"
execute install -d -o "$GRAFITO_USER" -g "$GRAFITO_GROUP" -m 0755 "$ETC_DIR"
[[ -n $STACKS_DIR ]] && execute install -d -o "$GRAFITO_USER" -g "$GRAFITO_GROUP" -m 0755 "$STACKS_DIR"

# --- Step: vector ---
vector_step() {
    step "Vector log pipeline"
    if [[ -z $VECTOR_BIN ]]; then
        info "installing vector from the release tarball"
        if [[ $DRY_RUN == 0 ]]; then
            vector_version="$(curl -fsSL https://api.github.com/repos/vectordotdev/vector/releases/latest \
                | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -n1 || true)"
            if [[ -n $vector_version ]]; then
                asset="vector-${vector_version}-${VECTOR_ARCH}-unknown-linux-gnu.tar.gz"
                download "https://github.com/vectordotdev/vector/releases/download/v${vector_version}/${asset}" \
                    "${TEMP_DIR}/${asset}"
                tar -xzf "${TEMP_DIR}/${asset}" -C "$TEMP_DIR"
                execute install -m 0755 "${TEMP_DIR}/vector-${VECTOR_ARCH}-unknown-linux-gnu/bin/vector" /usr/local/bin/vector
            fi
            VECTOR_BIN="$(command -v vector 2>/dev/null || true)"
            if [[ -z $VECTOR_BIN ]]; then
                # Vector is sugar for container logs: onboarding must not
                # die because of it.
                warn "vector could not be installed; continuing without it (re-run to retry)"
                VECTOR=0
                return 0
            fi
        else
            VECTOR_BIN="/usr/local/bin/vector"
        fi
    else
        info "using existing vector at $VECTOR_BIN"
    fi

    if [[ ! -f $VECTOR_CONFIG || $REPLACE_VECTOR_CONFIG == 1 ]]; then
        backup_if_exists "$VECTOR_CONFIG"
        write_file "$VECTOR_CONFIG" 0644 <<'VECTOR_YML'
# /etc/vector/vector.yml — written by grafito's onboarding wizard.
# Classify docker container logs and re-emit them into journald with
# real severities: docker only sees stdout/stderr, so its journald
# driver marks ALL stderr as errors; this pipeline recovers the actual
# level from the message itself (JSON level fields, [E]/[W] markers,
# error/warn keywords).
#
# The docker source follows ALL containers. Containers still using
# docker's journald log driver will appear twice in journald (docker's
# copy + vector's re-emission); keep containers on json-file to avoid
# it.
#
# Line-by-line explanation: docs/vector-on-rocky.md in the grafito repo.

data_dir: /var/lib/vector

sources:
  docker:
    type: docker_logs
    retry_backoff_secs: 1

transforms:
  classify:
    type: remap
    inputs: ["docker"]
    source: |
      .message = to_string(.message) ?? ""
      # Tier 1: structured JSON with a level-ish field
      # (zerolog, zap, logrus, Caddy, tracing_subscriber, bunyan, python...)
      j = parse_json(.message) ?? {}
      raw = j.level
      if raw == null { raw = j.lvl }
      if raw == null { raw = j.severity }
      if raw == null { raw = j.levelname }
      if raw == null { raw = j.levelno }
      lvl = if raw == null { "" } else { downcase(to_string(raw) ?? "") }
      n = to_int(lvl) ?? -1
      # Tier 2: plain-text conventions
      # gitea-style bracket codes first (most specific), then keyword
      # classes (n == -1 means "not numeric"; n in [0,20) is trace/debug)
      sev = if n >= 60 { 2 }
      else if n >= 50 { 3 }
      else if n >= 30 { 4 }
      else if n >= 20 { 6 }
      else if n >= 0 { 7 }
      else if match(.message, r'\[E\]') { 3 }
      else if match(.message, r'\[W\]') { 4 }
      else if match(.message, r'\[D\]') { 7 }
      else if match(.message, r'\[I\]') { 6 }
      else if contains(lvl, "trace") || contains(lvl, "debug") { 7 }
      else if match(.message, r'(?i)\b(err(or)?|critical|fatal|panic)\b') { 3 }
      else if match(.message, r'(?i)\bwarn(ing)?\b') { 4 }
      else if match(.message, r'(?i)\bnotice\b') { 5 }
      else if contains(lvl, "info") || match(.message, r'(?i)\b(info|log)\b') { 6 }
      else {
        # Tier 3: unknown lines — trust the stream, but softly:
        # stderr is 'notice' so junk never re-enters the error view
        if .stream == "stderr" { 5 } else { 6 }
      }
      .severity = sev
      .app_name = .container_name
      # Emit a traditional "<pri>tag: message" line for journald's /dev/log:
      # daemon facility (3*8) + severity, no timestamp/hostname — journald
      # then sets PRIORITY and SYSLOG_IDENTIFIER exactly as intended.
      p = to_string(sev + 24)
      tag = to_string(.app_name) ?? ""
      out = replace(to_string(.message), r'\x1b\[[0-9;]*[A-Za-z]', "")
      .message = "<" + p + ">" + tag + ": " + out
      del(.host)

sinks:
  journal:
    type: socket
    inputs: ["classify"]
    mode: unix_datagram
    path: /dev/log
    encoding:
      codec: raw_message
    framing:
      method: bytes
VECTOR_YML
    else
        info "$VECTOR_CONFIG exists: keeping it"
    fi

    # A unit naming a missing docker group would refuse to start.
    docker_group_line="SupplementaryGroups=docker"
    [[ $DOCKER_GROUP == 0 ]] && docker_group_line="# docker group missing: no docker socket access"

    # Our own wizard-written unit (marker comment) is rewritten in full;
    # a foreign one (a distro package's) only gets a drop-in override.
    if [[ ! -f $SERVICE_DIR/vector.service ]] || grep -q "onboard.sh" "$SERVICE_DIR/vector.service"; then
        write_file "$SERVICE_DIR/vector.service" 0644 <<VECTOR_UNIT
# Managed by grafito's onboarding wizard (onboard.sh).
[Unit]
Description=Vector log pipeline for grafito
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
DynamicUser=yes
StateDirectory=vector
${docker_group_line}
ExecStart=${VECTOR_BIN} --config ${VECTOR_CONFIG}
Restart=on-failure
RestartSec=2

# --- Hardening ---
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
VECTOR_UNIT
    else
        # Foreign unit (a distro package's): override the config path
        # and grant docker socket access via a drop-in, nothing else.
        backup_if_exists "$SERVICE_DIR/vector.service.d/99-grafito.conf"
        write_file "$SERVICE_DIR/vector.service.d/99-grafito.conf" 0644 <<VECTOR_DROPIN
# Managed by grafito's onboarding wizard (onboard.sh).
[Service]
ExecStart=
ExecStart=${VECTOR_BIN} --config ${VECTOR_CONFIG}
${docker_group_line}
VECTOR_DROPIN
    fi
}

if [[ $VECTOR == 1 ]]; then
    vector_step
fi

# --- Step: docker default log driver ---
if [[ $DOCKER_LOG_DRIVER == 1 ]]; then
    step "Docker log driver"
    write_file /etc/docker/daemon.json 0644 <<'DAEMON_JSON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
DAEMON_JSON
    info "applies to containers created after the next docker restart (not restarted by this script)"
fi

# --- Step: grafito binary ---
step "Grafito binary"
if [[ $REINSTALL_GRAFITO == 1 ]]; then
    asset="grafito-static-linux-${GRAFITO_ARCH}"
    download "https://github.com/${REPO}/releases/latest/download/${asset}" "${TEMP_DIR}/${asset}"
    if [[ $DRY_RUN == 0 ]]; then
        chmod +x "${TEMP_DIR}/${asset}"
        version="$("${TEMP_DIR}/${asset}" --version 2>/dev/null)" || die "downloaded binary does not run on this machine"
        info "downloaded $version"
        execute install -m 0755 "${TEMP_DIR}/${asset}" "$GRAFITO_BIN"
    else
        echo "++ install -m 0755 ${TEMP_DIR}/${asset} ${GRAFITO_BIN}" >&2
    fi
else
    info "keeping existing $GRAFITO_BIN"
fi

# --- Step: grafito service ---
step "Grafito service"
EXEC_ARGS="--data-dir=${DATA_DIR} --port=${PORT} --bind=${BIND} --homepage-config=${ETC_DIR}/homepage.yml"
[[ -n $STACKS_DIR ]] && EXEC_ARGS="$EXEC_ARGS --stacks-dir=${STACKS_DIR}"
[[ $ENABLE_ACTIONS == 1 ]] && EXEC_ARGS="$EXEC_ARGS --enable-actions"

SUPP_GROUPS="systemd-journal"
[[ $DOCKER_INTEGRATION == 1 && $DOCKER_GROUP == 1 ]] && SUPP_GROUPS="$SUPP_GROUPS docker"

RW_PATHS="${DATA_DIR} ${ETC_DIR}"
[[ -n $STACKS_DIR ]] && RW_PATHS="$RW_PATHS $STACKS_DIR"

MCP_ENV_LINE=""
if [[ $ENABLE_MCP == 1 ]]; then
    if [[ $DRY_RUN == 0 ]]; then
        if command -v openssl > /dev/null 2>&1; then
            MCP_TOKEN="$(openssl rand -hex 24)"
        else
            MCP_TOKEN="$(cat /proc/sys/kernel/random/uuid /proc/sys/kernel/random/uuid | tr -d '-' | tr -d '\n')"
        fi
    else
        MCP_TOKEN="<generated-at-install-time>"
    fi
    MCP_ENV_LINE="Environment=\"GRAFITO_MCP_TOKEN=${MCP_TOKEN}\""
fi

backup_if_exists "$SERVICE_DIR/grafito.service"
write_file "$SERVICE_DIR/grafito.service" 0644 <<GRAFITO_UNIT
# Managed by grafito's onboarding wizard (onboard.sh).
[Unit]
Description=Grafito Log Viewer
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${GRAFITO_USER}
Group=${GRAFITO_GROUP}
SupplementaryGroups=${SUPP_GROUPS}
WorkingDirectory=${DATA_DIR}
ExecStart=${GRAFITO_BIN} ${EXEC_ARGS}
${MCP_ENV_LINE}
Restart=on-failure
RestartSec=2

# --- Network exposure ---
# Bound to ${BIND}: see the bind discussion in the README before
# changing this, and create a login (first-visit wizard) if grafito
# is reachable from other machines.

# --- Hardening ---
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=${RW_PATHS}
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
GRAFITO_UNIT

if [[ $ENABLE_ACTIONS == 1 ]]; then
    write_file /etc/polkit-1/rules.d/49-grafito.rules 0644 <<'POLKIT_RULES'
// Managed by grafito's onboarding wizard (onboard.sh).
// Lets the grafito system user start/stop/restart/enable/disable
// units, which is what --enable-actions needs for its unit buttons.
polkit.addRule(function(action, subject) {
    if (subject.user == "grafito" &&
        action.id.indexOf("org.freedesktop.systemd1.") == 0) {
        return polkit.Result.YES;
    }
});
POLKIT_RULES
fi

# --- Step: enable and verify ---
step "Enable and verify"
execute systemctl daemon-reload
execute systemctl enable grafito.service
execute systemctl restart grafito.service
if [[ $VECTOR == 1 ]]; then
    if [[ $DRY_RUN == 0 ]] && [[ -x $VECTOR_BIN ]]; then
        if "$VECTOR_BIN" validate --no-environment "$VECTOR_CONFIG" > /dev/null 2>&1; then
            info "vector config validates"
        else
            warn "vector config does not validate (docker daemon running?); starting anyway — check with: $VECTOR_BIN validate $VECTOR_CONFIG"
        fi
    fi
    execute systemctl enable vector.service
    if [[ $DRY_RUN == 1 ]]; then
        echo "++ systemctl restart vector.service" >&2
    elif ! systemctl restart vector.service; then
        # Vector failing to start (docker daemon down, socket missing)
        # must not fail the whole onboarding.
        warn "vector.service failed to start (is the docker daemon running?); retry later: systemctl restart vector"
    fi
fi

if [[ $DRY_RUN == 0 ]]; then
    sleep 1
    if systemctl is-active --quiet grafito.service; then
        info "grafito.service is running"
    else
        err "grafito.service did not start: journalctl -u grafito.service -n 30"
        exit 1
    fi
    probe_host="127.0.0.1"
    [[ $BIND == "0.0.0.0" ]] || probe_host="$BIND"
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${probe_host}:${PORT}/" || true)"
    if [[ $code =~ ^[0-9]{3}$ ]]; then
        info "http://${probe_host}:${PORT}/ answers (HTTP $code)"
    else
        warn "no HTTP response on ${probe_host}:${PORT} yet (may still be starting)"
    fi
    if [[ $VECTOR == 1 ]]; then
        if systemctl is-active --quiet vector.service; then
            info "vector.service is running"
        else
            warn "vector.service is not running: journalctl -u vector.service -n 30"
        fi
    fi
fi

# --- Summary ---
step "Done"
cat >&2 <<SUMMARY
Grafito is installed as a systemd service (native, not dockerized).

  URL:            http://${BIND}:${PORT}/
  Service:        systemctl {status,restart} grafito
  Config:         ${SERVICE_DIR}/grafito.service
  Data/settings:  ${DATA_DIR}   (login, timezone, homepage data)
  Homepage file:  ${ETC_DIR}/homepage.yml
SUMMARY
[[ -n $STACKS_DIR ]] && echo "  Stacks dir:     $STACKS_DIR (drop a compose.yml there; it shows up as a stopped stack)" >&2
if [[ $VECTOR == 1 ]]; then
    cat >&2 <<SUMMARY
  Log pipeline:   vector ($VECTOR_CONFIG) -> journald, service: vector
SUMMARY
fi
if [[ -n $MCP_TOKEN ]]; then
    cat >&2 <<SUMMARY
  MCP token:      $MCP_TOKEN
                  (POST ${BIND}:${PORT}/mcp with 'Authorization: Bearer <token>')
SUMMARY
fi
cat >&2 <<'SUMMARY'

Next steps:
  1. Open the URL: the first-visit wizard asks you to create a login.
SUMMARY
if [[ $ENABLE_ACTIONS == 1 ]]; then
    echo "  2. After creating the login, run: systemctl restart grafito  (actions need it)" >&2
    echo "     (the action buttons stay disabled until a login exists)" >&2
fi
if [[ $DOCKER_LOG_DRIVER == 1 ]]; then
    echo "  - Next docker restart picks up json-file+rotation for NEW containers (docker is not restarted by this script)" >&2
fi
if [[ $BIND == "127.0.0.1" ]]; then
    echo "  - From another machine: ssh -L ${PORT}:localhost:${PORT} <this-host>, or put grafito behind a TLS proxy" >&2
fi
echo >&2
info "onboarding complete"
exit 0
