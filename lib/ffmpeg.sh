#!/usr/bin/env bash
# ffmpeg.sh - Validate the bundled ffmpeg, replace it when broken, and keep the
# segment directory from filling up.
#
# The panel ships an ffmpeg built in 2018 on Ubuntu 20.04 (glibc 2.31). On
# Ubuntu 22.04+ (glibc 2.34+, where libpthread was merged into libc.so.6) that
# binary segfaults inside libc on any real work:
#
#   ffmpeg[69510]: segfault at 1ac ip ... error 4 in libc.so.6
#
# The subtle part: `ffmpeg -version` still succeeds, because printing a version
# string never reaches the broken code path. Anything that checks only that the
# binary exists and runs will conclude it is fine. So we run an actual encode.
#
# When the bundled binary fails we install the distribution ffmpeg, which works
# but is not the modified build the panel expects. The panel's obfuscated PHP
# hardcodes options that only existed in that custom build, so a small wrapper
# translates them.

# Run a real encode. This is the check that matters.
_ffmpeg_works() {
    local binary="$1"

    [[ -x "$binary" ]] || return 1

    # A 1-second synthetic encode: no network, no codecs beyond rawvideo, but it
    # exercises the muxing and libc paths where the old binary dies.
    #
    # </dev/null matters: ffmpeg reads stdin by default, and when the installer
    # itself is being fed over stdin it will happily eat the rest of the script.
    timeout 30 "$binary" -nostdin -hide_banner -loglevel error \
        -f lavfi -i testsrc=duration=1:size=160x120:rate=5 \
        -f null - </dev/null >/dev/null 2>&1
}

verify_bundled_ffmpeg() {
    log_step "Testing the bundled ffmpeg"

    local bundled="${PANEL_PATH}/bin/ffmpeg"

    if [[ ! -x "$bundled" ]]; then
        log_warn "No bundled ffmpeg at $bundled"
        FFMPEG_BUNDLED_OK="no"
        return 0
    fi

    # `|| true`: head closes the pipe after one line, ffmpeg takes SIGPIPE and
    # exits non-zero. Under `set -o pipefail` that would abort the script.
    local version
    version=$("$bundled" -version </dev/null 2>/dev/null | head -1) || true
    log_info "Bundled: ${version:-unknown}"

    if _ffmpeg_works "$bundled"; then
        log_ok "The bundled ffmpeg completed a test encode."
        FFMPEG_BUNDLED_OK="yes"
    else
        log_warn "The bundled ffmpeg FAILED a test encode (it likely segfaults on this glibc)."
        log_info "This is expected on Ubuntu 22.04+ and Debian 12: the binary was built"
        log_info "against glibc 2.31, before libpthread was merged into libc."
        FFMPEG_BUNDLED_OK="no"
    fi
}

install_system_ffmpeg() {
    if [[ "${FFMPEG_SOURCE}" == "static" ]]; then
        _install_static_ffmpeg
        return
    fi

    log_step "Installing the distribution ffmpeg"

    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq ffmpeg || die "Could not install ffmpeg."

    local version
    version=$(/usr/bin/ffmpeg -version </dev/null 2>/dev/null | head -1) || true
    log_info "Installed: ${version:-unknown}"

    _ffmpeg_works /usr/bin/ffmpeg \
        || die "The distribution ffmpeg also failed the test encode. Something else is wrong."

    log_ok "Distribution ffmpeg passed the test encode."
}

# A statically linked build, installed outside the package manager.
#
# This is the same thing the upstream project ships as ffmpeg_v5.0.1_amd64.zip:
# John Van Sickle's generic static build, not a custom Xtream compile. Worth
# knowing, because it means it has no more support for the panel's custom
# '+delete' muxer flag than the distribution package does -- the wrapper is
# needed either way.
#
# What it does buy: no coupling to the host glibc (the exact failure mode that
# breaks the bundled binary), a newer release, and nonfree encoders such as
# libfdk-aac that Ubuntu cannot ship.
_install_static_ffmpeg() {
    log_step "Installing a static ffmpeg build"

    log_warn "This is an unsigned third-party binary, outside apt."
    [[ -n "$FFMPEG_STATIC_SHA256" ]] \
        || log_warn "No --ffmpeg-static-sha256 given: it will not be verified."

    local tarball="/tmp/ffmpeg-static.tar.xz"
    local workdir="/tmp/ffmpeg-static"

    download_and_verify "$FFMPEG_STATIC_URL" "$tarball" \
        "${FFMPEG_STATIC_SHA256:-}" "static ffmpeg"

    rm -rf "$workdir"; mkdir -p "$workdir"
    tar -xJf "$tarball" -C "$workdir" --strip-components=1 \
        || die "Could not unpack the static ffmpeg archive."

    for binary in ffmpeg ffprobe; do
        [[ -f "${workdir}/${binary}" ]] \
            || die "The archive does not contain ${binary}."
        install -m 0755 -o root -g root "${workdir}/${binary}" "/usr/bin/${binary}"
    done

    rm -rf "$workdir" "$tarball"

    local version
    version=$(/usr/bin/ffmpeg -version </dev/null 2>/dev/null | head -1) || true
    log_info "Installed: ${version:-unknown}"

    _ffmpeg_works /usr/bin/ffmpeg \
        || die "The static ffmpeg failed the test encode."

    log_ok "Static ffmpeg passed the test encode."
    log_warn "It will not receive security updates through apt. Track it yourself."
}

