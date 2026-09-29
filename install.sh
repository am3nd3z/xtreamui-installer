#!/usr/bin/env bash
#
# xtreamui-installer - a clean installer for the Xtream UI IPTV panel
#
# Licensed under the GNU General Public License v3.0, inheriting the licence of
# the upstream installer this replaces.
#
# READ THIS BEFORE RUNNING:
#
# This installer deploys a third-party payload: precompiled nginx, PHP and
# ffmpeg binaries, plus obfuscated PHP source. Nobody outside its authors knows
# what that code does. This script controls HOW it is deployed -- permissions,
# privilege boundaries, network exposure, service management -- but it cannot
# vouch for WHAT is being deployed.
#
# Use --tarball-sha256 to pin an archive you have verified yourself, and treat
# the resulting server as untrusted: isolated, firewalled, and holding nothing
# you would mind losing.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly VERSION="1.0.0"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

PANEL_HOME="/home/xtreamcodes"
PANEL_PATH="${PANEL_HOME}/iptv_xtream_codes"

ADMIN_PORT=""
CLIENT_PORT=""
CLIENT_HTTPS_PORT=""
RTMP_PORT=""
RTMP_STAT_PORT="31210"
ISP_PORT="8805"
MYSQL_PORT="7999"
SSH_PORT=""

ADMIN_USER=""
ADMIN_PASS=""
ADMIN_EMAIL=""
MYSQL_ROOT_PASS=""
DB_PASS=""

DB_NAME="xtream_iptvpro"
DB_USER="user_iptvpro"
# Detected at runtime. All admin queries go over the socket, not TCP, because
# skip-name-resolve stops root@localhost matching 127.0.0.1.
MYSQL_SOCKET=""

TIMEZONE=""
PUBLIC_IP=""
PANEL_DOMAIN=""

# Upstream hardcodes Portuguese (pt_PT.utf8) for every install.
PANEL_LANG="en"
PANEL_LOCALE="en_US.utf8"

ENABLE_HTTPS="yes"
ENABLE_FIREWALL="no"
ALLOW_IPTABLES_CONTROL="no"
ADMIN_ALLOW_IP=""
DB_REMOTE_CIDR=""
FORCE_REINSTALL="no"
ASSUME_YES="no"
DRY_RUN="no"

RATE_LIMIT="20"
RATE_BURST="8"
TMPFS_STREAMS_SIZE="60%"
TMPFS_TMP_SIZE="2G"

# auto   = test the bundled ffmpeg and fall back to the distribution build
# system = always use the distribution build
# bundled = trust the panel's binary without testing (not recommended)
FFMPEG_MODE="auto"
FFMPEG_BUNDLED_OK=""

# distro = Ubuntu/Debian's own ffmpeg package (signed, auto-updated)
# static = John Van Sickle's static build, which the upstream project also
#          redistributes as ffmpeg_v5.0.1_amd64.zip. Newer and not coupled to
#          the host glibc, but an unsigned third-party binary.
FFMPEG_SOURCE="distro"
FFMPEG_STATIC_URL="https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz"
FFMPEG_STATIC_SHA256=""

SEGMENT_MAX_AGE_MIN="3"

# legacy = segment muxer minus the custom '+delete' flag, swept by cron
# hls    = rewrite to the HLS muxer, which deletes its own segments and writes
#          each one atomically via temp_file
SEGMENT_MODE="hls"
HLS_DELETE_THRESHOLD="6"

PANEL_NOFILE="300000"
PANEL_NPROC="65535"

# Stream formats granted to client lines that have none. The panel assigns
# nothing by default, and a line with no formats authenticates and is then
# refused every stream with a bare HTTP 405.
DEFAULT_USER_OUTPUTS="m3u8,ts"

# The panel's users_checker.php cron deletes MPEGTS client connections every
# time it runs, cutting playback after 20-60 seconds with no error logged.
DISABLE_USERS_CHECKER="yes"

# --- Login branding -------------------------------------------------------
# Themes the login page and clears the browser-tab icon. The theme lives in
# admin/assets/css/xtreamui-brand.css on the server, not inline in the PHP.
BRANDING_ENABLED="yes"
BRAND_NAME=""
BRAND_HIDE_FAVICON="yes"

