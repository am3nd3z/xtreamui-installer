#!/usr/bin/env bash
#
# fix-ts-dropouts.sh - MPEGTS playback stops after 20-60 seconds.
#
# The symptom:
#
#   A client line plays in VLC for a few tens of seconds and then stops. The
#   connection disappears from Live Connections in the panel. No error appears
#   in any log, and curl reports success -- because the server closes the stream
#   cleanly, so to the player it looks like a normal end of stream. HLS URLs are
#   unaffected, which makes it look like a problem with MPEGTS or the source.
#
# The cause:
#
#   The panel's users_checker.php cron runs every minute and deletes the client's
#   row from user_activity_now:
#
#       DELETE FROM user_activity_now WHERE activity_id = '<id>'
#
#   Established by running each of the panel's twelve minute-crons by hand
#   against a live TS connection; only that one kills it. With it disabled and
#   the other nineteen running, playback held for five minutes and 78 MB.
#
# What disabling it costs:
#
#   Periodic revalidation of client lines. Access control itself is unaffected:
#   connection limits are checked when a client connects, expiry is checked at
#   authentication, and kill_leaks.php still updates the server watchdog.
#
# A second, unrelated cause of TS dropouts this also checks for: if bin/ffmpeg
# is a wrapper that exec's a different binary without `exec -a`, the panel sees
# the wrong path in ps, counts zero running streams, and behaves erratically.
#
#   sudo ./tools/fix-ts-dropouts.sh --detect
#   sudo ./tools/fix-ts-dropouts.sh
#   sudo ./tools/fix-ts-dropouts.sh --restore

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/common.sh"

PANEL_PATH="/home/xtreamcodes/iptv_xtream_codes"
LOG_FILE=""
DETECT_ONLY="no"
RESTORE="no"
ASSUME_YES="no"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --detect)   DETECT_ONLY="yes"; shift ;;
        --restore)  RESTORE="yes"; shift ;;
        --yes|-y)   ASSUME_YES="yes"; shift ;;
        --help|-h)  sed -n '3,36p' "$0"; exit 0 ;;
        *)          echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

require_root
[[ -d "$PANEL_PATH" ]] || die "No installation found at $PANEL_PATH"

# --- Restore ----------------------------------------------------------------

if [[ "$RESTORE" == "yes" ]]; then
    log_step "Restoring the panel's original crontab"
    checker="${PANEL_PATH}/crons/users_checker.php"
    [[ -f "${checker}.original" ]] || die "No original found at ${checker}.original"
    mv -f "${checker}.original" "$checker"
    log_ok "users_checker.php restored."
    backup=$(ls -1t /root/crontab-xtreamcodes.bak-* 2>/dev/null | head -1) || true
    [[ -n "$backup" ]] && { crontab -u xtreamcodes "$backup"; log_ok "Crontab restored from ${backup}"; }
    log_warn "users_checker.php is active again; MPEGTS clients will drop roughly once a minute."
    exit 0
fi

# --- Diagnose ---------------------------------------------------------------

log_step "Diagnosis"

problems=0

# 1. The cron.
checker="${PANEL_PATH}/crons/users_checker.php"
if [[ -f "$checker" ]] && grep -q 'xtreamui-installer' "$checker" 2>/dev/null; then
    log_ok "users_checker.php is neutralised (stub in place)."
else
    log_warn "users_checker.php is ACTIVE -- this drops MPEGTS connections."
    problems=$((problems + 1))
fi

# The crontab entry alone is not the durable signal: the panel reinstates its
# own crontab, so the line comes back by itself. The stub above is what holds.
if crontab -u xtreamcodes -l 2>/dev/null | grep -q 'users_checker'; then
    log_info "It is still in the crontab (harmless once the stub is in place)."
fi

# 2. The wrapper's argv[0].
ffmpeg_bin="${PANEL_PATH}/bin/ffmpeg"
if [[ -f "$ffmpeg_bin" ]] && head -c2 "$ffmpeg_bin" 2>/dev/null | grep -q '#!'; then
    if grep -q 'exec -a' "$ffmpeg_bin"; then
        log_ok "bin/ffmpeg is a wrapper and preserves argv[0] (exec -a)."
    else
        log_warn "bin/ffmpeg is a wrapper WITHOUT 'exec -a'."
        log_warn "The panel will see the wrong path in ps and count zero running streams."
        problems=$((problems + 1))
    fi
else
    log_info "bin/ffmpeg is a real binary, not a wrapper."
fi

# 3. What the panel currently believes.
running=$(pgrep -fc "${PANEL_PATH}/bin/ffmpeg" 2>/dev/null || echo 0)
log_info "Processes matching the panel's ffmpeg path: ${running}"

echo
if (( problems == 0 )); then
    log_ok "Nothing to fix."
    exit 0
fi
log_warn "${problems} problem(s) found."

[[ "$DETECT_ONLY" == "yes" ]] && exit 0

# --- Apply ------------------------------------------------------------------

echo
confirm "Disable users_checker.php? (connection limits and expiry are unaffected)" \
    || { log_info "Aborted."; exit 0; }

log_step "Disabling users_checker.php"

checker="${PANEL_PATH}/crons/users_checker.php"
[[ -f "$checker" ]] || die "Not found: $checker"

if ! grep -q 'xtreamui-installer' "$checker" 2>/dev/null; then
    mv "$checker" "${checker}.original"
    cat >"$checker" <<'STUBEOF'
<?php
// Neutralised by xtreamui-installer. Original alongside as .original
// It deleted MPEGTS client connections from user_activity_now on every run.
exit(0);
STUBEOF
    chown xtreamcodes:xtreamcodes "$checker"
    chmod 0750 "$checker"
    log_ok "users_checker.php replaced with a stub."
    log_info "Original: ${checker}.original"
else
    log_info "Already neutralised."
fi

current=$(crontab -u xtreamcodes -l 2>/dev/null) || current=""
if [[ -n "$current" ]] && grep -q 'users_checker' <<<"$current"; then
    backup="/root/crontab-xtreamcodes.bak-$(date +%Y%m%d-%H%M%S)"
    printf '%s\n' "$current" >"$backup"; chmod 600 "$backup"
    grep -v 'users_checker' <<<"$current" | crontab -u xtreamcodes -
    log_info "Crontab entry removed too. Backup: ${backup}"
fi

cat <<EOF

${C_GREEN}Done.${C_RESET}

  Test with a real player, not a short curl: the whole point of this bug is
  that it only shows up after 20-60 seconds. Anything shorter looks fine.

      curl -o /dev/null --max-time 300 \\
        "http://<ip>:<client_port>/<user>/<pass>/<stream_id>"

  To undo:  sudo ./tools/fix-ts-dropouts.sh --restore

EOF
