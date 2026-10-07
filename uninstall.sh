#!/bin/sh
# ==============================================================================
# oojq Sovereign Clean Uninstaller
# "Removes oojq binary, companion uninstaller, package installations, and cache."
#
# Usage:
#   curl -fsSL https://openooda-tools.github.io/oojq/uninstall.sh | bash
#   or: ./uninstall.sh [options]
#
# Options:
#   --prefix <dir>       Target directory where standalone binary was installed
#   --purge              Remove user caches and configuration
#   --dry-run            Simulate uninstallation without modifying the system
#   -y, --yes            Assume yes to all prompts (non-interactive)
#   -h, --help           Show this help message
# ==============================================================================

set -eu

if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ] && [ "${TERM:-dumb}" != "dumb" ]; then
    CYAN="\033[38;5;51m"
    GREEN="\033[38;5;82m"
    YELLOW="\033[38;5;220m"
    RED="\033[38;5;196m"
    DIM="\033[38;5;242m"
    BOLD="\033[1m"
    RESET="\033[0m"
else
    CYAN="" GREEN="" YELLOW="" RED="" DIM="" BOLD="" RESET=""
fi

say()  { printf '%b\n' "$*"; }
ok()   { say "  ${GREEN}✔${RESET} $*"; }
warn() { say "  ${YELLOW}!${RESET} $*"; }
err()  { say "  ${RED}ERROR:${RESET} $*" >&2; }
step() { say ""; say " ${CYAN}${BOLD}$*${RESET}"; }

PREFIX=""
PURGE=0
DRY_RUN=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)
            PREFIX="$2"
            shift 2
            ;;
        --purge)
            PURGE=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -y|--yes)
            ASSUME_YES=1
            shift
            ;;
        -h|--help)
            say "Usage: uninstall.sh [options]"
            say "Options:"
            say "  --prefix <dir>       Target directory where standalone binary was installed"
            say "  --purge              Remove user cache (~/.cache/oojq) and config"
            say "  --dry-run            Simulate uninstallation without modifying system"
            say "  -y, --yes            Assume yes to all prompts"
            say "  -h, --help           Show this help message"
            exit 0
            ;;
        *)
            err "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ "$ASSUME_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    CONFIRMED=0
    if [ -t 0 ]; then
        printf "Are you sure you want to completely uninstall oojq? [y/N] "
        read -r ANSWER
        case "$ANSWER" in [yY]|[yY][eE][sS]) CONFIRMED=1 ;; esac
    elif [ -e /dev/tty ]; then
        printf "Are you sure you want to completely uninstall oojq? [y/N] " </dev/tty
        read -r ANSWER </dev/tty
        case "$ANSWER" in [yY]|[yY][eE][sS]) CONFIRMED=1 ;; esac
    else
        CONFIRMED=1
    fi
    if [ "$CONFIRMED" -eq 0 ]; then
        say "Uninstallation cancelled by user."
        exit 0
    fi
fi

step "Relinquishing oojq from host"

HAS_SUDO=0
if command -v sudo >/dev/null 2>&1; then
    HAS_SUDO=1
fi

