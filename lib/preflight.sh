#!/usr/bin/env bash
# preflight.sh - Everything we check BEFORE touching the system.
#
# The upstream installer discovered problems halfway through and left the box in
# a broken half-installed state. Every check that can fail is done here first.

detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
        OS_CODENAME="${VERSION_CODENAME:-}"
        OS_PRETTY="$PRETTY_NAME"
    else
        die "Cannot read /etc/os-release. Unsupported system."
    fi

    ARCH="$(uname -m)"
    export OS_ID OS_VERSION OS_CODENAME OS_PRETTY ARCH
}

check_supported_os() {
    [[ "$ARCH" == "x86_64" ]] \
        || die "Unsupported architecture: $ARCH. Only x86_64 is supported."

    case "$OS_ID:$OS_VERSION" in
        ubuntu:20.04|ubuntu:22.04|ubuntu:24.04)
            log_ok "Detected $OS_PRETTY ($ARCH)"
            ;;
        debian:11|debian:12)
            log_ok "Detected $OS_PRETTY ($ARCH)"
            ;;
        ubuntu:*|debian:*)
            log_warn "Detected $OS_PRETTY -- not tested with this installer."
            confirm "Continue anyway?" || exit 1
            ;;
        *)
            die "Unsupported OS: $OS_PRETTY. This installer targets Ubuntu 20.04/22.04/24.04 and Debian 11/12."
            ;;
    esac
}

check_not_installed() {
    if [[ -d "$PANEL_PATH" ]]; then
        log_warn "An existing installation was found at $PANEL_PATH"
        if [[ "${FORCE_REINSTALL:-no}" != "yes" ]]; then
            die "Refusing to overwrite it. Re-run with --force to reinstall, or use tools/uninstall.sh first."
        fi
        confirm "This will DESTROY the existing panel and its database. Continue?" \
            || exit 1
    fi
}

check_conflicting_panels() {
    local -a panels=(
        /usr/local/cpanel /usr/local/directadmin /usr/local/solusvm/www
        /usr/local/lxlabs/kloxo /home/zpanel /home/sentora /usr/local/plesk
    )
    local panel
    for panel in "${panels[@]}"; do
        [[ -e "$panel" ]] && die "Another control panel is installed ($panel). Install on a clean system."
    done
}

check_resources() {
    local ram_mb disk_gb
    ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    disk_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9') || true
    [[ -n "$disk_gb" ]] || disk_gb=0

    log_info "RAM: ${ram_mb} MB | Free disk on /: ${disk_gb} GB | CPU cores: $(nproc)"

    (( ram_mb >= 2048 )) \
        || log_warn "Less than 2 GB of RAM. Transcoding will struggle."
    (( disk_gb >= 10 )) \
        || log_warn "Less than 10 GB free on /. The panel plus streams will fill this quickly."

    # The panel mounts a tmpfs sized at a percentage of RAM for stream buffers.
    log_info "A tmpfs of ${TMPFS_STREAMS_SIZE} will be mounted for stream buffers."
}

# Confirm the payload actually exists before we start modifying the system.
# The upstream script blindly ran `tar -xf` on whatever wget produced; when the
# release asset was missing it extracted nothing and carried on regardless.
check_payload_available() {
    log_info "Checking panel payload: $PANEL_TARBALL_URL"

    local http_code
    http_code=$(curl -fsSL -o /dev/null -w '%{http_code}' -I --max-time 20 \
        "$PANEL_TARBALL_URL" 2>/dev/null || echo "000")

    if [[ "$http_code" != "200" ]]; then
        log_error "The panel archive is not reachable (HTTP $http_code)."
        log_error "URL: $PANEL_TARBALL_URL"
        die "Set a working --tarball-url, or host your own copy of the archive."
    fi

    log_ok "Panel archive is reachable."

    if [[ -z "${PANEL_TARBALL_SHA256:-}" ]]; then
        log_warn "No --tarball-sha256 given: the archive will NOT be verified."
        log_warn "It contains precompiled nginx, PHP and ffmpeg binaries that will"
        log_warn "run on this server. Pin a checksum you have verified yourself."
        confirm "Continue without integrity verification?" || exit 1
    fi
}

check_network() {
    curl -fsS --max-time 10 -o /dev/null https://github.com \
        || die "No outbound HTTPS connectivity. The installer needs to download packages."
    log_ok "Outbound connectivity confirmed."
}

# Python 2 is required by the panel's own tooling (config.py, balancer) and was
# dropped from Debian 12 / Ubuntu 24.04 entirely. Fail loudly and early rather
# than at the final step.
check_python2_available() {
    if command -v python2 >/dev/null 2>&1; then
        log_ok "python2 is present: $(python2 --version 2>&1)"
        return 0
    fi

    if apt-cache show python2 >/dev/null 2>&1; then
        log_info "python2 is not installed but is available in the repositories."
        return 0
    fi

    log_warn "python2 is neither installed nor available in the configured repositories."
    log_warn "The panel's config.py and balancer tooling require it."
    confirm "Continue anyway?" || exit 1
}

run_preflight() {
    log_step "Preflight checks"

    require_root
    detect_os
    check_supported_os
    check_conflicting_panels
    check_not_installed
    check_resources
    check_network

    for cmd in curl wget tar systemctl awk sed; do
        require_cmd "$cmd"
    done

    check_python2_available
    check_payload_available

    log_ok "All preflight checks passed."
}