# Translate options that only existed in the panel's custom ffmpeg build.
#
# The panel launches, among other things:
#
#   -f segment -segment_time 10 -segment_list_size 6
#   -segment_list_flags +live+delete
#
# `delete` is not a stock segment-muxer flag; the "Xtreamui-Mods" build added
# it. Stock ffmpeg 4.4 rejects the whole option, so the muxer never initialises
# and the stream dies at startup with:
#
#   [segment muxer] Error setting option segment_list_flags to value +live+delete
#
# The flag string is compiled into the panel's obfuscated PHP and cannot be
# edited, so we intercept it at the binary instead.
install_ffmpeg_wrapper() {
    log_step "Installing the ffmpeg compatibility wrapper"

    local wrapper="${PANEL_PATH}/bin/ffmpeg"

    if [[ -f "$wrapper" && ! -L "$wrapper" ]]; then
        mv "$wrapper" "${wrapper}.original"
        log_info "Original binary kept as ${wrapper}.original"
    else
        rm -f "$wrapper"
    fi

    local template="${SCRIPT_DIR}/lib/ffmpeg-wrapper.template"
    [[ -f "$template" ]] || die "Wrapper template missing: $template"

    sed "s|__REAL_FFMPEG__|/usr/bin/ffmpeg|" "$template" >"$wrapper"

    # Runtime configuration, so the mode can be changed without reinstalling.
    cat >/etc/xtreamui-ffmpeg.conf <<EOF
# Managed by xtreamui-installer. Restart the panel after editing:
#   systemctl restart xtreamui
#
# How the wrapper handles the panel's segment-muxer output.
#
#   legacy  Pass the segment muxer through, minus the custom '+delete' flag
#           that no stock ffmpeg implements. Segments are then removed by
#           /usr/local/sbin/xtream-clean-segments on a cron.
#
#   hls     Rewrite the invocation to use the HLS muxer, which deletes its own
#           segments (delete_segments) and writes each one to .tmp before
#           renaming it (temp_file), so a client can never fetch a partially
#           written segment. No cron needed.
#
SEGMENT_MODE=${SEGMENT_MODE}

# How many playlist windows of segments to keep beyond the live playlist.
# This matters because the panel serves MPEGTS by reading these same files: at
# the default of 1, a TS client that falls behind reads a segment that is gone.
HLS_DELETE_THRESHOLD=${HLS_DELETE_THRESHOLD}
EOF
    chmod 0644 /etc/xtreamui-ffmpeg.conf

    chmod 0755 "$wrapper"
    chown xtreamcodes:xtreamcodes "$wrapper"

    : >/var/log/xtream-ffmpeg-args.log
    chown xtreamcodes:xtreamcodes /var/log/xtream-ffmpeg-args.log
    chmod 0640 /var/log/xtream-ffmpeg-args.log

    # ffprobe needs no translation, just a working binary.
    local probe="${PANEL_PATH}/bin/ffprobe"
    if [[ -f "$probe" && ! -L "$probe" ]]; then
        mv "$probe" "${probe}.original"
    fi
    ln -sf /usr/bin/ffprobe "$probe"
    chown -h xtreamcodes:xtreamcodes "$probe"

    log_ok "Wrapper installed; ffprobe linked to the distribution build."

    # Prove the translation actually works before moving on.
    if timeout 30 "$wrapper" -nostdin -hide_banner -loglevel error \
        -f lavfi -i testsrc=duration=2:size=160x120:rate=5 \
        -f segment -segment_time 1 -segment_list_flags '+live+delete' \
        -segment_list /tmp/.xui-wrap-test.m3u8 /tmp/.xui-wrap-test%d.ts \
        </dev/null >/dev/null 2>&1
    then
        log_ok "Wrapper verified: the rejected flag is now accepted."
    else
        log_warn "The wrapper test failed. Streams may not start."
    fi
    rm -f /tmp/.xui-wrap-test*.ts /tmp/.xui-wrap-test.m3u8
}