BRAND_FONT_DISPLAY="Oswald"
BRAND_FONT_BODY="Barlow"

BRAND_BG_TOP="#1c1008"
BRAND_BG_MID="#2a1a0d"
BRAND_WEDGE="#4a2c0c"
BRAND_ACCENT="#F5A03C"
BRAND_ACCENT_DEEP="#E07B1E"
BRAND_MUTED="#B3A296"
BRAND_PANEL="#251609"
BRAND_FIELD="#14100b"
BRAND_LINE="rgba(245, 160, 60, .28)"

PANEL_TARBALL_URL=""
PANEL_TARBALL_SHA256=""
PANEL_UPDATE_URL=""
PANEL_UPDATE_SHA256=""
GEOLITE_URL=""

CONFIG_FILE=""
LOG_FILE="/var/log/xtreamui-install.log"
CREDENTIALS_FILE="/root/xtreamui-credentials.txt"

# ---------------------------------------------------------------------------
# Libraries
# ---------------------------------------------------------------------------

for lib in common preflight system database schema panel webserver ffmpeg branding hardening firewall; do
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/lib/${lib}.sh" \
        || { echo "FATAL: cannot load lib/${lib}.sh" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
xtreamui-installer ${VERSION}

USAGE
    sudo ./install.sh [options]
    sudo ./install.sh --config xtreamui.conf

REQUIRED
    --admin-port PORT        Admin panel port          (1-65535)
    --client-port PORT       Client streaming port     (1-65535)
    --admin-user NAME        Panel administrator login
    --email ADDRESS          Administrator email
    --timezone ZONE          e.g. Europe/Madrid
    --tarball-url URL        Panel archive to deploy

LOCALE
    --lang CODE              Panel interface language  (default: en)
    --locale LOCALE          Panel locale             (default: en_US.utf8)
                             Upstream hardcodes pt_PT.utf8 for every install.

PORTS (optional)
    --rtmp-port PORT         RTMP ingest          (default: client-port + 1)
    --https-port PORT        Client TLS port      (default: client-port + 2)
    --mysql-port PORT        MariaDB              (default: 7999, loopback only)

CREDENTIALS (optional; generated securely when omitted)
    --admin-pass PASS        Panel administrator password
    --mysql-pass PASS        MariaDB root password
    --db-pass PASS           Panel database user password

INTEGRITY
    --tarball-sha256 HEX     Pinned checksum of the panel archive.
                             Strongly recommended. Without it you are running
                             whatever the URL happens to serve today.
    --update-url URL         Optional panel update bundle
    --update-sha256 HEX      Its pinned checksum
    --geolite-url URL        Optional GeoLite2 database

NETWORK
    --ip ADDRESS             Override public IP autodetection
    --domain NAME            Panel domain name
    --admin-allow-ip CIDR    Restrict the admin panel to this address
    --db-remote-cidr CIDR    Allow a load balancer to reach MariaDB

SECURITY
    --enable-firewall        Configure ufw (SSH is allowed first, always)
    --allow-iptables-control Let the panel block client IPs via sudo iptables
    --no-https               Do not configure TLS
    --keep-users-checker     Leave the panel's users_checker.php cron enabled.
                             It deletes MPEGTS client connections every time it
                             runs, so playback stops 20-60 seconds in with no
                             error logged anywhere -- the server closes the
                             stream cleanly and the connection vanishes from
                             Live Connections. HLS is unaffected. Disabled by
                             default; access control does not depend on it.

