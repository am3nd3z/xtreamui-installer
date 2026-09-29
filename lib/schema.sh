#!/usr/bin/env bash
# schema.sh - Post-import database fixes the panel needs but its own schema omits.
#
# The upstream installer downloads update_reg_users.py (which is SQL, not
# Python) and pipes it into mysql. That file carries settings rows, primary keys
# and panel defaults that database.sql does not include.
#
# It also contains a syntax error:
#
#     ALTER TABLE `reg_users`
#       ADD PRIMARY KEY (`id`),
#       ...
#       ADD KEY `password` (`password`);
#       ADD KEY `email` (`email`);          <- orphaned after the semicolon
#
# `ADD KEY ...` on its own is not a statement. mysql stops there and, with no
# --force, silently abandons everything after it. On a stock install that means
# admin_settings ends up with 10 of its 25 rows, the settings table never gets
# its primary key, and none of the panel defaults are applied. The installation
# looks successful and the panel half-works.
#
# What follows is that file's intent, corrected, made idempotent, and applied
# with errors actually checked.

# Run a statement and fail loudly. Unlike the upstream import, nothing here is
# allowed to fail quietly.
_schema_exec() {
    local sql="$1" description="$2"

    if ! mysql_exec "$sql" "$DB_NAME" >/dev/null 2>&1; then
        log_warn "Schema step failed: ${description}"
        return 1
    fi
    return 0
}

# mysql_exec prints the server's error text to stdout as well as returning a
# non-zero status. Both helpers below check that status, because a caller that
# only looks at the output will happily read "ERROR 1045 Access denied" as data
# -- which silently skips the very fix the check was guarding.

# One value, or empty on any error.
_query_scalar() {
    local out
    out=$(mysql_exec "$1" "$DB_NAME") || { printf ''; return 1; }
    printf '%s' "$(printf '%s' "$out" | tail -1 | tr -d '[:space:]')"
}

_table_has_primary_key() {
    local table="$1" result
    result=$(mysql_exec "SHOW KEYS FROM \`${table}\` WHERE Key_name='PRIMARY';" "$DB_NAME") \
        || return 1
    [[ "$result" == *PRIMARY* ]]
}

# The panel writes to settings by id and to admin_settings by type. Without
# primary keys, duplicate rows accumulate and ON DUPLICATE KEY UPDATE cannot
# work at all.
ensure_primary_keys() {
    log_step "Ensuring primary keys"

    if _table_has_primary_key settings; then
        log_info "settings already has a primary key."
    else
        _schema_exec "ALTER TABLE settings ADD PRIMARY KEY(id);" "settings primary key" \
            && log_ok "Added primary key on settings.id"
    fi

    if _table_has_primary_key admin_settings; then
        log_info "admin_settings already has a primary key."
    else
        # Collapse any duplicates first, or adding the key fails.
        _schema_exec "
            CREATE TEMPORARY TABLE _as_dedup AS
                SELECT type, MAX(value) AS value FROM admin_settings GROUP BY type;
            DELETE FROM admin_settings;
            INSERT INTO admin_settings (type, value) SELECT type, value FROM _as_dedup;
            DROP TEMPORARY TABLE _as_dedup;
        " "admin_settings deduplication"

        _schema_exec "ALTER TABLE admin_settings ADD PRIMARY KEY(type);" "admin_settings primary key" \
            && log_ok "Added primary key on admin_settings.type"
    fi
}

# The rows the panel reads at runtime. Missing ones make the admin UI behave as
# though features are disabled, and geolite2_version missing is why the upstream
# installer's own GeoIP version UPDATE is a silent no-op.
seed_admin_settings() {
    log_step "Seeding admin_settings"

    local now
    now=$(date +%s)

    local clear_log_tables='["flushActivity","flushActivitynow","flushPanelogs","flushLoginlogs","flushLogins","flushMagclaims","flushStlogs","flushClientlogs","flushEvents","flushMaglogs"]'

    # ON DUPLICATE KEY UPDATE type=type: insert when absent, never clobber a
    # value the operator has already changed in the panel.
    _schema_exec "
        INSERT INTO admin_settings (type, value) VALUES
            ('active_mannuals',        '1'),
            ('auto_refresh',           '1'),
            ('cc_time',                '${now}'),
            ('geolite2_version',       '1'),
            ('panel_version',          '1'),
            ('reseller_can_isplock',   '1'),
            ('reseller_reset_isplock', '1'),
            ('reseller_reset_stb',     '1'),
            ('show_tickets',           '1'),
            ('stats_pid',              ''),
            ('tmdb_pid',               ''),
            ('watch_pid',              ''),
            ('ip_logout',              '1'),
            ('reseller_restrictions',  '1'),
            ('change_own_dns',         '1'),
            ('change_own_email',       '1'),
            ('change_own_password',    '1'),
            ('change_own_lang',        '1'),
            ('reseller_view_info',     '1'),
            ('active_apps',            '1'),
            ('reseller_mag_to_m3u',    '1'),
            ('order_streams',          '1'),
            ('release_parser',         'python2'),
            ('clear_log_auto',         '1'),
            ('clear_log_check',        '${now}'),
            ('clear_log_tables',       '${clear_log_tables}')
        ON DUPLICATE KEY UPDATE type = type;
    " "admin_settings rows" && log_ok "admin_settings seeded (existing values preserved)."

    local count
    count=$(_query_scalar "SELECT COUNT(*) FROM admin_settings;") || true
    log_info "admin_settings now holds ${count:-?} rows."
}

