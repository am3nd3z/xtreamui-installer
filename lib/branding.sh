#!/usr/bin/env bash
# branding.sh - Theme the panel's login page and drop the browser-tab icon.
#
# The panel's login.php is plain, readable PHP -- unlike most of the panel, it
# is not obfuscated -- so it can be patched safely. What this does NOT do is
# rewrite the file: it makes four targeted insertions and leaves every line of
# authentication logic, flood control, 2FA and forced password change exactly
# as shipped.
#
# The theme itself lives in assets/css/xtreamui-brand.css on the server, not
# inline in the PHP, so it can be edited afterwards without touching code.
#
# Every step is guarded: if an anchor is missing -- because a different panel
# build is in use -- that step is skipped with a warning rather than corrupting
# the file. The result is validated with `php -l` and rolled back on failure.

_brand_css_target() { printf '%s/admin/assets/css/xtreamui-brand.css' "$PANEL_PATH"; }

# Resolve the repo root from this file's own location, not from SCRIPT_DIR.
# SCRIPT_DIR belongs to whoever sourced us -- the repo root for install.sh, but
# tools/ for the helper scripts -- so using it here looks for the template in
# the wrong place depending on the caller.
_brand_repo_root() {
    printf '%s' "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
}

install_brand_css() {
    local template; template="$(_brand_repo_root)/assets/login-theme.css"
    local target; target=$(_brand_css_target)

    if [[ ! -f "$template" ]]; then
        log_error "Theme template missing: $template"
        log_error "Run this from a complete checkout; assets/login-theme.css is required."
        return 1
    fi

    mkdir -p "$(dirname "$target")"

    sed -e "s|__BG_TOP__|${BRAND_BG_TOP}|g" \
        -e "s|__BG_MID__|${BRAND_BG_MID}|g" \
        -e "s|__WEDGE__|${BRAND_WEDGE}|g" \
        -e "s|__ACCENT_DEEP__|${BRAND_ACCENT_DEEP}|g" \
        -e "s|__ACCENT__|${BRAND_ACCENT}|g" \
        -e "s|__MUTED__|${BRAND_MUTED}|g" \
        -e "s|__PANEL__|${BRAND_PANEL}|g" \
        -e "s|__FIELD__|${BRAND_FIELD}|g" \
        -e "s|__LINE__|${BRAND_LINE}|g" \
        -e "s|__FONT_DISPLAY__|${BRAND_FONT_DISPLAY}|g" \
        -e "s|__FONT_BODY__|${BRAND_FONT_BODY}|g" \
        "$template" >"$target"

    chown xtreamcodes:xtreamcodes "$target"
    chmod 0644 "$target"

    # __ACCENT_DEEP__ is substituted before __ACCENT__ above on purpose: the
    # shorter token is a prefix of the longer one, and doing it the other way
    # round would leave a stray "_DEEP__" behind.
    if grep -q '__[A-Z_]*__' "$target"; then
        log_warn "Unsubstituted tokens remain in the theme CSS:"
        grep -o '__[A-Z_]*__' "$target" | sort -u | sed 's/^/    /'
    fi

    log_ok "Theme CSS written to admin/assets/css/xtreamui-brand.css"
}

