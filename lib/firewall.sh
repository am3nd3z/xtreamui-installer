#!/usr/bin/env bash
# firewall.sh - ufw rules, applied in an order that cannot lock you out.

detect_ssh_port() {
    local port
    port=$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' \
        /etc/ssh/sshd_config 2>/dev/null)
    printf '%s' "${port:-22}"
}

configure_firewall() {
    log_step "Configuring the firewall"

    if [[ "$ENABLE_FIREWALL" != "yes" ]]; then
        log_warn "Firewall configuration skipped (--enable-firewall not given)."
        log_warn "Port ${MYSQL_PORT} (MariaDB) is bound to loopback, but nothing else is filtered."
        return 0
    fi

    if ! command -v ufw >/dev/null 2>&1; then
        apt-get install -y -qq ufw || die "Could not install ufw."
    fi

    local ssh_port
    ssh_port=$(detect_ssh_port)

    # Order matters. Allowing SSH before enabling is the difference between a
    # firewall and a lockout. ufw --force enable would otherwise drop the very
    # session running this script.
    log_info "Detected SSH on port ${ssh_port}; allowing it first."

    ufw --force reset >/dev/null 2>&1
    ufw default deny incoming  >/dev/null
    ufw default allow outgoing >/dev/null

    ufw allow "${ssh_port}/tcp" comment 'SSH' >/dev/null
    log_ok "SSH (${ssh_port}) allowed."

    ufw allow "${CLIENT_PORT}/tcp" comment 'Xtream client HTTP' >/dev/null
    log_ok "Client HTTP (${CLIENT_PORT}) allowed."

    if [[ "$ENABLE_HTTPS" == "yes" ]]; then
        ufw allow "${CLIENT_HTTPS_PORT}/tcp" comment 'Xtream client HTTPS' >/dev/null
        log_ok "Client HTTPS (${CLIENT_HTTPS_PORT}) allowed."
    fi

    ufw allow "${RTMP_PORT}/tcp" comment 'Xtream RTMP' >/dev/null
    log_ok "RTMP (${RTMP_PORT}) allowed."

    # The admin panel is the highest-value target. Restrict it when we can.
    if [[ -n "${ADMIN_ALLOW_IP:-}" ]]; then
        ufw allow from "$ADMIN_ALLOW_IP" to any port "$ADMIN_PORT" proto tcp \
            comment 'Xtream admin (restricted)' >/dev/null
        log_ok "Admin panel (${ADMIN_PORT}) allowed from ${ADMIN_ALLOW_IP} only."
    else
        ufw allow "${ADMIN_PORT}/tcp" comment 'Xtream admin' >/dev/null
        log_warn "Admin panel (${ADMIN_PORT}) is open to the whole internet."
        log_warn "Restrict it with --admin-allow-ip YOUR.IP.HERE"
    fi

    # Database access for a load balancer, if one was declared.
    if [[ -n "${DB_REMOTE_CIDR:-}" ]]; then
        ufw allow from "$DB_REMOTE_CIDR" to any port "$MYSQL_PORT" proto tcp \
            comment 'MariaDB load balancer' >/dev/null
        log_ok "MariaDB (${MYSQL_PORT}) allowed from ${DB_REMOTE_CIDR} only."
    fi

    # Ports deliberately NOT opened: MariaDB to the world, the ISP module and
    # the RTMP stat endpoint. All three are loopback-bound by our configs.

    ufw --force enable >/dev/null
    log_ok "Firewall enabled."

    printf '\n'
    ufw status numbered

    printf '\n%s%s%s\n' "$C_YELLOW" \
        "Before closing this session: open a SECOND SSH connection and confirm it works." \
        "$C_RESET"
    printf '%sIf it fails, use this session to run: ufw disable%s\n\n' "$C_DIM" "$C_RESET"
}

print_firewall_commands() {
    cat <<EOF

Manual firewall setup, if you prefer to run it yourself:

  # SSH FIRST -- do not skip this line
  ufw allow $(detect_ssh_port)/tcp

  ufw allow ${CLIENT_PORT}/tcp          # clients
  ufw allow ${CLIENT_HTTPS_PORT}/tcp    # clients over TLS
  ufw allow ${RTMP_PORT}/tcp            # RTMP
  ufw allow ${ADMIN_PORT}/tcp           # admin panel
                                        # (better: ufw allow from YOUR.IP to any port ${ADMIN_PORT})

  ufw default deny incoming
  ufw default allow outgoing
  ufw --force enable
  ufw status numbered

Do NOT open port ${MYSQL_PORT}. MariaDB is bound to 127.0.0.1.

EOF
}