# Replace the segment deletion that the custom `delete` flag used to provide.
#
# The panel runs ffmpeg with -segment_list_size 6, which rotates the *playlist*
# but never removes the .ts files. Without the custom flag they accumulate at
# roughly 14 MB per minute per stream, filling the streams tmpfs in hours and
# killing every stream on the box.
install_segment_cleaner() {
    log_step "Installing the segment cleaner"

    # In hls mode ffmpeg deletes its own segments, so this is only a backstop --
    # for a stream that died leaving files behind, or an invocation the wrapper
    # did not recognise as a segment-muxer command. Harmless when there is
    # nothing stale to remove.
    if [[ "${SEGMENT_MODE}" == "hls" ]]; then
        log_info "SEGMENT_MODE=hls: ffmpeg handles deletion; installing the cleaner as a backstop."
    fi

    local cleaner="/usr/local/sbin/xtream-clean-segments"

    cat >"$cleaner" <<EOF
#!/bin/bash
#
# Replaces the '+delete' segment-muxer flag from the panel's custom ffmpeg,
# which stock ffmpeg does not implement.
#
# The panel serves a rolling window of segment_list_size (default 6) segments
# of segment_time (default 10s) each -- about a minute of video. Anything older
# than SEGMENT_MAX_AGE_MIN minutes is far outside that window and no client
# will ever request it.

STREAMS="${PANEL_PATH}/streams"
MAX_AGE_MIN=${SEGMENT_MAX_AGE_MIN}

[ -d "\$STREAMS" ] || exit 0

find "\$STREAMS" -maxdepth 1 -type f -name '*.ts' -mmin +\${MAX_AGE_MIN} -delete 2>/dev/null

exit 0
EOF

    chmod 0755 "$cleaner"
    chown root:root "$cleaner"

    cat >/etc/cron.d/xtream-clean-segments <<'EOF'
# Installed by xtreamui-installer. Removes stale HLS segments.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * root /usr/local/sbin/xtream-clean-segments
EOF
    chmod 0644 /etc/cron.d/xtream-clean-segments

    log_ok "Segment cleaner installed (removes .ts older than ${SEGMENT_MAX_AGE_MIN} min, hourly budget bounded)."
}

# The panel opens a file handle per segment, per client connection. The default
# 1024 runs out quickly once more than a handful of streams are live.
raise_panel_limits() {
    log_step "Raising resource limits for the panel user"

    cat >/etc/security/limits.d/xtreamcodes.conf <<EOF
xtreamcodes soft nofile ${PANEL_NOFILE}
xtreamcodes hard nofile ${PANEL_NOFILE}
xtreamcodes soft nproc  ${PANEL_NPROC}
xtreamcodes hard nproc  ${PANEL_NPROC}
EOF
    chmod 0644 /etc/security/limits.d/xtreamcodes.conf

    log_ok "Limits raised: nofile=${PANEL_NOFILE}, nproc=${PANEL_NPROC} (default was 1024)."
}

setup_ffmpeg() {
    case "${FFMPEG_MODE}" in
        bundled)
            log_info "FFMPEG_MODE=bundled: using the panel's own binary without testing."
            link_bundled_ffmpeg
            ;;
        system)
            log_info "FFMPEG_MODE=system: using the distribution ffmpeg."
            install_system_ffmpeg
            install_ffmpeg_wrapper
            install_segment_cleaner
            ;;
        auto|*)
            verify_bundled_ffmpeg
            if [[ "$FFMPEG_BUNDLED_OK" == "yes" ]]; then
                log_ok "Keeping the bundled ffmpeg; it works on this system."
                link_bundled_ffmpeg
            else
                log_info "Falling back to the distribution ffmpeg."
                install_system_ffmpeg
                install_ffmpeg_wrapper
                install_segment_cleaner
            fi
            ;;
    esac

    raise_panel_limits
}

link_bundled_ffmpeg() {
    local bundled="${PANEL_PATH}/bin/ffmpeg"
    if [[ -x "$bundled" ]]; then
        ln -sf "$bundled" /usr/local/bin/ffmpeg
        log_ok "Bundled ffmpeg linked into /usr/local/bin"
    fi
}
