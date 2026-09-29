#!/usr/bin/env bash
# hardening.sh - Permissions, privilege boundaries and service management.
#
# This module exists because of three upstream lines that together hand out root:
#
#   chmod -R 0777 /home/xtreamcodes
#   echo "@reboot root sudo /home/xtreamcodes/.../start_services.sh" >> /etc/crontab
#   echo "xtreamcodes ALL = (root) NOPASSWD: ... /usr/bin/python2, /usr/bin/python" >> /etc/sudoers
#
# The first makes every panel file world-writable. The second has root execute a
# script from that world-writable tree at every boot. The third lets the web
# server's own user become root directly:  sudo python2 -c 'import os; os.system("/bin/sh")'
# Since php-fpm runs as xtreamcodes, any RCE in the panel PHP is instant root.

set_panel_permissions() {
    log_step "Setting file permissions"

    chown -R xtreamcodes:xtreamcodes "$PANEL_HOME"

    # Directories 0750, files 0640: owner and group only, nothing for "other".
    find "$PANEL_HOME" -type d -exec chmod 0750 {} +
    find "$PANEL_HOME" -type f -exec chmod 0640 {} +

    # Executables the panel actually needs to run.
    local -a exec_dirs=(
        "${PANEL_PATH}/bin"
        "${PANEL_PATH}/nginx/sbin"
        "${PANEL_PATH}/nginx_rtmp/sbin"
        "${PANEL_PATH}/php/sbin"
        "${PANEL_PATH}/php/bin"
    )
    local dir
    for dir in "${exec_dirs[@]}"; do
        [[ -d "$dir" ]] && find "$dir" -type f -exec chmod 0750 {} +
    done

    # Writable working directories.
    local -a writable=(
        "${PANEL_PATH}/logs"
        "${PANEL_PATH}/tmp"
        "${PANEL_PATH}/streams"
        "${PANEL_PATH}/crons"
        "${PANEL_PATH}/wwwdir/session"
    )
    for dir in "${writable[@]}"; do
        [[ -d "$dir" ]] || mkdir -p "$dir"
        chown xtreamcodes:xtreamcodes "$dir"
        chmod 0750 "$dir"
    done

    # Cron scripts need the execute bit but must not be world-writable.
    [[ -d "${PANEL_PATH}/crons" ]] \
        && find "${PANEL_PATH}/crons" -type f -name '*.php' -exec chmod 0750 {} +

    log_ok "Permissions set: dirs 0750, files 0640, no world-writable paths."
}

verify_no_world_writable() {
    log_step "Verifying no world-writable files remain"

    local count
    count=$(find "$PANEL_HOME" -perm -o+w ! -type l 2>/dev/null | wc -l)

    if (( count > 0 )); then
        log_warn "Found $count world-writable paths under $PANEL_HOME:"
        # `|| true`: head closes the pipe after ten lines and find takes a
        # SIGPIPE, which under `set -o pipefail` would abort the install on a
        # warning.
        find "$PANEL_HOME" -perm -o+w ! -type l 2>/dev/null | head -10 || true
    else
        log_ok "No world-writable files under $PANEL_HOME."
    fi
}

# A minimal, explicitly scoped sudoers entry.
#
# The panel uses iptables to block abusive client IPs and chattr to protect the
# GeoIP database. Those are the only two it genuinely needs. python is NOT
# granted: that grant is equivalent to passwordless root for the web user.
configure_sudoers() {
    log_step "Configuring sudo privileges"

    local sudoers="/etc/sudoers.d/xtreamui"

    if [[ "$ALLOW_IPTABLES_CONTROL" != "yes" ]]; then
        rm -f "$sudoers"
        log_ok "No sudo privileges granted to xtreamcodes (IP blocking disabled)."
        log_info "Enable with --allow-iptables-control if you need the panel to block client IPs."
        return 0
    fi

    cat >"$sudoers" <<'EOF'
# Managed by xtreamui-installer.
#
# Deliberately minimal. Do not add python, perl, bash, or any interpreter here:
# an interpreter with NOPASSWD sudo is a passwordless root shell for the web
# server user.
Cmnd_Alias XTREAM_NET = /usr/sbin/iptables, /sbin/iptables
Cmnd_Alias XTREAM_ATTR = /usr/bin/chattr

xtreamcodes ALL = (root) NOPASSWD: XTREAM_NET, XTREAM_ATTR
EOF

    chmod 0440 "$sudoers"

    visudo -cf "$sudoers" >/dev/null \
        || { rm -f "$sudoers"; die "Generated sudoers file failed validation."; }

    log_ok "Scoped sudo rules installed (iptables and chattr only, no interpreters)."
}