# Panel behaviour defaults. These are the values the upstream SQL intended to
# set and never reached.
apply_panel_defaults() {
    log_step "Applying panel defaults"

    _schema_exec "
        UPDATE settings SET
            disallow_empty_user_agents = '1',
            hash_lb                    = '1',
            audio_restart_loss         = '1',
            disallow_2nd_ip_con        = '1',
            block_svp                  = '1',
            priority_backup            = '1',
            mag_security               = '1',
            stb_change_pass            = '1',
            stalker_lock_images        = '1',
            vod_bitrate_plus           = '300',
            vod_limit_at               = '10'
        WHERE id = 1;
    " "panel defaults" && log_ok "Panel defaults applied."

    # Deliberately NOT set here, unlike upstream:
    #
    #   default_locale = 'pt_PT.utf8'   upstream hardcodes Portuguese
    #   enable_isp_lock = '1'           locks clients to their ISP
    #   county_override_1st = '1'
    #
    # Locale follows the installer's own configuration, and the lock-down
    # options are policy choices that belong to the operator, not the installer.
    # Locale and timezone.
    #
    # The panel keeps its own timezone in settings.default_timezone, separate
    # from the system clock and from PHP's date.timezone. Upstream never sets
    # it, so it keeps whatever database.sql shipped -- Europe/London -- while
    # the OS is on something else entirely and php.ini's date.timezone is left
    # empty (its sed substitutes $timezone, a variable the installer never
    # assigns; it uses $tz). Three clocks, three different answers, and an EPG
    # that is silently hours off.
    _schema_exec "
        UPDATE settings SET
            default_locale   = '${PANEL_LOCALE}',
            default_timezone = '${TIMEZONE}'
        WHERE id = 1;
    " "panel locale and timezone" \
        && log_ok "Panel locale ${PANEL_LOCALE}, timezone ${TIMEZONE}"
}

# The stream output formats a client line can be granted: HLS, MPEGTS, RTMP.
#
# Worth understanding because it produces one of the panel's least obvious
# failures. Client lines get their formats from user_output, and the panel
# assigns nothing by default -- so a newly created user with no rows there can
# authenticate perfectly and still be refused every stream.
#
# The symptom is a bare HTTP 405 to the player, with the real reason only in
# the client_logs table as USER_DISALLOW_EXT. It bites hardest with a URL of
# the form /username/password/id, because nginx rewrites that to extension=ts
# -- so a line granted only HLS fails on exactly the URL the panel's own
# get.php hands out for output=ts.
#
# If access_output itself is empty, no line can ever be granted anything.
ensure_access_outputs() {
    log_step "Checking stream output formats"

    local count
    count=$(_query_scalar "SELECT COUNT(*) FROM access_output;") || true

    if [[ -z "$count" || "$count" == "0" ]]; then
        log_warn "access_output is empty. No client line will be able to play anything."
        log_info "Seeding the standard formats."
        _schema_exec "
            INSERT INTO access_output (access_output_id, output_name, output_key, output_ext)
            VALUES (1,'HLS','m3u8','m3u8'), (2,'MPEGTS','ts','ts'), (3,'RTMP','rtmp','')
            ON DUPLICATE KEY UPDATE output_name = VALUES(output_name);
        " "access_output rows" && log_ok "Seeded HLS, MPEGTS and RTMP."
    else
        log_ok "${count} output formats available."
    fi
}

