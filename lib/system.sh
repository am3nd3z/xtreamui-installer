#!/usr/bin/env bash
# system.sh - System packages, repositories and timezone.

setup_timezone() {
    log_step "Configuring timezone"
    timedatectl set-timezone "$TIMEZONE"
    log_ok "Timezone set to $TIMEZONE"
}

# Upstream fetched the sury.org APT signing key like this:
#
#   wget --no-check-certificate -qO- https://packages.sury.org/php/apt.gpg | apt-key add -
#
# Two problems. Disabling certificate validation while downloading a repository
# signing key is a textbook man-in-the-middle vector -- it is the root of trust
# for every package installed afterwards. And apt-key has been deprecated since
# Debian 11 because it installs keys with global trust across all repositories.
#
# We validate TLS and scope each key to its own repository with signed-by.
add_apt_repo_key() {
    local name="$1" key_url="$2" repo_line="$3"
    local keyring="/usr/share/keyrings/${name}-archive-keyring.gpg"

    log_info "Adding repository: $name"

    curl -fsSL --proto '=https' --tlsv1.2 "$key_url" \
        | gpg --dearmor --yes -o "$keyring" \
        || die "Failed to fetch or parse the signing key for $name."

    chmod 0644 "$keyring"

    printf 'deb [arch=amd64 signed-by=%s] %s\n' "$keyring" "$repo_line" \
        >"/etc/apt/sources.list.d/${name}.list"

    log_ok "Repository $name added with a scoped keyring."
}

install_base_packages() {
    log_step "Installing base packages"

    export DEBIAN_FRONTEND=noninteractive

    # Stop needrestart from opening interactive dialogs mid-install.
    if [[ -f /etc/needrestart/needrestart.conf ]]; then
        sed -i "s/^#\?\$nrconf{restart}.*/\$nrconf{restart} = 'a';/" \
            /etc/needrestart/needrestart.conf
    fi

    apt-get update -qq

    local -a packages=(
        ca-certificates curl wget gnupg lsb-release apt-transport-https
        software-properties-common
        unzip zip tar bzip2 xz-utils
        net-tools dnsutils iproute2
        cron at jq
        libxslt1-dev libgeoip-dev libmaxminddb0 libmaxminddb-dev
        libcurl4 libpcre3 libssl-dev zlib1g
        daemonize e2fsprogs
        python3 python3-pip
    )

    apt-get install -y -qq "${packages[@]}" \
        || die "Failed to install base packages."

    log_ok "Base packages installed."
}

install_python2() {
    log_step "Installing python2 (required by the panel tooling)"

    if command -v python2 >/dev/null 2>&1; then
        log_ok "python2 already present."
        return 0
    fi

    if apt-get install -y -qq python2 2>/dev/null; then
        log_ok "python2 installed from the distribution repositories."
    else
        log_warn "python2 is not available. Panel tools that depend on it will fail."
    fi
}

install_mariadb() {
    log_step "Installing MariaDB"

    if command -v mariadbd >/dev/null 2>&1 || command -v mysqld >/dev/null 2>&1; then
        log_ok "MariaDB is already installed."
        return 0
    fi

    apt-get install -y -qq mariadb-server mariadb-client \
        || die "Failed to install MariaDB."

    systemctl enable --now mariadb
    log_ok "MariaDB installed and running."
}

# The legacy OpenSSL 1.1 runtime. The panel ships nginx and PHP binaries linked
# against libssl.so.1.1, which Ubuntu 22.04+ no longer provides. Without this
# the binaries fail with "error while loading shared libraries".
install_legacy_openssl() {
    log_step "Checking legacy OpenSSL 1.1 runtime"

    if ldconfig -p | grep -q 'libssl\.so\.1\.1'; then
        log_ok "libssl.so.1.1 is already present."
        return 0
    fi

    log_info "libssl1.1 is missing; the panel's prebuilt binaries require it."

    local deb_url="http://security.ubuntu.com/ubuntu/pool/main/o/openssl/libssl1.1_1.1.1f-1ubuntu2.24_amd64.deb"
    local deb_path="/tmp/libssl1.1.deb"

    if curl -fsSL --max-time 60 -o "$deb_path" "$deb_url"; then
        dpkg -i "$deb_path" >/dev/null 2>&1 || apt-get install -f -y -qq
        rm -f "$deb_path"

        # Refresh the cache before checking it. dpkg normally runs ldconfig
        # itself, but not reliably within the same moment we query it, and a
        # stale cache made a successful install report as a failure.
        ldconfig 2>/dev/null || true

        if ldconfig -p | grep -q 'libssl\.so\.1\.1'; then
            log_ok "libssl1.1 installed."
        else
            log_warn "libssl1.1 installation did not take effect."
        fi
    else
        log_warn "Could not download libssl1.1 from $deb_url"
        log_warn "If nginx or php-fpm fail to start, install it manually."
    fi
}

install_ffmpeg_deps() {
    log_step "Installing media libraries"

    apt-get install -y -qq \
        libfdk-aac2 libx264-163 libx265-199 libvpx7 libopus0 libmp3lame0 \
        2>/dev/null || apt-get install -y -qq \
        libfdk-aac1 libx264-160 libx265-192 libvpx6 libopus0 libmp3lame0 \
        2>/dev/null || log_warn "Some media libraries were unavailable; ffmpeg may lack codecs."

    log_ok "Media libraries installed."
}