FFMPEG
    --ffmpeg-mode MODE       auto (default) tests the panel's bundled ffmpeg with
                             a real encode and falls back to the distribution
                             build if it fails -- which it does on Ubuntu 22.04+
                             and Debian 12, where it segfaults inside libc.
                             'system' always uses the distribution build;
                             'bundled' trusts the panel's binary untested.
    --ffmpeg-source WHICH    distro (default) uses the signed apt package.
                             static installs a statically linked build -- the
                             same thing upstream ships as ffmpeg_v5.0.1_amd64.zip,
                             which is John Van Sickle's generic build, not a
                             custom Xtream compile. Newer, unaffected by the
                             host glibc, and carries nonfree encoders such as
                             libfdk-aac; unsigned and outside apt.
    --segment-mode MODE      How segment rotation is handled.
                             'hls' (default) rewrites the panel's segment-muxer
                             command to the HLS muxer, which deletes its own
                             segments and writes each one to .tmp before
                             renaming -- so a client can never fetch a
                             half-written segment.
                             'legacy' keeps the segment muxer (minus the custom
                             '+delete' flag no stock ffmpeg has) and sweeps the
                             directory with a cron instead.
    --hls-delete-threshold N Segment windows kept beyond the live playlist in
                             hls mode (default: 6). The panel serves MPEGTS by
                             reading these same files, so ffmpeg's default of 1
                             leaves a lagging TS client reading a deleted file.
    --segment-max-age MIN    In legacy mode, delete segments older than this
                             (default: 3). No stock ffmpeg implements the custom
                             '+delete' flag -- verified against the distribution
                             package and the static build alike -- so without
                             one of these two mechanisms the streams tmpfs fills
                             at roughly 14 MB/min per stream.

OTHER
    --config FILE            Read options from a config file
    --force                  Overwrite an existing installation
    --yes                    Do not prompt for confirmation
    --dry-run                Validate everything, change nothing
    --help                   This message

EXAMPLE
    sudo ./install.sh \\
        --admin-port 8091 \\
        --client-port 8080 \\
        --admin-user admin \\
        --email you@example.com \\
        --timezone Europe/Madrid \\
        --tarball-url https://your.host/xui-ubuntu-22.04.tar.gz \\
        --tarball-sha256 abc123... \\
        --admin-allow-ip 203.0.113.10 \\
        --enable-firewall

EOF
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --admin-port)        ADMIN_PORT="$2"; shift 2 ;;
            --client-port)       CLIENT_PORT="$2"; shift 2 ;;
            --rtmp-port)         RTMP_PORT="$2"; shift 2 ;;
            --https-port)        CLIENT_HTTPS_PORT="$2"; shift 2 ;;
            --mysql-port)        MYSQL_PORT="$2"; shift 2 ;;
            --admin-user)        ADMIN_USER="$2"; shift 2 ;;
            --admin-pass)        ADMIN_PASS="$2"; shift 2 ;;
            --email)             ADMIN_EMAIL="$2"; shift 2 ;;
            --mysql-pass)        MYSQL_ROOT_PASS="$2"; shift 2 ;;
            --db-pass)           DB_PASS="$2"; shift 2 ;;
            --timezone)          TIMEZONE="$2"; shift 2 ;;
            --ip)                PUBLIC_IP="$2"; shift 2 ;;
            --domain)            PANEL_DOMAIN="$2"; shift 2 ;;
            --tarball-url)       PANEL_TARBALL_URL="$2"; shift 2 ;;
            --tarball-sha256)    PANEL_TARBALL_SHA256="$2"; shift 2 ;;
            --update-url)        PANEL_UPDATE_URL="$2"; shift 2 ;;
            --update-sha256)     PANEL_UPDATE_SHA256="$2"; shift 2 ;;
            --geolite-url)       GEOLITE_URL="$2"; shift 2 ;;
            --admin-allow-ip)    ADMIN_ALLOW_IP="$2"; shift 2 ;;
            --db-remote-cidr)    DB_REMOTE_CIDR="$2"; shift 2 ;;
            --enable-firewall)   ENABLE_FIREWALL="yes"; shift ;;
            --allow-iptables-control) ALLOW_IPTABLES_CONTROL="yes"; shift ;;
            --no-https)          ENABLE_HTTPS="no"; shift ;;
            --keep-users-checker) DISABLE_USERS_CHECKER="no"; shift ;;
            --no-branding)       BRANDING_ENABLED="no"; shift ;;
            --brand-name)        BRAND_NAME="$2"; shift 2 ;;
            --brand-accent)      BRAND_ACCENT="$2"; shift 2 ;;
            --keep-favicon)      BRAND_HIDE_FAVICON="no"; shift ;;
            --ffmpeg-mode)       FFMPEG_MODE="$2"; shift 2 ;;
            --ffmpeg-source)     FFMPEG_SOURCE="$2"; shift 2 ;;
            --segment-max-age)   SEGMENT_MAX_AGE_MIN="$2"; shift 2 ;;
            --segment-mode)      SEGMENT_MODE="$2"; shift 2 ;;
            --hls-delete-threshold) HLS_DELETE_THRESHOLD="$2"; shift 2 ;;
            --lang)              PANEL_LANG="$2"; shift 2 ;;
            --locale)            PANEL_LOCALE="$2"; shift 2 ;;
            --config)            CONFIG_FILE="$2"; shift 2 ;;
            --force)             FORCE_REINSTALL="yes"; shift ;;
            --yes|-y)            ASSUME_YES="yes"; shift ;;
            --dry-run)           DRY_RUN="yes"; shift ;;
            --help|-h)           usage; exit 0 ;;
            *)                   echo "Unknown option: $1" >&2; usage; exit 1 ;;
        esac
    done
}