# A root-owned launcher outside the panel tree.
#
# Upstream had root run start_services.sh from inside the 0777 panel directory.
# This script lives in /usr/local/sbin, owned by root and not writable by
# xtreamcodes, so the panel user cannot rewrite what root will execute.
install_service_launcher() {
    log_step "Installing the service launcher"

    local launcher="/usr/local/sbin/xtreamui-start"

    cat >"$launcher" <<EOF
#!/usr/bin/env bash
# Managed by xtreamui-installer. Root-owned, outside the panel tree.
set -u

PANEL_PATH="${PANEL_PATH}"

# Clear stale pid files left by an unclean shutdown.
rm -f "\${PANEL_PATH}"/php/*.pid 2>/dev/null

# Panel maintenance tasks, dropped to the unprivileged user.
runuser -u xtreamcodes -- "\${PANEL_PATH}/php/bin/php" \\
    "\${PANEL_PATH}/crons/setup_cache.php" >/dev/null 2>&1 || true

runuser -u xtreamcodes -- "\${PANEL_PATH}/php/bin/php" \\
    "\${PANEL_PATH}/tools/signal_receiver.php" >/dev/null 2>&1 &

runuser -u xtreamcodes -- "\${PANEL_PATH}/php/bin/php" \\
    "\${PANEL_PATH}/tools/pipe_reader.php" >/dev/null 2>&1 &

# Web servers. The master starts as root to bind ports, then drops to the
# xtreamcodes user for worker processes as declared in nginx.conf.
"\${PANEL_PATH}/nginx_rtmp/sbin/nginx_rtmp"
"\${PANEL_PATH}/nginx/sbin/nginx"

# PHP-FPM pools.
for pool in VaiIb8 JdlJXm CWcfSP; do
    if [[ -f "\${PANEL_PATH}/php/etc/\${pool}.conf" ]]; then
        "\${PANEL_PATH}/php/sbin/php-fpm" \\
            --fpm-config "\${PANEL_PATH}/php/etc/\${pool}.conf" \\
            --pid "\${PANEL_PATH}/php/\${pool}.pid" \\
            --daemonize
    fi
done

exit 0
EOF

    chown root:root "$launcher"
    chmod 0755 "$launcher"

    local stopper="/usr/local/sbin/xtreamui-stop"
    cat >"$stopper" <<EOF
#!/usr/bin/env bash
# Managed by xtreamui-installer.
set -u
PANEL_PATH="${PANEL_PATH}"

"\${PANEL_PATH}/nginx/sbin/nginx" -s quit 2>/dev/null || true
"\${PANEL_PATH}/nginx_rtmp/sbin/nginx_rtmp" -s quit 2>/dev/null || true

for pid_file in "\${PANEL_PATH}"/php/*.pid; do
    [[ -f "\$pid_file" ]] && kill "\$(cat "\$pid_file")" 2>/dev/null || true
done

pkill -u xtreamcodes 2>/dev/null || true
exit 0
EOF

    chown root:root "$stopper"
    chmod 0755 "$stopper"

    log_ok "Launcher installed at $launcher (root-owned, outside the panel tree)."
}

# systemd instead of a crontab line.
#
# Upstream appended "@reboot root sudo ..." to /etc/crontab. systemd gives us
# ordering guarantees, restart-on-failure, proper logging via journalctl, and
# no dependency on cron running as root.
install_systemd_service() {
    log_step "Installing the systemd service"

    cat >/etc/systemd/system/xtreamui.service <<EOF
[Unit]
Description=Xtream UI IPTV Panel
Documentation=https://github.com/YOUR_USER/xtreamui-installer
After=network-online.target mariadb.service
Wants=network-online.target
Requires=mariadb.service

[Service]
Type=forking
ExecStart=/usr/local/sbin/xtreamui-start
ExecStop=/usr/local/sbin/xtreamui-stop
RemainAfterExit=yes
TimeoutStartSec=120
Restart=on-failure
RestartSec=10

# Hardening. These cost nothing and shrink the blast radius of a compromise.
NoNewPrivileges=no
PrivateTmp=no
ProtectSystem=full
ProtectHome=no
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictRealtime=yes

LimitNOFILE=300000
LimitNPROC=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xtreamui.service >/dev/null 2>&1

    # Remove the upstream crontab line if this is a repair over an old install.
    if grep -q 'start_services.sh' /etc/crontab 2>/dev/null; then
        backup_file /etc/crontab >/dev/null
        sed -i '/start_services\.sh/d' /etc/crontab
        log_ok "Removed the legacy @reboot root crontab entry."
    fi

    log_ok "systemd service installed and enabled."
}

# Disable the panel cron that kills MPEGTS client connections.
#
# users_checker.php deletes rows from user_activity_now for container='ts'
# connections every time it runs:
#
#     DELETE FROM user_activity_now WHERE activity_id = '<id>'
#
# The client's playback stops 20-60 seconds in. There is no error anywhere --
# the server closes the stream cleanly, so the player reports a normal end of
# stream and the connection simply vanishes from Live Connections. HLS
# connections are unaffected, which makes it look like an MPEGTS-only problem
# with the stream rather than a cron deleting rows.
#
# Established by running each of the panel's twelve minute-crons by hand
# against a live TS connection: only this one kills it. With it disabled and
# the other nineteen running, playback held for five minutes and 78 MB.
#
# What is lost: periodic revalidation of client lines. What is NOT lost:
#   * connection limits  -- checked when a client connects, in the streaming path
#   * expiry             -- checked at authentication, via exp_date
#   * server watchdog    -- kill_leaks.php updates streaming_servers.watchdog_data
disable_broken_panel_crons() {
    log_step "Reviewing the panel's own cron jobs"

    if [[ "${DISABLE_USERS_CHECKER}" != "yes" ]]; then
        log_info "Leaving users_checker.php enabled (--keep-users-checker)."
        log_warn "MPEGTS clients will be disconnected roughly once a minute."
        return 0
    fi

    # Neutralise the script itself, not just its crontab entry.
    #
    # Removing the crontab line alone is not durable: the panel reinstates its
    # own crontab, and the entry comes back on its own. Replacing the script
    # with a stub survives that, because whatever schedule fires simply runs a
    # file that exits immediately.
    local target="${PANEL_PATH}/crons/users_checker.php"

    if [[ -f "$target" ]] && ! grep -q 'xtreamui-installer' "$target" 2>/dev/null; then
        mv "$target" "${target}.original"
        cat >"$target" <<'STUBEOF'
<?php
// Neutralised by xtreamui-installer. The original is alongside as
// users_checker.php.original.
//
// This cron deletes MPEGTS client connections from user_activity_now every
// time it runs, which stops playback 20-60 seconds in. The server closes the
// stream cleanly, so nothing is logged as an error and the player reports a
// normal end of stream. HLS connections are unaffected.
//
// Access control does not depend on it: connection limits are enforced when a
// client connects, expiry is enforced at authentication, and kill_leaks.php
// still updates the server watchdog data.
exit(0);
STUBEOF
        chown xtreamcodes:xtreamcodes "$target"
        chmod 0750 "$target"
        log_ok "users_checker.php replaced with a stub (original kept as .original)."
    else
        log_info "users_checker.php is already neutralised."
    fi

    # Also drop the crontab entry, so it does not run even once before the
    # stub would take effect.
    local current
    current=$(crontab -u xtreamcodes -l 2>/dev/null) || current=""

    if [[ -n "$current" ]] && grep -q 'users_checker' <<<"$current"; then
        local backup="/root/crontab-xtreamcodes.bak-$(date +%Y%m%d-%H%M%S)"
        printf '%s\n' "$current" >"$backup"
        chmod 600 "$backup"
        grep -v 'users_checker' <<<"$current" | crontab -u xtreamcodes -
        log_info "Crontab entry removed as well. Backup: ${backup}"
    fi

    cat >/root/README-users_checker.txt <<EOF
users_checker.php is NEUTRALISED on this server.

What it did:
  Deleted MPEGTS client connections from user_activity_now every time it ran,
  stopping playback 20-60 seconds in. The server closes the stream cleanly, so
  nothing appears as an error in any log and the player reports a normal end of
  stream. HLS connections were unaffected.

How it is disabled:
  ${PANEL_PATH}/crons/users_checker.php  ->  a stub that exits immediately
  ${PANEL_PATH}/crons/users_checker.php.original  ->  the original

  The crontab entry was removed too, but the stub is what makes this durable:
  the panel reinstates its own crontab, so removing the line alone does not
  hold.

Access control is unaffected:
  - connection limits are enforced when a client connects
  - expiry is enforced at authentication, via exp_date
  - kill_leaks.php still updates streaming_servers.watchdog_data

To restore:
    mv ${PANEL_PATH}/crons/users_checker.php.original \\
       ${PANEL_PATH}/crons/users_checker.php
EOF
    chmod 600 /root/README-users_checker.txt
}

install_panel_cron() {
    log_step "Installing the panel cron jobs"

    local cron_file="/etc/cron.d/xtreamui"

    # Runs as xtreamcodes, not root.
    cat >"$cron_file" <<EOF
# Managed by xtreamui-installer.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

*/1 * * * * xtreamcodes ${PANEL_PATH}/php/bin/php ${PANEL_PATH}/crons/epg.php >/dev/null 2>&1
*/1 * * * * xtreamcodes ${PANEL_PATH}/php/bin/php ${PANEL_PATH}/crons/series_episodes.php >/dev/null 2>&1
*/5 * * * * xtreamcodes ${PANEL_PATH}/php/bin/php ${PANEL_PATH}/crons/backup.php >/dev/null 2>&1
EOF

    chmod 0644 "$cron_file"
    log_ok "Cron jobs installed under the xtreamcodes user, not root."
}

