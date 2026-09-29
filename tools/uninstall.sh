#!/usr/bin/env bash
#
# uninstall.sh - Remove an Xtream UI installation placed by this installer.
#
#   sudo ./tools/uninstall.sh            # keep the database
#   sudo ./tools/uninstall.sh --purge    # remove the database too

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/common.sh"

PANEL_HOME="/home/xtreamcodes"
PANEL_PATH="${PANEL_HOME}/iptv_xtream_codes"
DB_NAME="xtream_iptvpro"
DB_USER="user_iptvpro"

PURGE="no"
ASSUME_YES="no"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --purge)   PURGE="yes"; shift ;;
        --yes|-y)  ASSUME_YES="yes"; shift ;;
        --help|-h) sed -n '3,8p' "$0"; exit 0 ;;
        *)         echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

require_root

log_warn "This removes the panel, its services and its system user."
[[ "$PURGE" == "yes" ]] && log_warn "--purge: the database ${DB_NAME} will be DROPPED."
confirm "Continue?" || exit 0

log_step "Stopping services"
systemctl stop xtreamui 2>/dev/null || true
systemctl disable xtreamui 2>/dev/null || true
rm -f /etc/systemd/system/xtreamui.service
systemctl daemon-reload
pkill -u xtreamcodes 2>/dev/null || true
log_ok "Services stopped."

log_step "Removing scheduled jobs and privileges"
rm -f /etc/cron.d/xtreamui /etc/cron.d/xtream-clean-segments
rm -f /etc/sudoers.d/xtreamui
rm -f /usr/local/sbin/xtreamui-start /usr/local/sbin/xtreamui-stop
rm -f /usr/local/sbin/xtream-clean-segments
rm -f /usr/local/bin/ffmpeg
rm -f /etc/security/limits.d/xtreamcodes.conf
rm -f /var/log/xtream-ffmpeg-args.log
# Clean up the legacy upstream crontab line if it is present.
if grep -q 'start_services\.sh' /etc/crontab 2>/dev/null; then
    backup_file /etc/crontab >/dev/null
    sed -i '/start_services\.sh/d' /etc/crontab
fi
log_ok "Removed."

log_step "Unmounting tmpfs"
umount "${PANEL_PATH}/streams" 2>/dev/null || true
umount "${PANEL_PATH}/tmp" 2>/dev/null || true
if grep -q "$PANEL_PATH" /etc/fstab 2>/dev/null; then
    backup_file /etc/fstab >/dev/null
    sed -i "\|${PANEL_PATH}|d" /etc/fstab
fi
log_ok "Unmounted and removed from fstab."

if [[ "$PURGE" == "yes" ]]; then
    log_step "Dropping the database"
    mysql -u root -e "DROP DATABASE IF EXISTS ${DB_NAME}; DROP USER IF EXISTS '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null \
        && log_ok "Database dropped." \
        || log_warn "Could not drop the database. Do it manually if required."
    rm -f /etc/mysql/mariadb.conf.d/60-xtreamui.cnf
fi

log_step "Removing panel files"
rm -rf "$PANEL_HOME"
userdel xtreamcodes 2>/dev/null || true
groupdel xtreamcodes 2>/dev/null || true
log_ok "Panel removed."

log_step "Cleaning /etc/hosts"
if grep -q 'xtream-codes\.com' /etc/hosts 2>/dev/null; then
    backup_file /etc/hosts >/dev/null
    sed -i '/xtream-codes\.com/d' /etc/hosts
    log_ok "Vendor entries removed."
fi

printf '\n'
log_ok "Uninstall complete."
log_info "Left in place: ufw rules, MariaDB itself, and /root/xtreamui-credentials.txt"