load_config_file() {
    [[ -z "$CONFIG_FILE" ]] && return 0
    [[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"

    # Only accept KEY=VALUE lines; never source arbitrary shell.
    local line key value
    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        [[ "$line" != *=* ]] && continue

        key="${line%%=*}"
        value="${line#*=}"
        value="${value%\"}"; value="${value#\"}"
        value="${value%\'}"; value="${value#\'}"

        case "$key" in
            ADMIN_PORT|CLIENT_PORT|RTMP_PORT|CLIENT_HTTPS_PORT|MYSQL_PORT|\
            ADMIN_USER|ADMIN_PASS|ADMIN_EMAIL|MYSQL_ROOT_PASS|DB_PASS|\
            TIMEZONE|PUBLIC_IP|PANEL_DOMAIN|PANEL_TARBALL_URL|PANEL_TARBALL_SHA256|\
            PANEL_UPDATE_URL|PANEL_UPDATE_SHA256|GEOLITE_URL|ADMIN_ALLOW_IP|\
            DB_REMOTE_CIDR|ENABLE_FIREWALL|ENABLE_HTTPS|ALLOW_IPTABLES_CONTROL|\
            TMPFS_STREAMS_SIZE|TMPFS_TMP_SIZE|RATE_LIMIT|RATE_BURST|\
            FFMPEG_MODE|FFMPEG_SOURCE|FFMPEG_STATIC_URL|FFMPEG_STATIC_SHA256|\
            SEGMENT_MODE|HLS_DELETE_THRESHOLD|SEGMENT_MAX_AGE_MIN|PANEL_NOFILE|PANEL_NPROC|PANEL_LANG|PANEL_LOCALE|\
            BRANDING_ENABLED|BRAND_NAME|BRAND_HIDE_FAVICON|BRAND_FONT_DISPLAY|BRAND_FONT_BODY|BRAND_BG_TOP|BRAND_BG_MID|BRAND_WEDGE|BRAND_ACCENT|BRAND_ACCENT_DEEP|BRAND_MUTED|BRAND_PANEL|BRAND_FIELD|BRAND_LINE|DISABLE_USERS_CHECKER|DEFAULT_USER_OUTPUTS)
                printf -v "$key" '%s' "$value"
                ;;
            *)
                log_warn "Ignoring unknown config key: $key"
                ;;
        esac
    done <"$CONFIG_FILE"

    log_ok "Loaded configuration from $CONFIG_FILE"
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

validate_inputs() {
    log_step "Validating configuration"

    [[ -n "$ADMIN_PORT"        ]] || die "--admin-port is required."
    [[ -n "$CLIENT_PORT"       ]] || die "--client-port is required."
    [[ -n "$ADMIN_USER"        ]] || die "--admin-user is required."
    [[ -n "$ADMIN_EMAIL"       ]] || die "--email is required."
    [[ -n "$TIMEZONE"          ]] || die "--timezone is required."
    [[ -n "$PANEL_TARBALL_URL" ]] || die "--tarball-url is required."

    # This is the check whose absence upstream caused a total install failure:
    # 80910 was accepted, written into nginx.conf, and nginx then refused the
    # whole config file with [emerg] invalid port -- so nothing started at all.
    ADMIN_PORT=$(validate_port  "$ADMIN_PORT"  "--admin-port")
    CLIENT_PORT=$(validate_port "$CLIENT_PORT" "--client-port")
    MYSQL_PORT=$(validate_port  "$MYSQL_PORT"  "--mysql-port")

    [[ -n "$RTMP_PORT" ]]         || RTMP_PORT=$((CLIENT_PORT + 1))
    [[ -n "$CLIENT_HTTPS_PORT" ]] || CLIENT_HTTPS_PORT=$((CLIENT_PORT + 2))

    RTMP_PORT=$(validate_port         "$RTMP_PORT"         "--rtmp-port")
    CLIENT_HTTPS_PORT=$(validate_port "$CLIENT_HTTPS_PORT" "--https-port")
    RTMP_STAT_PORT=$(validate_port    "$RTMP_STAT_PORT"    "rtmp stat port")
    ISP_PORT=$(validate_port          "$ISP_PORT"          "isp port")

    validate_ports_unique \
        "admin=$ADMIN_PORT" \
        "client=$CLIENT_PORT" \
        "rtmp=$RTMP_PORT" \
        "https=$CLIENT_HTTPS_PORT" \
        "mysql=$MYSQL_PORT" \
        "isp=$ISP_PORT" \
        "rtmp-stat=$RTMP_STAT_PORT"

    ADMIN_USER=$(validate_username  "$ADMIN_USER")
    ADMIN_EMAIL=$(validate_email    "$ADMIN_EMAIL")
    TIMEZONE=$(validate_timezone    "$TIMEZONE")

    case "$FFMPEG_MODE" in
        auto|system|bundled) ;;
        *) die "--ffmpeg-mode must be one of: auto, system, bundled (got '$FFMPEG_MODE')." ;;
    esac

    case "$FFMPEG_SOURCE" in
        distro|static) ;;
        *) die "--ffmpeg-source must be one of: distro, static (got '$FFMPEG_SOURCE')." ;;
    esac

    [[ "$PANEL_LANG" =~ ^[a-z]{2}$ ]] \
        || die "--lang must be a two-letter code, e.g. en or es (got '$PANEL_LANG')."

    [[ "$SEGMENT_MAX_AGE_MIN" =~ ^[0-9]+$ ]] && (( SEGMENT_MAX_AGE_MIN >= 1 )) \
        || die "--segment-max-age must be a positive integer (minutes)."

    case "$SEGMENT_MODE" in
        hls|legacy) ;;
        *) die "--segment-mode must be one of: hls, legacy (got '$SEGMENT_MODE')." ;;
    esac

    [[ "$HLS_DELETE_THRESHOLD" =~ ^[0-9]+$ ]] && (( HLS_DELETE_THRESHOLD >= 1 )) \
        || die "--hls-delete-threshold must be a positive integer."

    SSH_PORT=$(detect_ssh_port)

    local conflicts=0
    for spec in "admin:$ADMIN_PORT" "client:$CLIENT_PORT" "rtmp:$RTMP_PORT"; do
        check_port_free "${spec##*:}" "${spec%%:*}" || conflicts=$((conflicts + 1))
    done
    (( conflicts == 0 )) || confirm "Ports are already in use. Continue anyway?" || exit 1

    log_ok "Ports validated: admin=$ADMIN_PORT client=$CLIENT_PORT rtmp=$RTMP_PORT https=$CLIENT_HTTPS_PORT"
}