# Patch login.php. Python rather than sed: the anchors span multiple lines and
# contain characters that make sed quoting error-prone.
patch_login_page() {
    local login="${PANEL_PATH}/admin/login.php"

    [[ -f "$login" ]] || { log_warn "login.php not found; skipping."; return 1; }

    # Refuse to touch an obfuscated build.
    if ! grep -q '<!DOCTYPE html>' "$login"; then
        log_warn "login.php does not look like the expected template; skipping."
        return 1
    fi

    local backup="${login}.bak-$(date +%Y%m%d-%H%M%S)"
    cp -a "$login" "$backup"

    local report
    report=$(BRAND_HIDE_FAVICON="$BRAND_HIDE_FAVICON" \
             BRAND_FONT_DISPLAY="$BRAND_FONT_DISPLAY" \
             BRAND_FONT_BODY="$BRAND_FONT_BODY" \
             python3 - "$login" <<'PYEOF'
import os, re, sys

path = sys.argv[1]
with open(path, encoding='utf-8', errors='surrogateescape') as fh:
    html = fh.read()

display = os.environ['BRAND_FONT_DISPLAY'].replace(' ', '+')
body    = os.environ['BRAND_FONT_BODY'].replace(' ', '+')
hide_fav = os.environ['BRAND_HIDE_FAVICON'] == 'yes'

applied, skipped = [], []

# 1. Favicon.
#
# An empty data URI, not a deleted tag: removing the link entirely makes the
# browser fall back to requesting /favicon.ico, which exists in this panel and
# would come straight back.
if hide_fav:
    new_html, n = re.subn(
        r'<link[^>]*rel=["\'](?:shortcut )?icon["\'][^>]*>',
        '<link rel="icon" href="data:,">',
        html, flags=re.I)
    if n:
        html = new_html
        applied.append('favicon removed (%d tag%s)' % (n, '' if n == 1 else 's'))
    else:
        skipped.append('favicon: no link tag found')

# 2. Fonts and theme stylesheet, immediately before </head> so they load last.
if 'xtreamui-brand.css' not in html:
    links = (
        '        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>\n'
        '        <link href="https://fonts.googleapis.com/css2?family=%s:wght@500;700'
        '&family=%s:wght@400;500;600;700&display=swap" rel="stylesheet">\n'
        '        <link href="assets/css/xtreamui-brand.css" rel="stylesheet" type="text/css" />\n'
        '    </head>' % (display, body)
    )
    if '</head>' in html:
        html = html.replace('</head>', links, 1)
        applied.append('theme stylesheet linked')
    else:
        skipped.append('stylesheet: no </head> found')
else:
    applied.append('theme stylesheet already linked')

# 3. Header bar, right after <body>. The server name is escaped by the PHP,
#    then split on the first space so the second half takes the accent colour.
if 'class="brandbar"' not in html:
    m = re.search(r'<body[^>]*>', html, flags=re.I)
    if m:
        bar = m.group(0) + '''
        <?php
        $rBrand      = htmlspecialchars($rSettings["server_name"]);
        $rBrandParts = explode(" ", $rBrand, 2);
        ?>
        <div class="brandbar">
            <span class="mark"><i></i></span>
            <span class="name"><?=$rBrand?></span>
        </div>'''
        html = html[:m.start()] + bar + html[m.end():]
        applied.append('header bar inserted')
    else:
        skipped.append('header bar: no <body> tag found')
else:
    applied.append('header bar already present')

# 4. Hero block, before the login card. The stack of <br> tags the stock
#    template uses for spacing is replaced if present.
if 'class="login-brand"' not in html:
    hero = '''<div class="login-brand">
                            <span class="login-pill"><?=$_["admin_reseller_interface"]?></span>
                            <h1><?=$rBrandParts[0]?><?php if (isset($rBrandParts[1])) { ?> <span class="accent"><?=$rBrandParts[1]?></span><?php } ?></h1>
                            <p class="tagline"><?=$_["welcome_login"]?></p>
                        </div>
                        <div class="card">'''
    new_html, n = re.subn(r'(?:<br>\s*)+<div class="card">', hero, html, count=1)
    if n == 0:
        new_html, n = re.subn(r'<div class="card">', hero, html, count=1)
    if n:
        html = new_html
        applied.append('hero block inserted')
    else:
        skipped.append('hero: no login card found')
else:
    applied.append('hero block already present')

with open(path, 'w', encoding='utf-8', errors='surrogateescape') as fh:
    fh.write(html)

for line in applied:
    print('OK|' + line)
for line in skipped:
    print('SKIP|' + line)
PYEOF
    ) || { cp -a "$backup" "$login"; die "The login patcher failed; the original was restored."; }

    while IFS='|' read -r kind message; do
        [[ -z "$kind" ]] && continue
        case "$kind" in
            OK)   log_ok   "$message" ;;
            SKIP) log_warn "$message" ;;
        esac
    done <<<"$report"

    # Validate. A broken login page locks the operator out of their own panel,
    # so a failed syntax check restores the backup rather than leaving it.
    local php_bin="${PANEL_PATH}/php/bin/php"
    [[ -x "$php_bin" ]] || php_bin="php"

    if "$php_bin" -l "$login" >/dev/null 2>&1; then
        chown xtreamcodes:xtreamcodes "$login"
        chmod 0644 "$login"
        log_ok "login.php patched and valid. Backup: ${backup}"
    else
        log_error "Patched login.php failed its syntax check:"
        "$php_bin" -l "$login" 2>&1 | head -3 | sed 's/^/    /' || true
        cp -a "$backup" "$login"
        log_error "The original was restored."
        return 1
    fi

    # The form must still be intact. Losing a field here would be worse than
    # an ugly page.
    local missing=0 field
    for field in 'name="username"' 'name="password"' 'id="login_form"' 'action="./login.php"'; do
        grep -q -- "$field" "$login" || { log_error "Missing after patch: ${field}"; missing=1; }
    done
    if (( missing )); then
        cp -a "$backup" "$login"
        log_error "Form fields went missing; the original was restored."
        return 1
    fi
    log_ok "Login form verified intact."
}

