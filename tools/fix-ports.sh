#!/usr/bin/env bash
#
# fix-ports.sh - Repair port inconsistencies in an EXISTING Xtream UI install.
#
# The upstream installer parameterises the client port but leaves the stock
# values hardcoded in three other places. Choosing any client port other than
# 25461 silently breaks:
#
#   1. RTMP authentication  - nginx_rtmp calls back to 127.0.0.1:25461, where
#                             nothing listens. Every auth attempt fails quietly.
#   2. HTTPS stream URLs    - the database advertises https_broadcast_port 2083
#                             while nginx listens for TLS on 25463.
#   3. RTMP port in the UI  - the database advertises rtmp_port 2086 while
#                             nginx_rtmp listens on 25462.
#
# It also rejects out-of-range ports, which is what breaks nginx entirely.
#
#   sudo ./tools/fix-ports.sh --detect
#   sudo ./tools/fix-ports.sh --admin-port 8091 --client-port 8080

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/common.sh"

PANEL_PATH="/home/xtreamcodes/iptv_xtream_codes"
NGINX_CONF="${PANEL_PATH}/nginx/conf/nginx.conf"
RTMP_CONF="${PANEL_PATH}/nginx_rtmp/conf/nginx.conf"
DB_NAME="xtream_iptvpro"
MYSQL_PORT="7999"
MYSQL_SOCKET=""

ADMIN_PORT=""
CLIENT_PORT=""
RTMP_PORT=""
HTTPS_PORT=""
DETECT_ONLY="no"
ASSUME_YES="no"

usage() {
    cat <<EOF
fix-ports.sh - repair port configuration in an existing Xtream UI install

USAGE
    sudo ./tools/fix-ports.sh --detect
    sudo ./tools/fix-ports.sh [--admin-port N] [--client-port N] [--rtmp-port N] [--https-port N]

OPTIONS
    --detect          Report current state and mismatches, change nothing
    --admin-port N    Set the admin panel port
    --client-port N   Set the client port (also fixes the RTMP callbacks)
    --rtmp-port N     Set the RTMP ingest port
    --https-port N    Set the client TLS port
    --yes             Do not prompt
    --help

Options you omit keep their current value. Every file is backed up first.

DATABASE ACCESS
    Reading and writing the panel database needs the MariaDB root password.
    Pass it in the environment:

        sudo MYSQL_PWD='yourpassword' ./tools/fix-ports.sh --detect

    Without it the nginx side is still checked, but the database columns show
    as '?' and the mismatch report is incomplete.

    Connections use the unix socket, not TCP: the panel's my.cnf sets
    skip-name-resolve=1, which stops 'root'@'localhost' from matching
    connections to 127.0.0.1.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --admin-port)  ADMIN_PORT="$2"; shift 2 ;;
        --client-port) CLIENT_PORT="$2"; shift 2 ;;
        --rtmp-port)   RTMP_PORT="$2"; shift 2 ;;
        --https-port)  HTTPS_PORT="$2"; shift 2 ;;
        --detect)      DETECT_ONLY="yes"; shift ;;
        --yes|-y)      ASSUME_YES="yes"; shift ;;
        --help|-h)     usage; exit 0 ;;
        *)             echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

require_root
[[ -d "$PANEL_PATH" ]] || die "No installation found at $PANEL_PATH"

# --- Read the current state -------------------------------------------------

# Connect over the unix socket, not TCP.
#
# The panel's my.cnf sets skip-name-resolve=1, which makes 'root'@'localhost'
# stop matching TCP connections from 127.0.0.1 -- those need an explicit
# 'root'@'127.0.0.1' grant that does not exist. Connecting over the socket is
# what actually matches the localhost account.
mysql_q() {
    local cnf
    cnf=$(mktemp); chmod 600 "$cnf"
    {
        printf '[client]\nuser=root\n'
        printf 'socket=%s\n' "$MYSQL_SOCKET"
        [[ -n "${MYSQL_PWD:-}" ]] && printf 'password=%s\n' "$MYSQL_PWD"
    } >"$cnf"

    local out rc=0
    out=$(mysql --defaults-extra-file="$cnf" -N -B "$DB_NAME" -e "$1" 2>/dev/null) || rc=$?
    rm -f "$cnf"
    printf '%s' "$out"
    return $rc
}

# Locate the socket before the first query.
detect_mysql_socket() {
    local s
    for s in /run/mysqld/mysqld.sock /var/run/mysqld/mysqld.sock \
             /var/lib/mysql/mysql.sock /tmp/mysql.sock; do
        [[ -S "$s" ]] && { printf '%s' "$s"; return 0; }
    done
    printf '/run/mysqld/mysqld.sock'
}