resolve_ip() {
    if [[ -n "$PUBLIC_IP" ]]; then
        log_ok "Using the IP provided on the command line: $PUBLIC_IP"
        return 0
    fi

    log_info "Detecting the public IP address"

    # Upstream trusted a single endpoint that no longer exists, never checked
    # the result, and wrote an empty string into the database.
    if PUBLIC_IP=$(detect_public_ip); then
        log_ok "Public IP detected: $PUBLIC_IP"
    else
        die "Could not determine the public IP from any provider. Pass it explicitly with --ip"
    fi
}

generate_secrets() {
    [[ -n "$ADMIN_PASS"      ]] || { ADMIN_PASS=$(gen_password 20);      log_info "Generated an admin password."; }
    [[ -n "$MYSQL_ROOT_PASS" ]] || { MYSQL_ROOT_PASS=$(gen_password 32); log_info "Generated a MariaDB root password."; }
    [[ -n "$DB_PASS"         ]] || { DB_PASS=$(gen_password 32);         log_info "Generated a panel database password."; }

    STREAM_PASS=$(gen_password 20)
    UNIQUE_ID=$(gen_password 10)
    CRYPT_LB=$(gen_password 20)

    # Keep every secret out of the log file.
    register_secret "$ADMIN_PASS"
    register_secret "$MYSQL_ROOT_PASS"
    register_secret "$DB_PASS"
    register_secret "$STREAM_PASS"
    register_secret "$CRYPT_LB"
}