remove_file() {
    _target="$1"
    if [ -f "$_target" ] || [ -L "$_target" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            say "  ${DIM}[dry-run] Would remove: ${_target}${RESET}"
        else
            if [ -w "$(dirname "$_target")" ] && [ -w "$_target" ]; then
                rm -f "$_target" 2>/dev/null || true
            elif [ "$HAS_SUDO" -eq 1 ]; then
                sudo rm -f "$_target" 2>/dev/null || true
            else
                rm -f "$_target" 2>/dev/null || true
            fi
            ok "Removed ${_target}"
        fi
    fi
}

remove_dir() {
    _target="$1"
    if [ -d "$_target" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            say "  ${DIM}[dry-run] Would remove directory: ${_target}${RESET}"
        else
            if [ -w "$_target" ]; then
                rm -rf "$_target" 2>/dev/null || true
            elif [ "$HAS_SUDO" -eq 1 ]; then
                sudo rm -rf "$_target" 2>/dev/null || true
            else
                rm -rf "$_target" 2>/dev/null || true
            fi
            ok "Removed directory ${_target}"
        fi
    fi
}

# 1. Package Manager Uninstalls
if command -v dpkg >/dev/null 2>&1 && dpkg -s oojq >/dev/null 2>&1; then
    if [ "$DRY_RUN" -eq 1 ]; then
        say "  ${DIM}[dry-run] Would uninstall Debian package: oojq${RESET}"
    else
        if [ "$HAS_SUDO" -eq 1 ]; then
            sudo apt-get remove -y oojq 2>/dev/null || sudo dpkg -r oojq 2>/dev/null || true
        else
            dpkg -r oojq 2>/dev/null || true
        fi
        ok "Uninstalled Debian package oojq"
    fi
fi

if command -v rpm >/dev/null 2>&1 && rpm -q oojq >/dev/null 2>&1; then
    if [ "$DRY_RUN" -eq 1 ]; then
        say "  ${DIM}[dry-run] Would uninstall RPM package: oojq${RESET}"
    else
        if command -v dnf >/dev/null 2>&1; then
            if [ "$HAS_SUDO" -eq 1 ]; then sudo dnf remove -y oojq 2>/dev/null || true; else dnf remove -y oojq 2>/dev/null || true; fi
        elif [ "$HAS_SUDO" -eq 1 ]; then
            sudo rpm -e oojq 2>/dev/null || true
        else
            rpm -e oojq 2>/dev/null || true
        fi
        ok "Uninstalled RPM package oojq"
    fi
fi

if command -v pacman >/dev/null 2>&1; then
    for pkg in oojq oojq-bin; do
        if pacman -Qi "$pkg" >/dev/null 2>&1; then
            if [ "$DRY_RUN" -eq 1 ]; then
                say "  ${DIM}[dry-run] Would uninstall Arch package: ${pkg}${RESET}"
            else
                if [ "$HAS_SUDO" -eq 1 ]; then sudo pacman -R --noconfirm "$pkg" 2>/dev/null || true; else pacman -R --noconfirm "$pkg" 2>/dev/null || true; fi
                ok "Uninstalled Arch package ${pkg}"
            fi
        fi
    done
fi

# 2. Standalone Binary Targets
BIN_TARGETS="
/usr/local/bin/oojq
/usr/local/bin/oojq-uninstall
/usr/bin/oojq
/usr/bin/oojq-uninstall
${HOME}/.local/bin/oojq
${HOME}/.local/bin/oojq-uninstall
${HOME}/bin/oojq
${HOME}/bin/oojq-uninstall
${HOME}/.openooda/bin/oojq
${HOME}/.openooda/bin/oojq-uninstall
"
if [ -n "$PREFIX" ]; then
    BIN_TARGETS="$PREFIX/oojq $PREFIX/oojq-uninstall $BIN_TARGETS"
fi

for bp in $BIN_TARGETS; do
    remove_file "$bp"
done

# 3. Integrations, Man Pages, and Caches
EXTRA_TARGETS="
/usr/local/share/man/man1/oojq.1
/usr/share/man/man1/oojq.1
${HOME}/.local/share/man/man1/oojq.1
/usr/share/bash-completion/completions/oojq
/etc/bash_completion.d/oojq
${HOME}/.local/share/bash-completion/completions/oojq
/usr/share/zsh/site-functions/_oojq
${HOME}/.zsh/completion/_oojq
/usr/share/fish/vendor_completions.d/oojq.fish
${HOME}/.config/fish/completions/oojq.fish
"
for ep in $EXTRA_TARGETS; do
    remove_file "$ep"
done

if [ "$PURGE" -eq 1 ]; then
    remove_dir "${HOME}/.cache/oojq"
    remove_dir "${HOME}/.config/oojq"
fi

say ""
if [ "$DRY_RUN" -eq 1 ]; then
    ok "Dry run complete. No modifications made."
else
    ok "oojq has been cleanly uninstalled."
fi
