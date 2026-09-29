#!/usr/bin/env bash
# database.sh - MariaDB configuration, schema and panel credentials.

# Locate the MariaDB unix socket.
detect_mysql_socket() {
    local candidate
    for candidate in /run/mysqld/mysqld.sock /var/run/mysqld/mysqld.sock \
                     /var/lib/mysql/mysql.sock /tmp/mysql.sock; do
        [[ -S "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
    done
    printf '/run/mysqld/mysqld.sock'
}

# Run mysql over the unix socket, without ever putting a password on the
# command line.
#
# Two separate points here.
#
# The password: upstream ran `mysql -u root -p$PASSMYSQL ...` throughout.
# Command lines are world-readable via /proc, so any local user could read the
# MySQL root password with a plain `ps aux` while the installer ran.
#
# The socket: connecting to 127.0.0.1 over TCP does NOT work on this setup.
# The config sets skip-name-resolve, which stops 'root'@'localhost' matching
# TCP connections from the loopback address -- those would need an explicit
# 'root'@'127.0.0.1' grant that does not exist. Everything here goes through
# the socket, which is what the localhost account actually matches.
mysql_exec() {
    local sql="$1" database="${2:-}"

    [[ -n "${MYSQL_SOCKET:-}" ]] || MYSQL_SOCKET=$(detect_mysql_socket)

    local cnf
    cnf=$(mktemp)
    chmod 600 "$cnf"

    cat >"$cnf" <<EOF
[client]
user=root
password=${MYSQL_ROOT_PASS}
socket=${MYSQL_SOCKET}
EOF

    local result rc=0
    result=$(mysql --defaults-extra-file="$cnf" ${database:+"$database"} \
        -e "$sql" 2>&1) || rc=$?

    rm -f "$cnf"
    printf '%s' "$result"
    return $rc
}

configure_mariadb() {
    log_step "Configuring MariaDB"

    local cnf="/etc/mysql/mariadb.conf.d/60-xtreamui.cnf"
    mkdir -p "$(dirname "$cnf")"

    # bind-address is the single most important line in this file.
    #
    # Upstream shipped `bind-address = *`, which put MariaDB on every interface,
    # and then granted user_iptvpro@'%' ALL PRIVILEGES ON *.* WITH GRANT OPTION.
    # The combination exposes a root-equivalent database account to the whole
    # internet on port 7999. That is how large numbers of these panels have been
    # dumped. We bind to loopback and open it selectively, if at all.
    local bind_addr="127.0.0.1"
    if [[ -n "${DB_REMOTE_CIDR:-}" ]]; then
        bind_addr="0.0.0.0"
        log_warn "MariaDB will listen on all interfaces for load balancer access."
        log_warn "Access is restricted to $DB_REMOTE_CIDR by grant and firewall rule."
    fi

    cat >"$cnf" <<EOF
# Managed by xtreamui-installer. Do not edit by hand.
[mysqld]
bind-address            = ${bind_addr}
port                    = ${MYSQL_PORT}
skip-name-resolve        = 1
skip-external-locking

max_connections          = ${DB_MAX_CONNECTIONS}
back_log                 = 4096
open_files_limit         = 20240
innodb_open_files        = 20240
max_connect_errors       = 3072
table_open_cache         = 4096
table_definition_cache   = 4096

key_buffer_size          = 128M
max_allowed_packet       = 64M
myisam_sort_buffer_size  = 4M
myisam-recover-options   = BACKUP
max_length_for_sort_data = 8192

tmp_table_size           = ${DB_TMP_TABLE_SIZE}
max_heap_table_size      = ${DB_TMP_TABLE_SIZE}

innodb_buffer_pool_size       = ${DB_BUFFER_POOL_SIZE}
innodb_buffer_pool_instances  = 4
innodb_read_io_threads        = 16
innodb_write_io_threads       = 16
innodb_thread_concurrency     = 0
innodb_flush_method           = O_DIRECT
innodb-file-per-table         = 1
innodb_io_capacity            = 2000

# Upstream set innodb_flush_log_at_trx_commit = 0, which can lose up to one
# second of committed transactions on a crash. 2 flushes on commit and is a
# far safer default while still avoiding a disk sync per transaction.
innodb_flush_log_at_trx_commit = 2

# Upstream disabled deadlock detection and set lock_wait_timeout = 0 (wait
# forever). That turns a deadlock into a permanently hung connection.
innodb_lock_wait_timeout      = 50

expire_logs_days         = 10
max_binlog_size          = 100M
performance_schema       = 0

sql-mode = "NO_ENGINE_SUBSTITUTION"

[mysqldump]
quick
quote-names
max_allowed_packet = 16M
EOF

    log_info "Buffer pool: $DB_BUFFER_POOL_SIZE | max_connections: $DB_MAX_CONNECTIONS"

    systemctl restart mariadb || die "MariaDB failed to restart. Check: journalctl -u mariadb"

    local waited=0
    until mysqladmin ping --silent 2>/dev/null || (( waited >= 30 )); do
        sleep 1; waited=$((waited + 1))
    done
    (( waited < 30 )) || die "MariaDB did not become ready within 30 seconds."

    log_ok "MariaDB configured and listening on ${bind_addr}:${MYSQL_PORT}"
}

secure_mariadb_root() {
    log_step "Securing the MariaDB root account"

    # On a fresh install root uses unix_socket auth, so this first call needs no
    # password. Once set, every later call goes through mysql_exec.
    mysql -u root --socket=/var/run/mysqld/mysqld.sock -e "
        ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
        DELETE FROM mysql.user WHERE User='';
        DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
        DROP DATABASE IF EXISTS test;
        DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
        FLUSH PRIVILEGES;
    " 2>/dev/null || die "Could not set the MariaDB root password."

    log_ok "Root password set, anonymous users and test database removed."
}

create_panel_database() {
    log_step "Creating the panel database"

    mysql_exec "
        DROP DATABASE IF EXISTS ${DB_NAME};
        CREATE DATABASE ${DB_NAME} CHARACTER SET utf8 COLLATE utf8_general_ci;
    " >/dev/null || die "Could not create database ${DB_NAME}."

    local schema="${PANEL_PATH}/database.sql"
    [[ -f "$schema" ]] || die "Schema not found at $schema. The panel archive may be incomplete."

    [[ -n "${MYSQL_SOCKET:-}" ]] || MYSQL_SOCKET=$(detect_mysql_socket)

    local cnf
    cnf=$(mktemp); chmod 600 "$cnf"
    cat >"$cnf" <<EOF
[client]
user=root
password=${MYSQL_ROOT_PASS}
socket=${MYSQL_SOCKET}
EOF
    # No --force here, deliberately. mysql stops at the first error and exits
    # non-zero, and we abort on that. The upstream installer pipes its SQL in
    # without checking, which is how a file that dies a third of the way through
    # still produces a "successfully installed" banner.
    mysql --defaults-extra-file="$cnf" "$DB_NAME" <"$schema" \
        || { rm -f "$cnf"; die "Failed to import the panel schema."; }
    rm -f "$cnf"

    # The schema contains the panel's own credentials; do not leave it on disk.
    shred -u "$schema" 2>/dev/null || rm -f "$schema"

    log_ok "Database ${DB_NAME} created and schema imported."
}

# Scoped privileges only.
#
# Upstream: GRANT ALL PRIVILEGES ON *.* TO 'user_iptvpro'@'%' WITH GRANT OPTION
#   - ON *.*        every database on the server, including mysql.user
#   - @'%'          from any host on the internet
#   - GRANT OPTION  can create new accounts and escalate itself
#
# The panel only needs data access to its own database.
create_panel_db_user() {
    log_step "Creating the panel database user"

    mysql_exec "
        DROP USER IF EXISTS '${DB_USER}'@'localhost';
        CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
        GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER,
              CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE
          ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
        FLUSH PRIVILEGES;
    " >/dev/null || die "Could not create the panel database user."

    log_ok "User ${DB_USER}@localhost created, scoped to ${DB_NAME} only."

    if [[ -n "${DB_REMOTE_CIDR:-}" ]]; then
        mysql_exec "
            DROP USER IF EXISTS '${DB_USER}'@'${DB_REMOTE_CIDR}';
            CREATE USER '${DB_USER}'@'${DB_REMOTE_CIDR}' IDENTIFIED BY '${DB_PASS}';
            GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER,
                  CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE
              ON ${DB_NAME}.* TO '${DB_USER}'@'${DB_REMOTE_CIDR}';
            FLUSH PRIVILEGES;
        " >/dev/null || die "Could not create the remote load balancer user."
        log_ok "Load balancer access granted to ${DB_USER}@${DB_REMOTE_CIDR}"
    fi
}

# Register this server, with every port matching what nginx actually listens on.
#
# Upstream inserted hardcoded defaults (rtmp_port 2086, https_broadcast_port
# 2083) and then only updated http_broadcast_port. The result was a panel
# advertising ports nothing was bound to.
register_main_server() {
    log_step "Registering this server in the panel"

    local network_iface
    network_iface=$(ip route show default | awk '{print $5; exit}')
    [[ -n "$network_iface" ]] || network_iface="eth0"

    mysql_exec "
        REPLACE INTO streaming_servers
            (id, server_name, domain_name, server_ip, vpn_ip, ssh_password, ssh_port,
             diff_time_main, http_broadcast_port, total_clients, system_os,
             network_interface, latency, status, enable_geoip, geoip_countries,
             last_check_ago, can_delete, server_hardware, total_services,
             persistent_connections, rtmp_port, geoip_type, isp_names, isp_type,
             enable_isp, boost_fpm, http_ports_add, network_guaranteed_speed,
             https_broadcast_port, https_ports_add, whitelist_ips, watchdog_data,
             timeshift_only)
        VALUES
            (1, 'Main Server', '${PANEL_DOMAIN}', '${PUBLIC_IP}', '', NULL, ${SSH_PORT},
             0, ${CLIENT_PORT}, 1000, '${OS_ID} ${OS_VERSION}',
             '${network_iface}', 0, 1, 0, '',
             0, 0, '{}', 3,
             0, ${RTMP_PORT}, 'low_priority', '', 'low_priority',
             0, 0, '', 1000,
             ${CLIENT_HTTPS_PORT}, '', '[\"127.0.0.1\",\"\"]', '{}',
             0);
    " "$DB_NAME" >/dev/null || die "Could not register the main server."

    log_ok "Server registered: ${PUBLIC_IP} | client ${CLIENT_PORT} | rtmp ${RTMP_PORT} | https ${CLIENT_HTTPS_PORT}"
}

configure_panel_settings() {
    log_step "Applying panel settings"

    mysql_exec "
        UPDATE settings SET
            live_streaming_pass  = '${STREAM_PASS}',
            unique_id            = '${UNIQUE_ID}',
            crypt_load_balancing = '${CRYPT_LB}'
        WHERE id = 1;
    " "$DB_NAME" >/dev/null || log_warn "Could not update the settings table."

    log_ok "Panel settings applied."
}

create_admin_user() {
    log_step "Creating the panel administrator"

    # The panel stores SHA-512 crypt hashes with a fixed salt prefix.
    local hash
    hash=$(python3 -c "
import crypt, sys
print(crypt.crypt(sys.argv[1], '\$6\$rounds=20000\$xtreamcodes'))
" "$ADMIN_PASS" 2>/dev/null) \
        || hash=$(perl -e 'print crypt($ARGV[0], "\$6\$rounds=20000\$xtreamcodes")' "$ADMIN_PASS")

    [[ -n "$hash" ]] || die "Could not hash the administrator password."

    # The full 21-column reg_users schema, verified against a real install.
    #
    # Columns that must not be omitted: default_lang, reseller_dns and
    # google_2fa_sec are NOT NULL with no default, and verified must be 1 or the
    # account cannot log in. An INSERT that leaves them out either fails outright
    # under strict SQL mode or, under the panel's own NO_ENGINE_SUBSTITUTION
    # mode, silently creates an account that does not work.
    mysql_exec "
        DELETE FROM reg_users WHERE id = 1;
        INSERT INTO reg_users
            (id, username, password, email, ip, date_registered, verify_key,
             last_login, member_group_id, verified, credits, notes, status,
             default_lang, reseller_dns, owner_id, override_packages,
             google_2fa_sec, dark_mode, sidebar, expanded_sidebar)
        VALUES
            (1, '${ADMIN_USER}', '${hash}', '${ADMIN_EMAIL}', NULL, UNIX_TIMESTAMP(), NULL,
             NULL, 1, 1, 0, NULL, 1,
             '${PANEL_LANG}', '', 0, NULL,
             '', 0, 0, 0);
    " "$DB_NAME" >/dev/null || die "Could not create the administrator account."

    # Confirm it landed, and that it is usable rather than merely present.
    local check
    check=$(mysql_exec "SELECT CONCAT(username,'|',verified,'|',status) FROM reg_users WHERE id=1;" \
        "$DB_NAME" 2>/dev/null | tail -1)
    [[ "$check" == "${ADMIN_USER}|1|1" ]] \
        || die "Administrator row is wrong: got '${check}'. Expected '${ADMIN_USER}|1|1'."

    log_ok "Administrator '${ADMIN_USER}' created (verified, active)."
}

# Write the panel's config file.
#
# Note honestly what this is: the panel reads a base64-wrapped XOR of its
# database credentials, using a key hardcoded in the public source. That is
# obfuscation, not encryption, and anyone with the file can recover the
# password in seconds. We cannot change the format without changing the panel
# PHP, so we compensate with strict file permissions instead.
write_panel_config() {
    log_step "Writing the panel configuration file"

    local config_file="${PANEL_PATH}/config"

    python3 - "$config_file" <<PYEOF || die "Could not write the panel config file."
import base64, json, sys
from itertools import cycle

path = sys.argv[1]
key = "5709650b0d7806074842c6de575025b1"

payload = json.dumps({
    "host":      "127.0.0.1",
    "db_user":   "${DB_USER}",
    "db_pass":   "${DB_PASS}",
    "db_name":   "${DB_NAME}",
    "server_id": "1",
    "db_port":   "${MYSQL_PORT}",
}, separators=(',', ':'))

encoded = base64.b64encode(
    bytes(ord(c) ^ ord(k) for c, k in zip(payload, cycle(key)))
).decode()

with open(path, "w") as fh:
    fh.write(encoded)
PYEOF

    # Upstream left this file inside a 0777 tree. It holds database credentials.
    chown xtreamcodes:xtreamcodes "$config_file"
    chmod 0400 "$config_file"

    log_ok "Config written to $config_file (mode 0400, owner xtreamcodes)."
}