size_database() {
    local ram_mb
    ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)

    # Upstream hardcoded innodb_buffer_pool_size = 10G regardless of the host,
    # which simply fails to start on a machine with less RAM than that.
    DB_BUFFER_POOL_SIZE="$(( ram_mb / 4 ))M"
    DB_TMP_TABLE_SIZE="$(( ram_mb / 16 ))M"

    if   (( ram_mb >= 16384 )); then DB_MAX_CONNECTIONS=20000
    elif (( ram_mb >= 8192  )); then DB_MAX_CONNECTIONS=10000
    elif (( ram_mb >= 4096  )); then DB_MAX_CONNECTIONS=5000
    else                             DB_MAX_CONNECTIONS=2000
    fi
}

show_summary() {
    cat <<EOF

${C_GREEN}Installation plan${C_RESET}

  System        ${OS_PRETTY} (${ARCH})
  Public IP     ${PUBLIC_IP}
  Timezone      ${TIMEZONE}

  Admin panel   ${ADMIN_PORT}${ADMIN_ALLOW_IP:+  (restricted to ${ADMIN_ALLOW_IP})}
  Clients       ${CLIENT_PORT} (HTTP)$( [[ "$ENABLE_HTTPS" == "yes" ]] && printf ', %s (HTTPS)' "$CLIENT_HTTPS_PORT" )
  RTMP          ${RTMP_PORT}
  MariaDB       ${MYSQL_PORT} (loopback only)
  ISP module    ${ISP_PORT} (loopback only)

  Admin user    ${ADMIN_USER}
  Email         ${ADMIN_EMAIL}

  Firewall      $( [[ "$ENABLE_FIREWALL" == "yes" ]] && echo "ufw, configured" || echo "NOT configured" )
  Panel sudo    $( [[ "$ALLOW_IPTABLES_CONTROL" == "yes" ]] && echo "iptables + chattr" || echo "none" )
  Archive       $( [[ -n "$PANEL_TARBALL_SHA256" ]] && echo "checksum pinned" || echo "${C_YELLOW}UNVERIFIED${C_RESET}" )
  ffmpeg        ${FFMPEG_MODE} / ${FFMPEG_SOURCE} (segments pruned after ${SEGMENT_MAX_AGE_MIN} min)
  Locale        ${PANEL_LANG} / ${PANEL_LOCALE}

EOF
}

write_credentials() {
    umask 077
    cat >"$CREDENTIALS_FILE" <<EOF
Xtream UI - installed $(date '+%Y-%m-%d %H:%M:%S')
================================================================

  Panel URL     http://${PUBLIC_IP}:${ADMIN_PORT}
  Username      ${ADMIN_USER}
  Password      ${ADMIN_PASS}
  Email         ${ADMIN_EMAIL}

  Client HTTP   ${CLIENT_PORT}
  Client HTTPS  ${CLIENT_HTTPS_PORT}
  RTMP          ${RTMP_PORT}

  MariaDB root  ${MYSQL_ROOT_PASS}
  DB user       ${DB_USER} / ${DB_PASS}
  DB name       ${DB_NAME}
  DB port       ${MYSQL_PORT} (127.0.0.1 only)

================================================================
This file is mode 0600. Move these credentials to a password
manager and delete it.

Change the panel password on first login.
EOF
    chmod 0600 "$CREDENTIALS_FILE"
}