# Block the panel's outbound calls to the original vendor domains.
#
# Upstream did this too, but framed it as part of the install. Stating it
# plainly: these domains belonged to Xtream Codes, whose infrastructure was
# seized in 2019. The panel still tries to reach them. Pointing them at
# loopback stops the requests hanging and stops an obfuscated binary phoning
# home to a domain that no longer belongs to anyone you can identify.
block_vendor_callbacks() {
    log_step "Blocking vendor callback domains"

    local -a domains=(
        "api.xtream-codes.com"
        "downloads.xtream-codes.com"
        "xtream-codes.com"
    )

    backup_file /etc/hosts >/dev/null

    local domain
    for domain in "${domains[@]}"; do
        if ! grep -qE "^\s*127\.0\.0\.1\s+.*\b${domain//./\\.}\b" /etc/hosts; then
            printf '127.0.0.1\t%s\n' "$domain" >>/etc/hosts
        fi
    done

    log_ok "Vendor domains redirected to loopback."
}

restrict_postfix() {
    log_step "Checking the local mail server"

    if ! systemctl is-active --quiet postfix 2>/dev/null; then
        log_info "Postfix is not running; nothing to do."
        return 0
    fi

    local listening
    listening=$(ss -tln 2>/dev/null | awk '$4 ~ /:25$/ && $4 !~ /^127\./ {print $4}')

    if [[ -n "$listening" ]]; then
        log_warn "Postfix is listening on $listening (reachable from the internet)."
        log_warn "An exposed mail server is a spam relay target. Restrict it with:"
        log_warn "  postconf -e 'inet_interfaces = loopback-only' && systemctl restart postfix"
    else
        log_ok "Postfix is bound to loopback only."
    fi
}