# The tab icon is referenced from the dashboard templates too, so clearing it
# only in login.php leaves it reappearing once the operator signs in.
hide_favicon_everywhere() {
    [[ "$BRAND_HIDE_FAVICON" == "yes" ]] || return 0

    local file count=0
    for file in "${PANEL_PATH}/admin/header.php" \
                "${PANEL_PATH}/admin/header_sidebar.php"; do
        [[ -f "$file" ]] || continue
        grep -qE 'rel=["'"'"'](shortcut )?icon' "$file" || continue

        cp -a "$file" "${file}.bak-$(date +%Y%m%d-%H%M%S)"
        sed -i -E 's|<link[^>]*rel="(shortcut )?icon"[^>]*>|<link rel="icon" href="data:,">|Ig' "$file"
        count=$((count + 1))
    done

    (( count > 0 )) \
        && log_ok "Tab icon cleared from ${count} dashboard template(s)." \
        || log_info "No favicon references in the dashboard templates."
}

set_panel_brand_name() {
    [[ -n "${BRAND_NAME:-}" ]] || return 0

    local escaped="${BRAND_NAME//\'/\\\'}"
    if mysql_exec "UPDATE settings SET server_name = '${escaped}' WHERE id = 1;" "$DB_NAME" >/dev/null; then
        log_ok "Panel name set to '${BRAND_NAME}'."
        log_info "A name of two words renders the second half in the accent colour."
    else
        log_warn "Could not set the panel name."
    fi
}

apply_branding() {
    if [[ "${BRANDING_ENABLED}" != "yes" ]]; then
        log_info "Login branding skipped (--no-branding)."
        return 0
    fi

    log_step "Applying login branding"

    # Branding is cosmetic: a failure here must never abort an otherwise good
    # install, so each step is allowed to fail with a warning.
    set_panel_brand_name   || log_warn "Panel name unchanged."
    install_brand_css      || log_warn "Theme CSS not installed."
    patch_login_page       || log_warn "Login page left as shipped."
    hide_favicon_everywhere || true

    # The panel caches settings, so the new name would otherwise take a while
    # to appear.
    runuser -u xtreamcodes -- "${PANEL_PATH}/php/bin/php" \
        "${PANEL_PATH}/crons/setup_cache.php" >/dev/null 2>&1 || true
}