MYSQL_SOCKET=$(detect_mysql_socket)

log_step "Current configuration"

CUR_ADMIN=$(grep -oP '(?<=listen )\d+(?=;)' "$NGINX_CONF" | sed -n '2p' || true)
CUR_CLIENT=$(grep -oP '(?<=listen )\d+(?=;)' "$NGINX_CONF" | sed -n '1p' || true)
CUR_HTTPS=$(grep -oP '(?<=listen )\d+(?= ssl)' "$NGINX_CONF" | head -1 || true)
CUR_RTMP=$(grep -oP '(?<=listen )\d+(?=;)' "$RTMP_CONF" | head -1 || true)
CUR_CALLBACK=$(grep -oP '(?<=127\.0\.0\.1:|localhost:)\d+(?=/streaming/rtmp\.php)' "$RTMP_CONF" | head -1 || true)

DB_CLIENT=$(mysql_q "SELECT http_broadcast_port FROM streaming_servers WHERE id=1;" || echo "?")
DB_RTMP=$(mysql_q   "SELECT rtmp_port FROM streaming_servers WHERE id=1;" || echo "?")
DB_HTTPS=$(mysql_q  "SELECT https_broadcast_port FROM streaming_servers WHERE id=1;" || echo "?")
DB_IP=$(mysql_q     "SELECT server_ip FROM streaming_servers WHERE id=1;" || echo "?")

cat <<EOF

                    nginx       database
  admin             ${CUR_ADMIN:-?}
  client HTTP       ${CUR_CLIENT:-?}          ${DB_CLIENT:-?}
  client HTTPS      ${CUR_HTTPS:-?}          ${DB_HTTPS:-?}
  rtmp              ${CUR_RTMP:-?}          ${DB_RTMP:-?}
  rtmp callback ->  127.0.0.1:${CUR_CALLBACK:-?}

  server_ip         ${DB_IP:-(empty)}

EOF

# --- Report mismatches ------------------------------------------------------

ISSUES=0
report() { log_warn "$1"; ISSUES=$((ISSUES + 1)); }

for p in "admin:$CUR_ADMIN" "client:$CUR_CLIENT" "rtmp:$CUR_RTMP"; do
    port="${p##*:}"; name="${p%%:*}"
    if [[ "$port" =~ ^[0-9]+$ ]] && (( port > 65535 )); then
        report "$name port $port is out of range. nginx will refuse the entire config."
    fi
done

[[ -n "$CUR_CALLBACK" && "$CUR_CALLBACK" != "$CUR_CLIENT" ]] \
    && report "RTMP callbacks point to :${CUR_CALLBACK} but the client vhost listens on :${CUR_CLIENT}. RTMP auth is broken."

[[ -n "$DB_RTMP" && "$DB_RTMP" != "$CUR_RTMP" ]] \
    && report "Database advertises rtmp_port ${DB_RTMP} but nginx_rtmp listens on ${CUR_RTMP}."

[[ -n "$DB_HTTPS" && -n "$CUR_HTTPS" && "$DB_HTTPS" != "$CUR_HTTPS" ]] \
    && report "Database advertises https_broadcast_port ${DB_HTTPS} but nginx listens on ${CUR_HTTPS}."

[[ -n "$DB_CLIENT" && "$DB_CLIENT" != "$CUR_CLIENT" ]] \
    && report "Database advertises http_broadcast_port ${DB_CLIENT} but nginx listens on ${CUR_CLIENT}."

[[ -z "$DB_IP" || "$DB_IP" == "?" ]] \
    && report "server_ip is empty in the database. Generated stream URLs will be malformed."

if (( ISSUES == 0 )); then
    log_ok "No inconsistencies found."
else
    printf '\n%s%d issue(s) found.%s\n\n' "$C_YELLOW" "$ISSUES" "$C_RESET"
fi

[[ "$DETECT_ONLY" == "yes" ]] && exit 0

# --- Apply ------------------------------------------------------------------

ADMIN_PORT="${ADMIN_PORT:-$CUR_ADMIN}"
CLIENT_PORT="${CLIENT_PORT:-$CUR_CLIENT}"
RTMP_PORT="${RTMP_PORT:-$CUR_RTMP}"
HTTPS_PORT="${HTTPS_PORT:-$CUR_HTTPS}"

