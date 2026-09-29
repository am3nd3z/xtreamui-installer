#!/usr/bin/env bash
#
# apply-branding.sh - Theme the login page of an existing installation.
#
# Makes four targeted insertions into admin/login.php and installs the theme as
# admin/assets/css/xtreamui-brand.css. Every line of authentication logic is
# left exactly as shipped; the result is checked with `php -l` and with a scan
# for the form fields, and the backup is restored automatically if either fails.
#
#   sudo MYSQL_PWD='...' ./tools/apply-branding.sh --brand-name "Pato Player"
#   sudo ./tools/apply-branding.sh --accent '#3B82F6' --no-favicon-change
#   sudo ./tools/apply-branding.sh --restore
#
# Re-running is safe: each insertion is skipped if already present, so only the
# CSS is refreshed. That makes it the way to re-theme after editing colours.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/common.sh"

PANEL_PATH="/home/xtreamcodes/iptv_xtream_codes"
DB_NAME="xtream_iptvpro"
MYSQL_ROOT_PASS="${MYSQL_PWD:-}"
MYSQL_SOCKET=""
LOG_FILE=""

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

RESTORE="no"
ASSUME_YES="no"

usage() { sed -n '3,18p' "$0"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --brand-name)         BRAND_NAME="$2"; shift 2 ;;
        --accent)             BRAND_ACCENT="$2"; shift 2 ;;
        --accent-deep)        BRAND_ACCENT_DEEP="$2"; shift 2 ;;
        --bg-top)             BRAND_BG_TOP="$2"; shift 2 ;;
        --bg-mid)             BRAND_BG_MID="$2"; shift 2 ;;
        --wedge)              BRAND_WEDGE="$2"; shift 2 ;;
        --font-display)       BRAND_FONT_DISPLAY="$2"; shift 2 ;;
        --font-body)          BRAND_FONT_BODY="$2"; shift 2 ;;
        --no-favicon-change)  BRAND_HIDE_FAVICON="no"; shift ;;
        --restore)            RESTORE="yes"; shift ;;
        --yes|-y)             ASSUME_YES="yes"; shift ;;
        --help|-h)            usage; exit 0 ;;
        *)                    echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/database.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/branding.sh"

require_root
[[ -d "$PANEL_PATH" ]] || die "No installation found at $PANEL_PATH"

# --- Restore ----------------------------------------------------------------

if [[ "$RESTORE" == "yes" ]]; then
    log_step "Restoring the stock login page"

    backup=$(ls -1t "${PANEL_PATH}"/admin/login.php.bak-* 2>/dev/null | head -1) || true
    [[ -n "$backup" ]] || die "No backup found at admin/login.php.bak-*"

    cp -a "$backup" "${PANEL_PATH}/admin/login.php"
    log_ok "login.php restored from ${backup}"

    rm -f "$(_brand_css_target)"
    log_ok "Theme CSS removed."

    for f in "${PANEL_PATH}/admin/header.php" "${PANEL_PATH}/admin/header_sidebar.php"; do
        b=$(ls -1t "${f}".bak-* 2>/dev/null | head -1) || true
        [[ -n "$b" ]] && { cp -a "$b" "$f"; log_ok "$(basename "$f") restored."; }
    done
    exit 0
fi

# --- Apply ------------------------------------------------------------------

log_step "Branding"

cat <<EOF

  Panel name    ${BRAND_NAME:-<unchanged>}
  Accent        ${BRAND_ACCENT}  ->  ${BRAND_ACCENT_DEEP}
  Background    ${BRAND_BG_MID}  ->  ${BRAND_BG_TOP}   wedge ${BRAND_WEDGE}
  Fonts         ${BRAND_FONT_DISPLAY} (display) / ${BRAND_FONT_BODY} (UI)
  Tab icon      $( [[ "$BRAND_HIDE_FAVICON" == "yes" ]] && echo "removed everywhere" || echo "left alone" )

EOF

if [[ -n "$BRAND_NAME" && -z "$MYSQL_ROOT_PASS" ]]; then
    die "Setting the panel name needs the database password: sudo MYSQL_PWD='...' $0 ..."
fi

confirm "Apply this?" || { log_info "Aborted."; exit 0; }

# `[[ ... ]] && cmd` as a bare statement returns non-zero when the test is
# false, which under `set -e` would abort the script the moment --brand-name is
# omitted. Use a real if.
if [[ -n "$BRAND_NAME" ]]; then
    set_panel_brand_name
fi

install_brand_css || die "Could not install the theme CSS."
patch_login_page  || die "Could not patch the login page; it was left as shipped."
hide_favicon_everywhere

runuser -u xtreamcodes -- "${PANEL_PATH}/php/bin/php" \
    "${PANEL_PATH}/crons/setup_cache.php" >/dev/null 2>&1 || true

cat <<EOF

${C_GREEN}Done.${C_RESET}

  Theme    ${PANEL_PATH}/admin/assets/css/xtreamui-brand.css
           Edit it directly to retheme -- no PHP involved.

  Reload the page with Ctrl+Shift+R. Browsers cache favicons and stylesheets
  hard, and a stale one will have you chasing a change that already applied.

  To undo:  sudo ./tools/apply-branding.sh --restore

EOF
