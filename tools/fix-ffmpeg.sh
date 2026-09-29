#!/usr/bin/env bash
#
# fix-ffmpeg.sh - Repair a broken ffmpeg in an EXISTING Xtream UI install.
#
# Symptoms this fixes:
#
#   * Streams never start. The panel shows them as offline, the admin UI gives
#     no useful error, and <panel>/streams/<id>.errors is empty or missing.
#   * dmesg shows:  ffmpeg[NNNN]: segfault at 1ac ... in libc.so.6
#   * The stream source plays fine everywhere else.
#   * stream_logs contains:
#       [segment muxer] Error setting option segment_list_flags to value +live+delete
#
# Two separate causes, both from the panel shipping a 2018 ffmpeg build:
#
#   1. That binary was built against glibc 2.31. On glibc 2.34+ (Ubuntu 22.04+,
#      Debian 12), where libpthread was merged into libc.so.6, it segfaults on
#      any real work. `ffmpeg -version` still succeeds, which is why this is
#      easy to misdiagnose as a problem with the stream source.
#
#   2. The build carried a custom '+delete' flag for the segment muxer. Stock
#      ffmpeg rejects it, the muxer never initialises, and the stream dies at
#      startup.
#
#   sudo ./tools/fix-ffmpeg.sh --detect
#   sudo ./tools/fix-ffmpeg.sh

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/common.sh"

PANEL_HOME="/home/xtreamcodes"
PANEL_PATH="${PANEL_HOME}/iptv_xtream_codes"
SEGMENT_MAX_AGE_MIN="3"
PANEL_NOFILE="300000"
PANEL_NPROC="65535"
FFMPEG_MODE="system"
FFMPEG_BUNDLED_OK=""

DETECT_ONLY="no"
ASSUME_YES="no"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --detect)           DETECT_ONLY="yes"; shift ;;
        --segment-max-age)  SEGMENT_MAX_AGE_MIN="$2"; shift 2 ;;
        --yes|-y)           ASSUME_YES="yes"; shift ;;
        --help|-h)          sed -n '3,30p' "$0"; exit 0 ;;
        *)                  echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../lib/ffmpeg.sh"

require_root
[[ -d "$PANEL_PATH" ]] || die "No installation found at $PANEL_PATH"

# --- Diagnose ---------------------------------------------------------------

log_step "Diagnosis"

verify_bundled_ffmpeg

echo
log_info "Recent kernel segfaults:"
dmesg -T 2>/dev/null | grep -iE "ffmpeg|ffprobe" | tail -3 | sed 's/^/    /' \
    || echo "    (none, or dmesg is restricted)"

echo
log_info "Segment directory:"
if [[ -d "${PANEL_PATH}/streams" ]]; then
    seg_count=$(find "${PANEL_PATH}/streams" -maxdepth 1 -name '*.ts' 2>/dev/null | wc -l)
    seg_size=$(du -sh "${PANEL_PATH}/streams" 2>/dev/null | cut -f1)
    stale=$(find "${PANEL_PATH}/streams" -maxdepth 1 -name '*.ts' -mmin +10 2>/dev/null | wc -l)
    printf '    %s segments, %s total, %s older than 10 minutes\n' \
        "$seg_count" "$seg_size" "$stale"
    if (( stale > 5 )); then
        log_warn "Stale segments are accumulating -- the '+delete' flag is not working."
    fi
fi

echo
log_info "Panel user limits:"
current_nofile=$(runuser -u xtreamcodes -- bash -c 'ulimit -n' 2>/dev/null || echo "?")
printf '    open files: %s\n' "$current_nofile"
[[ "$current_nofile" != "?" ]] && (( current_nofile < 65535 )) \
    && log_warn "Open-file limit is low for a streaming server."

if [[ "$DETECT_ONLY" == "yes" ]]; then
    echo
    if [[ "$FFMPEG_BUNDLED_OK" == "yes" ]]; then
        log_ok "The bundled ffmpeg works. Nothing to repair here."
    else
        log_warn "The bundled ffmpeg is broken. Re-run without --detect to fix it."
    fi
    exit 0
fi

if [[ "$FFMPEG_BUNDLED_OK" == "yes" ]]; then
    log_ok "The bundled ffmpeg passed its test encode."
    confirm "Replace it with the distribution build anyway?" || exit 0
fi

# --- Repair -----------------------------------------------------------------

confirm "Install the distribution ffmpeg, the compatibility wrapper and the segment cleaner?" \
    || { log_info "Aborted."; exit 0; }

install_system_ffmpeg
install_ffmpeg_wrapper
install_segment_cleaner
raise_panel_limits

# --- Restart and verify -----------------------------------------------------

log_step "Restarting the panel"

if systemctl list-unit-files 2>/dev/null | grep -q '^xtreamui.service'; then
    systemctl restart xtreamui
elif [[ -x "${PANEL_PATH}/start_services.sh" ]]; then
    "${PANEL_PATH}/start_services.sh" >/dev/null 2>&1 </dev/null
fi

sleep 8

log_step "Verifying"

running=$(pgrep -xc ffmpeg 2>/dev/null || echo 0)
if (( running > 0 )); then
    log_ok "$running ffmpeg process(es) running."
else
    log_warn "No ffmpeg running yet. Start a stream from the panel and check:"
    log_warn "  ${PANEL_PATH}/streams/<id>.errors"
fi

cat <<EOF

${C_GREEN}Done.${C_RESET}

  Original binary   ${PANEL_PATH}/bin/ffmpeg.original
  Wrapper           ${PANEL_PATH}/bin/ffmpeg
  Segment cleaner   /usr/local/sbin/xtream-clean-segments  (cron, every minute)

  If a stream still fails, the exact command the panel built is recorded in
  /var/log/xtream-ffmpeg-args.log -- compare ORIGINAL against TRANSLATED to
  spot any other option the custom build accepted and stock ffmpeg does not.

EOF