ADMIN_PORT=$(validate_port  "$ADMIN_PORT"  "admin port")
CLIENT_PORT=$(validate_port "$CLIENT_PORT" "client port")
[[ -n "$RTMP_PORT"  ]] && RTMP_PORT=$(validate_port  "$RTMP_PORT"  "rtmp port")
[[ -n "$HTTPS_PORT" ]] && HTTPS_PORT=$(validate_port "$HTTPS_PORT" "https port")

validate_ports_unique \
    "admin=$ADMIN_PORT" "client=$CLIENT_PORT" \
    ${RTMP_PORT:+"rtmp=$RTMP_PORT"} ${HTTPS_PORT:+"https=$HTTPS_PORT"}

confirm "Apply admin=$ADMIN_PORT client=$CLIENT_PORT rtmp=$RTMP_PORT https=$HTTPS_PORT ?" \
    || { log_info "Aborted."; exit 0; }

log_step "Applying changes"

backup_file "$NGINX_CONF" >/dev/null
backup_file "$RTMP_CONF"  >/dev/null

# nginx: client vhost is the first listen, admin is the second.
sed -i "0,/listen ${CUR_CLIENT};/s//listen ${CLIENT_PORT};/" "$NGINX_CONF"
sed -i "s/listen ${CUR_ADMIN};/listen ${ADMIN_PORT};/"       "$NGINX_CONF"
[[ -n "$HTTPS_PORT" && -n "$CUR_HTTPS" ]] \
    && sed -i "s/listen ${CUR_HTTPS} ssl;/listen ${HTTPS_PORT} ssl;/" "$NGINX_CONF"

# While we are here: SSLv3 and TLS 1.1 have no business in a config in use.
if grep -q 'ssl_protocols.*SSLv3' "$NGINX_CONF"; then
    sed -i 's/ssl_protocols[^;]*;/ssl_protocols TLSv1.2 TLSv1.3;/' "$NGINX_CONF"
    log_ok "Removed SSLv3 and TLSv1.1 from ssl_protocols."
fi

# nginx_rtmp: the listen port and, critically, the callback port.
[[ -n "$RTMP_PORT" && -n "$CUR_RTMP" ]] \
    && sed -i "s/listen ${CUR_RTMP};/listen ${RTMP_PORT};/" "$RTMP_CONF"

sed -i -E "s|(https?://)(127\.0\.0\.1\|localhost):[0-9]+(/streaming/rtmp\.php)|\1127.0.0.1:${CLIENT_PORT}\3|g" \
    "$RTMP_CONF"
log_ok "RTMP callbacks now point to 127.0.0.1:${CLIENT_PORT}"

# Database: make the advertised ports match reality.
PUBLIC_IP=$(detect_public_ip || echo "")
UPDATE_SQL="UPDATE streaming_servers SET http_broadcast_port=${CLIENT_PORT}"
[[ -n "$RTMP_PORT"  ]] && UPDATE_SQL+=", rtmp_port=${RTMP_PORT}"
[[ -n "$HTTPS_PORT" ]] && UPDATE_SQL+=", https_broadcast_port=${HTTPS_PORT}"
[[ -n "$PUBLIC_IP"  ]] && UPDATE_SQL+=", server_ip='${PUBLIC_IP}'"
UPDATE_SQL+=" WHERE id=1;"

mysql_q "$UPDATE_SQL" >/dev/null && log_ok "Database updated." \
    || log_warn "Database update failed. Set MYSQL_PWD and re-run if root needs a password."

# --- Validate before restarting --------------------------------------------

log_step "Validating"

NGINX_BIN="${PANEL_PATH}/nginx/sbin/nginx"
if [[ -x "$NGINX_BIN" ]]; then
    if out=$("$NGINX_BIN" -t -c "$NGINX_CONF" 2>&1); then
        log_ok "nginx configuration is valid."
    else
        log_error "$out"
        die "Config is invalid. Backups are alongside the originals; nothing was restarted."
    fi
fi

log_step "Restarting"

if systemctl list-unit-files 2>/dev/null | grep -q '^xtreamui.service'; then
    systemctl restart xtreamui
else
    "${PANEL_PATH}/start_services.sh"
fi

sleep 5
log_step "Listening ports"
ss -tlnp | grep -E ":(${ADMIN_PORT}|${CLIENT_PORT}${RTMP_PORT:+|$RTMP_PORT}${HTTPS_PORT:+|$HTTPS_PORT})\b" \
    || log_warn "Expected ports are not bound. Check the panel error log."

log_ok "Done."
