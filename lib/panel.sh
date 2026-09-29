#!/usr/bin/env bash
# panel.sh - Download, verify and deploy the panel payload.

create_panel_user() {
    log_step "Creating the xtreamcodes system user"

    if id -u xtreamcodes >/dev/null 2>&1; then
        log_ok "User xtreamcodes already exists."
        return 0
    fi

    # --shell /usr/sbin/nologin and --disabled-login: this account must never be
    # usable for an interactive session.
    adduser --system --group --disabled-login \
        --shell /usr/sbin/nologin \
        --home "$PANEL_HOME" \
        xtreamcodes >/dev/null \
        || die "Could not create the xtreamcodes user."

    log_ok "System user xtreamcodes created (no shell, no login)."
}

# Download with integrity verification.
#
# This is the one part of the install that genuinely cannot be made safe by the
# installer alone: the archive contains precompiled nginx, PHP and ffmpeg
# binaries plus obfuscated PHP that will run on this server as a service. All
# an installer can do is let you pin a checksum you verified yourself and refuse
# to proceed if the bytes change.
download_and_verify() {
    local url="$1" dest="$2" expected_sha="${3:-}" label="$4"

    log_info "Downloading $label"
    curl -fSL --progress-bar --max-time 900 -o "$dest" "$url" \
        || die "Download failed: $url"

    local size
    size=$(stat -c%s "$dest")
    (( size > 1024 )) || die "$label is suspiciously small (${size} bytes). Aborting."

    if [[ -n "$expected_sha" ]]; then
        local actual_sha
        actual_sha=$(sha256sum "$dest" | awk '{print $1}')
        if [[ "$actual_sha" != "$expected_sha" ]]; then
            rm -f "$dest"
            log_error "Checksum mismatch for $label"
            log_error "  expected: $expected_sha"
            log_error "  actual:   $actual_sha"
            die "Refusing to install an archive that does not match the pinned checksum."
        fi
        log_ok "$label verified against the pinned SHA256."
    else
        log_warn "$label installed WITHOUT verification. SHA256: $(sha256sum "$dest" | awk '{print $1}')"
        log_warn "Record that checksum and pin it with --tarball-sha256 on future installs."
    fi
}

deploy_panel() {
    log_step "Deploying the panel"

    local tarball="/tmp/xtreamui-panel.tar.gz"

    download_and_verify "$PANEL_TARBALL_URL" "$tarball" \
        "${PANEL_TARBALL_SHA256:-}" "panel archive"

    mkdir -p "$PANEL_HOME"

    log_info "Extracting to $PANEL_HOME"
    tar -xf "$tarball" -C "$PANEL_HOME" || die "Extraction failed."
    rm -f "$tarball"

    [[ -d "$PANEL_PATH" ]] \
        || die "Expected $PANEL_PATH after extraction but it is missing. The archive layout is not what this installer expects."

    log_ok "Panel extracted."
}

apply_panel_update() {
    log_step "Applying the panel update bundle"

    if [[ -z "${PANEL_UPDATE_URL:-}" ]]; then
        log_info "No update bundle configured; skipping."
        return 0
    fi

    local zip="/tmp/xtreamui-update.zip"
    local staging="/tmp/xtreamui-update"

    download_and_verify "$PANEL_UPDATE_URL" "$zip" \
        "${PANEL_UPDATE_SHA256:-}" "update bundle"

    rm -rf "$staging"
    mkdir -p "$staging"
    unzip -qo "$zip" -d "$staging" || die "Could not unpack the update bundle."

    # `|| true`: head can close the pipe before find finishes, and pipefail
    # would turn that SIGPIPE into an aborted install.
    local src
    src=$(find "$staging" -maxdepth 1 -mindepth 1 -type d | head -1) || true
    [[ -n "$src" ]] || src="$staging"

    # Never let the update bundle replace the PHP runtime or the GeoIP database.
    rm -rf "${src}/php" "${src}/GeoLite2.mmdb"

    cp -rf "${src}/." "$PANEL_PATH/"

    rm -rf "$staging" "$zip"
    log_ok "Update bundle applied."
}

install_geolite() {
    log_step "Installing the GeoLite2 database"

    if [[ -z "${GEOLITE_URL:-}" ]]; then
        log_info "No GeoLite2 source configured; skipping."
        return 0
    fi

    local target="${PANEL_PATH}/GeoLite2.mmdb"

    chattr -i "$target" 2>/dev/null || true

    if curl -fsSL --max-time 300 -o "$target" "$GEOLITE_URL"; then
        chown xtreamcodes:xtreamcodes "$target"
        chmod 0444 "$target"
        log_ok "GeoLite2 database installed."
    else
        log_warn "Could not download GeoLite2. GeoIP features will be unavailable."
    fi
}

setup_tmpfs_mounts() {
    log_step "Configuring tmpfs mounts for stream buffers"

    local streams="${PANEL_PATH}/streams"
    local tmp="${PANEL_PATH}/tmp"

    mkdir -p "$streams" "$tmp"

    # Upstream used mode=1777 (world-writable, sticky). These are owned by
    # xtreamcodes and nothing else needs to write to them, so 0750 is enough.
    local opts="defaults,noatime,nosuid,nodev,noexec,mode=0750,uid=$(id -u xtreamcodes),gid=$(id -g xtreamcodes)"

    _add_fstab_entry "$streams" "${opts},size=${TMPFS_STREAMS_SIZE}"
    _add_fstab_entry "$tmp"     "${opts},size=${TMPFS_TMP_SIZE}"

    mount -a || log_warn "mount -a reported an error. Check /etc/fstab."

    log_ok "tmpfs mounted: streams=${TMPFS_STREAMS_SIZE}, tmp=${TMPFS_TMP_SIZE}"
}

_add_fstab_entry() {
    local mountpoint="$1" opts="$2"
    local line="tmpfs ${mountpoint} tmpfs ${opts} 0 0"

    if grep -qF " ${mountpoint} " /etc/fstab; then
        log_info "fstab already has an entry for ${mountpoint}; leaving it alone."
        return 0
    fi

    printf '%s\n' "$line" >>/etc/fstab
}

# ffmpeg setup lives in lib/ffmpeg.sh: the bundled binary has to be tested with
# a real encode before it can be trusted, and replaced when it fails.
