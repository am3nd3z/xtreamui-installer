#!/usr/bin/env bash
# common.sh - Logging, validation and shared helpers.
# Sourced by install.sh and the scripts under tools/.

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
    C_RESET=$'\033[0m'; C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'
    C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'; C_DIM=$'\033[2m'
else
    C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_DIM=''
fi

# Secrets registered here are masked in every log line. The upstream installer
# piped its whole run through `tee`, which left MySQL root and panel passwords
# sitting in cleartext in the log file.
declare -a _SECRETS=()

register_secret() {
    # The explicit return matters: `[[ ... ]] && cmd` as the last statement makes
    # the function exit non-zero whenever the test is false, which aborts any
    # caller running under `set -e`.
    [[ -n "${1:-}" ]] && _SECRETS+=("$1")
    return 0
}

_redact() {
    local text="$1" secret
    for secret in ${_SECRETS[@]+"${_SECRETS[@]}"}; do
        [[ -n "$secret" ]] && text="${text//$secret/********}"
    done
    printf '%s' "$text"
}

_log() {
    local level="$1" color="$2" msg="$3"
    msg="$(_redact "$msg")"
    printf '%s[%s]%s %s\n' "$color" "$level" "$C_RESET" "$msg"
    if [[ -n "${LOG_FILE:-}" ]]; then
        printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg" >>"$LOG_FILE"
    fi
}

log_info()  { _log "INFO" "$C_BLUE"   "$1"; }
log_ok()    { _log " OK " "$C_GREEN"  "$1"; }
log_warn()  { _log "WARN" "$C_YELLOW" "$1"; }
log_error() { _log "FAIL" "$C_RED"    "$1" >&2; }

log_step() {
    printf '\n%s==>%s %s\n' "$C_GREEN" "$C_RESET" "$1"
    if [[ -n "${LOG_FILE:-}" ]]; then
        printf '\n=== %s ===\n' "$1" >>"$LOG_FILE"
    fi
    # Without this, the function returns 1 whenever LOG_FILE is unset -- and
    # under `set -e` that silently kills the caller right after the first
    # heading it prints. The tools/ scripts do not set LOG_FILE.
    return 0
}

die() {
    log_error "$1"
    exit "${2:-1}"
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

# The upstream installer accepted "80910" as a port. nginx then refused to load
# the entire config with `[emerg] invalid port`, so nothing started at all --
# not just the admin panel. Ports are validated up front here.
validate_port() {
    local port="$1" label="$2"

    [[ "$port" =~ ^[0-9]+$ ]] \
        || die "$label: '$port' is not a number. Ports must be 1-65535."

    # Strip leading zeros so 08080 does not get read as octal.
    port=$((10#$port))

    (( port >= 1 && port <= 65535 )) \
        || die "$label: $port is out of range. The maximum TCP port is 65535."

    if (( port < 1024 )); then
        log_warn "$label: $port is a privileged port (<1024)."
    fi

    printf '%s' "$port"
}

# Refuse two services on the same port before we write any config.
validate_ports_unique() {
    local -A seen=()
    local entry name port

    for entry in "$@"; do
        name="${entry%%=*}"
        port="${entry##*=}"
        if [[ -n "${seen[$port]:-}" ]]; then
            die "Port conflict: $name and ${seen[$port]} are both set to $port."
        fi
        seen[$port]="$name"
    done
}

# A port already bound by another service will make nginx fail at start time.
check_port_free() {
    local port="$1" label="$2" holder

    holder=$(ss -tlnp 2>/dev/null | awk -v p=":$port\$" '$4 ~ p {print $6; exit}')
    if [[ -n "$holder" ]]; then
        log_warn "$label ($port) is already in use by: $holder"
        return 1
    fi
    return 0
}

validate_email() {
    local email="$1"
    [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] \
        || die "'$email' does not look like a valid email address."
    printf '%s' "$email"
}

validate_username() {
    local user="$1"
    [[ "$user" =~ ^[A-Za-z0-9_-]{3,32}$ ]] \
        || die "Admin username must be 3-32 chars: letters, digits, _ or -."
    printf '%s' "$user"
}

validate_timezone() {
    local tz="$1"
    [[ -f "/usr/share/zoneinfo/$tz" ]] \
        || die "Unknown timezone '$tz'. See: timedatectl list-timezones"
    printf '%s' "$tz"
}

# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------

gen_password() {
    local length="${1:-24}" raw=""

    # Read a bounded chunk and let tr consume all of it.
    #
    # The obvious form is fatal here:
    #
    #     tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$length"
    #
    # /dev/urandom never ends, so tr never finishes on its own. head closes the
    # pipe once it has its bytes, tr takes a SIGPIPE, and under `set -o
    # pipefail` the pipeline reports 141 and `set -e` aborts the installer --
    # every time, on every machine. Reading a fixed amount up front lets tr
    # exit normally.
    #
    # Filtering discards most bytes, so top up until we have enough.
    while (( ${#raw} < length )); do
        raw+=$(head -c $(( length * 8 )) /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9') || true
    done

    printf '%s' "${raw:0:length}"
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

# Upstream used a single provider (api.sentora.org) which no longer exists. It
# returned an empty string, the installer never checked, and the blank IP was
# written straight into the database -- breaking every generated stream URL.
detect_public_ip() {
    local ip
    local -a providers=(
        "https://api.ipify.org"
        "https://ifconfig.me/ip"
        "https://icanhazip.com"
        "https://ipinfo.io/ip"
    )

    for url in "${providers[@]}"; do
        ip=$(curl -fsS --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            printf '%s' "$ip"
            return 0
        fi
    done

    return 1
}

# ---------------------------------------------------------------------------
# Filesystem
# ---------------------------------------------------------------------------

backup_file() {
    local path="$1"
    [[ -f "$path" ]] || return 0
    local backup="${path}.bak-$(date +%Y%m%d-%H%M%S)"
    cp -a "$path" "$backup"
    log_info "Backed up $path -> $backup"
    printf '%s' "$backup"
}

require_root() {
    [[ $EUID -eq 0 ]] || die "This script must run as root. Use: sudo -i"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

confirm() {
    local prompt="$1"
    [[ "${ASSUME_YES:-no}" == "yes" ]] && return 0

    local answer
    read -r -p "$prompt [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}
