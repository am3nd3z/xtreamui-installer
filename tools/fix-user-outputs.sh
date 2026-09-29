#!/usr/bin/env bash
#
# fix-user-outputs.sh - Grant stream output formats to client lines that have none.
#
# The failure this fixes:
#
#   A client line authenticates fine, the panel shows it active, the stream is
#   running -- and every player refuses to play it. The server answers HTTP 405
#   with an empty body, which tells the player nothing.
#
#   The reason only appears in the client_logs table:
#
#       client_status: USER_DISALLOW_EXT
#       query_string:  username=...&password=...&stream=1&extension=ts
#
#   Client lines take their allowed formats from the user_output table, and the
#   panel assigns none by default. A line created with only HLS ticked cannot
#   play a URL of the form /username/password/id, because nginx rewrites that
#   to extension=ts:
#
#       rewrite ^/(.*)/(.*)/(\d+)$ ...&extension=ts break;
#
#   Which is the same URL the panel's own get.php hands out for output=ts.
#
# Note when testing: the panel caches these permissions. After a change, give it
# two or three minutes before concluding it did not work.
#
#   sudo MYSQL_PWD='...' ./tools/fix-user-outputs.sh --detect
#   sudo MYSQL_PWD='...' ./tools/fix-user-outputs.sh
#   sudo MYSQL_PWD='...' ./tools/fix-user-outputs.sh --user 3 --formats m3u8,ts

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/common.sh"

PANEL_PATH="/home/xtreamcodes/iptv_xtream_codes"
DB_NAME="xtream_iptvpro"
MYSQL_ROOT_PASS="${MYSQL_PWD:-}"
MYSQL_SOCKET=""
LOG_FILE=""

DEFAULT_USER_OUTPUTS="m3u8,ts"
TARGET_USER=""
FORMATS=""
DETECT_ONLY="no"
ASSUME_YES="no"

usage() { sed -n '3,32p' "$0"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)     TARGET_USER="$2"; shift 2 ;;
        --formats)  FORMATS="$2"; shift 2 ;;
        --detect)   DETECT_ONLY="yes"; shift ;;
        --yes|-y)   ASSUME_YES="yes"; shift ;;
        --help|-h)  usage; exit 0 ;;
        *)          echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/database.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/schema.sh"

require_root
[[ -d "$PANEL_PATH" ]] || die "No installation found at $PANEL_PATH"
[[ -n "$MYSQL_ROOT_PASS" ]] \
    || die "Set the MariaDB root password: sudo MYSQL_PWD='...' $0"

FORMATS="${FORMATS:-$DEFAULT_USER_OUTPUTS}"

# --- Report -----------------------------------------------------------------

log_step "Client lines and their output formats"

printf '\n'
mysql_exec "
    SELECT u.id                                   AS id,
           u.username                             AS username,
           u.enabled                              AS enabled,
           IFNULL(GROUP_CONCAT(ao.output_key ORDER BY ao.output_key SEPARATOR ','), '(none)')
                                                  AS formats
    FROM users u
    LEFT JOIN user_output uo ON uo.user_id = u.id
    LEFT JOIN access_output ao ON ao.access_output_id = uo.access_output_id
    GROUP BY u.id, u.username, u.enabled
    ORDER BY u.id;
" "$DB_NAME" | sed 's/^/  /'
printf '\n'

ensure_access_outputs

if report_users_without_outputs; then
    log_ok "Every client line has at least one output format."
    [[ "$DETECT_ONLY" == "yes" ]] && exit 0
    [[ -z "$TARGET_USER" ]] && { log_info "Nothing to do."; exit 0; }
fi

if [[ "$DETECT_ONLY" == "yes" ]]; then
    printf '\n'
    log_info "Re-run without --detect to grant: ${FORMATS}"
    exit 0
fi

# --- Apply ------------------------------------------------------------------

if [[ -n "$TARGET_USER" ]]; then
    confirm "Grant '${FORMATS}' to user id ${TARGET_USER}?" || exit 0
else
    confirm "Grant '${FORMATS}' to every line that currently has none?" || exit 0
fi

log_step "Granting output formats"
grant_user_outputs "$TARGET_USER" "$FORMATS"

log_step "Result"
printf '\n'
mysql_exec "
    SELECT u.id AS id, u.username AS username,
           IFNULL(GROUP_CONCAT(ao.output_key ORDER BY ao.output_key SEPARATOR ','), '(none)') AS formats
    FROM users u
    LEFT JOIN user_output uo ON uo.user_id = u.id
    LEFT JOIN access_output ao ON ao.access_output_id = uo.access_output_id
    GROUP BY u.id, u.username
    ORDER BY u.id;
" "$DB_NAME" | sed 's/^/  /'

cat <<EOF

${C_YELLOW}The panel caches these permissions.${C_RESET}
Wait two or three minutes before testing, and do not conclude it failed before then.

Check what the panel itself believes:

  curl -s "http://127.0.0.1:<client_port>/player_api.php?username=<u>&password=<p>" \\
    | python3 -m json.tool | grep -A4 allowed_output_formats

EOF
