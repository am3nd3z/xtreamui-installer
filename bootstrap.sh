#!/usr/bin/env bash
#
# bootstrap.sh - one-command entry point for xtreamui-installer.
#
#   curl -fsSL https://raw.githubusercontent.com/am3nd3z/xtreamui-installer/main/bootstrap.sh \
#     | sudo bash -s -- --admin-port 8091 --client-port 8080 --admin-user admin \
#         --email you@example.com --timezone America/Mexico_City \
#         --tarball-url https://your.host/xui.tar.gz --yes
#
# install.sh cannot be piped into bash directly: it sources lib/*.sh relative to
# its own location, and ${BASH_SOURCE[0]} is "stdin" when a script arrives over a
# pipe. This fetches the whole tree first, then runs the real installer.
#
# Pin a specific commit or tag instead of tracking main:
#   curl ... | sudo XUI_REF=v0.9.0 bash -s -- ...

set -Eeuo pipefail

REPO="${XUI_REPO:-am3nd3z/xtreamui-installer}"
REF="${XUI_REF:-main}"
KEEP="${XUI_KEEP:-no}"

say()  { printf '\033[1;34m[boot]\033[0m %s\n' "$1"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$1" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root: pipe into 'sudo bash', not plain 'bash'."

for cmd in curl tar; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
done

WORKDIR="$(mktemp -d)"
cleanup() {
    if [[ "$KEEP" == "yes" ]]; then
        printf '[boot] Left in place: %s\n' "$WORKDIR"
    else
        rm -rf "$WORKDIR"
    fi
}
trap cleanup EXIT

say "Fetching ${REPO} @ ${REF}"

TARBALL="${WORKDIR}/src.tar.gz"
URL="https://codeload.github.com/${REPO}/tar.gz/${REF}"

curl -fsSL --proto '=https' --tlsv1.2 --max-time 120 -o "$TARBALL" "$URL" \
    || die "Could not download ${URL} -- check the repo is public and the ref exists."

# A private repo or a bad ref returns a short HTML error page, not an archive.
SIZE=$(stat -c%s "$TARBALL" 2>/dev/null || echo 0)
(( SIZE > 2048 )) || die "Downloaded file is only ${SIZE} bytes; that is not the archive."

tar -tzf "$TARBALL" >/dev/null 2>&1 || die "Downloaded file is not a valid tar.gz."

tar -xzf "$TARBALL" -C "$WORKDIR" || die "Could not extract the archive."

SRC="$(find "$WORKDIR" -maxdepth 1 -mindepth 1 -type d | head -1)"
[[ -n "$SRC" && -f "${SRC}/install.sh" ]] || die "install.sh not found in the archive."

chmod +x "${SRC}/install.sh" "${SRC}"/tools/*.sh 2>/dev/null || true
ok "Source ready at ${SRC}"

# stdin belongs to the pipe, so install.sh's confirmation prompts would read
# EOF and abort. Hand it the terminal when there is one; otherwise insist on
# --yes rather than letting it fail halfway through with a confusing message.
STDIN_SRC="/dev/null"
if [[ -e /dev/tty ]] && (: >/dev/tty) 2>/dev/null; then
    STDIN_SRC="/dev/tty"
else
    case " $* " in
        *" --yes "*|*" -y "*|*" --dry-run "*) ;;
        *) die "No terminal available for prompts. Add --yes to run unattended." ;;
    esac
fi

say "Starting the installer"
printf '\n'

# Deliberately not `exec`: that replaces the process image and the EXIT trap
# never fires, leaving the temporary directory behind on every run. Run it as
# a child and pass its exit code up instead.
cd "$SRC"
set +e
./install.sh "$@" <"$STDIN_SRC"
RC=$?
set -e
exit "$RC"