# Grant output formats to client lines that have none.
#
# Idempotent, and it never removes a format an operator has chosen. Called with
# no argument it covers every line missing formats; with a user id, just that one.
grant_user_outputs() {
    local target_user="${1:-}"
    local formats="${2:-$DEFAULT_USER_OUTPUTS}"

    # Resolve the target lines ONCE, before granting anything.
    #
    # Selecting them inside the per-format loop does not work: after the first
    # format is granted, those lines are no longer "missing formats", so the
    # second format skips them and every user ends up with exactly one.
    local targets
    if [[ -n "$target_user" ]]; then
        targets="$target_user"
    else
        targets=$(mysql_exec "
            SELECT u.id FROM users u
            WHERE NOT EXISTS (SELECT 1 FROM user_output uo WHERE uo.user_id = u.id);
        " "$DB_NAME") || return 1
        # mysql_exec keeps the column header, so drop anything non-numeric here
        # rather than only skipping it in the loop -- otherwise the header is
        # counted as a user in the summary.
        targets=$(printf '%s' "$targets" | tr -d '\r' | tr '\n' ' ' \
            | tr ' ' '\n' | grep -E '^[0-9]+$' | tr '\n' ' ') || true
    fi

    [[ -n "${targets// /}" ]] || { log_info "No client lines need output formats."; return 0; }

    local uid key granted=0
    for uid in $targets; do
        for key in ${formats//,/ }; do
            _schema_exec "
                INSERT INTO user_output (user_id, access_output_id)
                SELECT ${uid}, ao.access_output_id
                FROM access_output ao
                WHERE ao.output_key = '${key}'
                  AND NOT EXISTS (
                      SELECT 1 FROM user_output uo
                      WHERE uo.user_id = ${uid}
                        AND uo.access_output_id = ao.access_output_id
                  );
            " "granting ${key} to user ${uid}" && granted=$((granted + 1))
        done
    done

    log_ok "Granted '${formats}' across $(printf '%s' "$targets" | wc -w) client line(s)."
}

# Lines that can authenticate but cannot play anything.
report_users_without_outputs() {
    local orphans
    orphans=$(_query_scalar "
        SELECT COUNT(*) FROM users u
        WHERE NOT EXISTS (SELECT 1 FROM user_output uo WHERE uo.user_id = u.id);
    ") || true

    if [[ -n "$orphans" && "$orphans" != "0" ]]; then
        log_warn "${orphans} client line(s) have no output format assigned."
        log_warn "They will authenticate and then be refused every stream with HTTP 405."
        log_warn "Fix with: tools/fix-user-outputs.sh"
        return 1
    fi
    return 0
}

# Output formats offered under "Devices" in the panel. database.sql ships 20;
# the upstream SQL adds a 21st ('get', a shell downloader).
ensure_device_formats() {
    log_step "Checking device output formats"

    local count
    count=$(_query_scalar "SELECT COUNT(*) FROM devices;") || true

    if [[ -z "$count" || "$count" == "0" ]]; then
        log_warn "The devices table is empty. Clients will not be able to download playlists."
        log_warn "This usually means the panel archive's database.sql was incomplete."
        return 0
    fi

    log_ok "${count} output formats available (m3u, m3u_plus, enigma, ...)."
}

# A last look at the things that actually stop the panel working, so a broken
# import cannot pass for a successful install the way the upstream one does.
verify_schema() {
    log_step "Verifying the database"

    local problems=0

    local admin_count
    admin_count=$(_query_scalar "SELECT COUNT(*) FROM reg_users WHERE id=1;") || true
    if [[ "$admin_count" == "1" ]]; then
        log_ok "Administrator account present."
    else
        log_error "No administrator in reg_users. You will not be able to log in."
        problems=$((problems + 1))
    fi

    local server_ip
    server_ip=$(_query_scalar "SELECT server_ip FROM streaming_servers WHERE id=1;") || true
    if [[ -n "$server_ip" && "$server_ip" != "NULL" ]]; then
        log_ok "streaming_servers.server_ip = ${server_ip}"
    else
        log_error "server_ip is empty. Stream URLs will be malformed."
        problems=$((problems + 1))
    fi

    for table in settings admin_settings; do
        if _table_has_primary_key "$table"; then
            log_ok "${table} has a primary key."
        else
            log_warn "${table} has no primary key."
            problems=$((problems + 1))
        fi
    done

    local settings_rows
    settings_rows=$(_query_scalar "SELECT COUNT(*) FROM settings;") || true
    [[ "$settings_rows" == "1" ]] \
        && log_ok "settings has exactly one row." \
        || log_warn "settings has ${settings_rows:-?} rows; the panel expects one."

    local outputs
    outputs=$(_query_scalar "SELECT COUNT(*) FROM access_output;") || true
    if [[ -n "$outputs" && "$outputs" != "0" ]]; then
        log_ok "${outputs} stream output formats available."
    else
        log_error "access_output is empty. No client will be able to play anything."
        problems=$((problems + 1))
    fi

    report_users_without_outputs || true

    # Three clocks have to agree, and nothing else checks that they do.
    local db_tz php_tz sys_tz
    db_tz=$(_query_scalar "SELECT default_timezone FROM settings WHERE id=1;") || true
    sys_tz=$(timedatectl show -p Timezone --value 2>/dev/null) || true
    php_tz=$(grep -E '^date\.timezone' "${PANEL_PATH}/php/lib/php.ini" 2>/dev/null \
        | cut -d= -f2- | tr -d '[:space:]') || true

    if [[ "$db_tz" == "$sys_tz" && "$php_tz" == "$sys_tz" ]]; then
        log_ok "Timezone consistent across system, PHP and panel: ${sys_tz}"
    else
        log_warn "Timezone mismatch -- EPG times will be wrong:"
        log_warn "  system: ${sys_tz:-unset}   php: ${php_tz:-EMPTY}   panel: ${db_tz:-unset}"
        problems=$((problems + 1))
    fi

    if (( problems == 0 )); then
        log_ok "Database verification passed."
    else
        log_warn "${problems} database problem(s) found. The panel may not work correctly."
    fi
}

apply_schema_fixes() {
    ensure_primary_keys
    seed_admin_settings
    apply_panel_defaults
    ensure_access_outputs
    ensure_device_formats
}