print_result() {
    cat <<EOF

${C_GREEN}================================================================${C_RESET}
${C_GREEN}  Installation complete${C_RESET}
${C_GREEN}================================================================${C_RESET}

  Panel     http://${PUBLIC_IP}:${ADMIN_PORT}
  User      ${ADMIN_USER}
  Password  ${ADMIN_PASS}

  Credentials saved to ${CREDENTIALS_FILE} (mode 0600)

  Service   systemctl status xtreamui
  Logs      journalctl -u xtreamui -f
            ${PANEL_PATH}/logs/error.log
            ${PANEL_PATH}/streams/<id>.errors   (per-stream ffmpeg errors)
            /var/log/xtream-ffmpeg-args.log     (first ffmpeg command seen)

EOF

    [[ "$ENABLE_FIREWALL" != "yes" ]] && print_firewall_commands

    cat <<EOF
${C_YELLOW}Reminders${C_RESET}
  1. Change the admin password on first login.
  2. Move the credentials out of ${CREDENTIALS_FILE} and delete it.
  3. The panel code is obfuscated and unaudited. Treat this host as untrusted.
$( [[ -z "$PANEL_TARBALL_SHA256" ]] && printf '  4. Record the archive checksum printed above and pin it next time.\n' )
EOF
}

# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------

on_error() {
    local exit_code=$? line=$1
    log_error "Failed at line ${line} (exit ${exit_code})."
    log_error "Log: ${LOG_FILE}"
    log_error "The system may be partially configured. Review before re-running."
    exit "$exit_code"
}

trap 'on_error $LINENO' ERR

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    parse_args "$@"

    require_root
    : >"$LOG_FILE"
    chmod 0600 "$LOG_FILE"

    printf '\n%sxtreamui-installer %s%s\n' "$C_GREEN" "$VERSION" "$C_RESET"

    load_config_file
    validate_inputs
    run_preflight
    resolve_ip
    generate_secrets
    size_database

    show_summary

    if [[ "$DRY_RUN" == "yes" ]]; then
        log_ok "Dry run complete. Nothing was changed."
        exit 0
    fi

    confirm "Proceed with the installation?" || { log_info "Aborted."; exit 0; }

    setup_timezone
    install_base_packages
    install_python2
    install_legacy_openssl
    install_ffmpeg_deps
    install_mariadb

    create_panel_user
    deploy_panel
    apply_panel_update
    install_geolite

    configure_mariadb
    secure_mariadb_root
    create_panel_database
    create_panel_db_user

    write_nginx_conf
    write_nginx_rtmp_conf
    configure_php

    # Primary keys and settings rows the panel's own database.sql omits. Upstream
    # intends to apply these but its SQL file aborts on a syntax error partway
    # through, leaving the install half-configured and reporting success.
    apply_schema_fixes

    register_main_server
    configure_panel_settings
    create_admin_user
    write_panel_config
    verify_schema

    setup_tmpfs_mounts

    # Must run before permissions are locked down: it may replace bin/ffmpeg.
    setup_ffmpeg

    set_panel_permissions
    configure_sudoers
    block_vendor_callbacks

    install_service_launcher
    install_systemd_service
    install_panel_cron
    disable_broken_panel_crons
    apply_branding

    test_nginx_config

    log_step "Starting services"
    systemctl start xtreamui || die "Services failed to start. Check: journalctl -u xtreamui -n 50"
    sleep 5
    systemctl is-active --quiet xtreamui \
        && log_ok "xtreamui is running." \
        || log_warn "xtreamui is not active. Check: journalctl -u xtreamui -n 50"

    verify_no_world_writable
    restrict_postfix
    configure_firewall

    write_credentials
    print_result
}

main "$@"
