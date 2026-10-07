#!/bin/sh
# ==============================================================================
# oojq Universal Installer
# "Capability-bounded jq replacement with a first-class MCP surface."
#
# Usage:
#   curl -fsSL https://openooda-tools.github.io/oojq/install.sh | bash
#
# Options:
#   --prefix <dir>   Installation directory (default: /usr/local/bin or ~/.local/bin)
#   --dry-run        Simulate installation without touching the filesystem
#   --verify         Perform strict cryptographic SHA-256 integrity verification
#   --uninstall      Remove oojq binary from standard system paths
#   -h, --help       Show this help message
# ==============================================================================

set -eu

REPO="openOODA-tools/oojq"
GITHUB_URL="https://github.com/${REPO}"
CANONICAL_URL="https://openooda-tools.github.io/oojq"
VERSION_PIN="v0.1.0"

# --- Styling & Human Interface Standard ---------------------------------------
if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ] && [ "${TERM:-dumb}" != "dumb" ]; then
    AMBER="\033[38;5;214m"
    CYAN="\033[38;5;51m"
    GREEN="\033[38;5;82m"
    YELLOW="\033[38;5;220m"
    MAGENTA="\033[38;5;213m"
    DIM="\033[38;5;242m"
    BOLD="\033[1m"
    RESET="\033[0m"
    IS_TTY=1
else
    AMBER="" CYAN="" GREEN="" YELLOW="" MAGENTA="" DIM="" BOLD="" RESET=""
    IS_TTY=0
fi

say()  { printf '%b\n' "$*"; }
dim()  { say "  ${DIM}$*${RESET}"; }
ok()   { say "  ${GREEN}✔${RESET} $*"; }
warn() { say "  ${YELLOW}!${RESET} $*"; }
err()  { say "  ${YELLOW}ERROR:${RESET} $*" >&2; }
step() { say ""; say " ${CYAN}${BOLD}$*${RESET}"; }

pause() {
    _s="${1:-0.25}"
    if [ "$IS_TTY" -eq 1 ]; then
        sleep "$_s" 2>/dev/null || true
    fi
}

story_line() {
    say "  ${MAGENTA}›${RESET} ${DIM}$*${RESET}"
    pause 0.2
}

spin_while() {
    _pid="$1"
    _label="$2"
    _i=0
    if [ "$IS_TTY" -eq 0 ]; then
        wait "$_pid"
        return $?
    fi
    while kill -0 "$_pid" 2>/dev/null; do
        case $((_i % 4)) in
            0) _ch='⠋' ;;
            1) _ch='⠙' ;;
            2) _ch='⠹' ;;
            3) _ch='⠸' ;;
        esac
        printf "\r  ${CYAN}%s${RESET} %s…  " "$_ch" "$_label"
        _i=$((_i + 1))
        sleep 0.08 2>/dev/null || true
    done
    wait "$_pid"
    _rc=$?
    printf '\r\033[K'
    return $_rc
}

countdown() {
    _n="${1:-3}"
    _msg="${2:-Launching}"
    if [ "$IS_TTY" -eq 0 ]; then
        return 0
    fi
    while [ "$_n" -gt 0 ]; do
        printf "\r  ${AMBER}${BOLD}%s${RESET} in ${BOLD}%s${RESET}…   " "$_msg" "$_n"
        sleep 0.8
        _n=$((_n - 1))
    done
    printf '\r\033[K'
}

clear_soft() {
    if [ "$IS_TTY" -eq 1 ] && command -v clear >/dev/null 2>&1; then
        clear 2>/dev/null || true
    fi
}

banner() {
    clear_soft
    say ""
    say "${AMBER}${BOLD}"
    cat <<'BANNER'
        ╔══════════════════════════════════════════════════════════╗
        ║                                                          ║
        ║    ██████╗  ██████╗      ██╗ ██████╗                     ║
        ║   ██╔═══██╗██╔═══██╗     ██║██╔═══██╗                    ║
        ║   ██║   ██║██║   ██║     ██║██║   ██║                    ║
        ║   ██║   ██║██║   ██║██   ██║██║▄▄ ██║                    ║
        ║   ╚██████╔╝╚██████╔╝╚█████╔╝╚██████╔╝                    ║
        ║    ╚═════╝  ╚═════╝  ╚════╝  ╚══▀▀═╝                     ║
        ║                                                          ║
        ║                openOODA JSON Filter Engine               ║
        ║         Fast / Capability-Bounded / Agent-Ready          ║
        ║                                                          ║
        ╚══════════════════════════════════════════════════════════╝
BANNER
    say "${RESET}"
    say "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    say ""
}

victory_banner() {
    say ""
    say "${GREEN}${BOLD}"
    cat <<'VICTORY'
        ╔══════════════════════════════════════════════════════════╗
        ║                                                          ║
        ║               ⚡ SOVEREIGNTY AWAKENED ⚡                  ║
        ║                                                          ║
        ╚══════════════════════════════════════════════════════════╝
VICTORY
    say "${RESET}"
    say "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    say ""
}

# --- Argument Parsing ---------------------------------------------------------
DRY_RUN=0
DO_UNINSTALL=0
DO_VERIFY=0
CUSTOM_PREFIX=""
INSTALL_DEB=0
INSTALL_DNF=0
INSTALL_ARCH=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --uninstall|--remove) DO_UNINSTALL=1; shift ;;
        --verify) DO_VERIFY=1; shift ;;
        --prefix) CUSTOM_PREFIX="$2"; shift 2 ;;
        --deb|--apt) INSTALL_DEB=1; shift ;;
        --dnf|--rpm) INSTALL_DNF=1; shift ;;
        --pkgbuild|--arch) INSTALL_ARCH=1; shift ;;
        -h|--help)
            banner
            say "  ${BOLD}Usage:${RESET} curl -fsSL .../install.sh | bash [options]"
            say ""
            say "  ${BOLD}Options:${RESET}"
            say "    ${CYAN}--prefix <dir>${RESET}     Target binary directory (default: /usr/local/bin or ~/.local/bin)"
            say "    ${CYAN}--deb, --apt${RESET}       Download and install Debian package (.deb) via apt/dpkg"
            say "    ${CYAN}--dnf, --rpm${RESET}       Download and install RPM package (.rpm) via dnf"
            say "    ${CYAN}--pkgbuild, --arch${RESET} Download and install Arch Linux package via makepkg"
            say "    ${CYAN}--dry-run${RESET}          Simulate deployment without modifying host"
            say "    ${CYAN}--verify${RESET}           Verify cryptographic SHA-256 seal and exit"
            say "    ${CYAN}--uninstall, --remove${RESET} Cleanly remove oojq binary, uninstaller, packages, and caches"
            say "    ${CYAN}-h, --help${RESET}         Display this manual"
            say ""
            say "  ${BOLD}Direct Package Manager Invocations:${RESET}"
            say "    ${CYAN}DNF:${RESET}      curl -fsSL ${CANONICAL_URL}/install.sh | bash -s -- --dnf"
            say "    ${CYAN}APT:${RESET}      curl -fsSL ${CANONICAL_URL}/install.sh | bash -s -- --deb"
            say "    ${CYAN}PKGBUILD:${RESET} curl -fsSL ${CANONICAL_URL}/install.sh | bash -s -- --pkgbuild"
            say ""
            say "  ${BOLD}Clean Uninstallation:${RESET}"
            say "    ${CYAN}Uninstall:${RESET} curl -fsSL ${CANONICAL_URL}/install.sh | bash -s -- --uninstall"
            say "    ${CYAN}Local:${RESET}     oojq-uninstall (if installed)"
            say ""
            exit 0
            ;;
        *) err "Unknown flag: $1"; exit 1 ;;
    esac
done

banner
story_line "Attuning your environment to openOODA JSON transformation…"
pause 0.3

# --- Uninstall Path -----------------------------------------------------------
if [ "$DO_UNINSTALL" -eq 1 ]; then
    step "Relinquishing oojq"
    if [ "$DRY_RUN" -eq 1 ]; then
        dim "Would check package manager registrations (dpkg, rpm, pacman)"
        dim "Would remove binaries (/usr/local/bin/oojq, ~/.local/bin/oojq, /usr/bin/oojq)"
        dim "Would remove companion uninstaller (oojq-uninstall)"
        dim "Would purge cache and configuration directories (~/.cache/oojq, ~/.config/oojq)"
        ok "Simulation complete. No host modifications made."
        exit 0
    fi
    if command -v dpkg >/dev/null 2>&1 && dpkg -s oojq >/dev/null 2>&1; then
        sudo apt-get remove -y oojq 2>/dev/null || sudo dpkg -r oojq 2>/dev/null || true
        ok "Removed oojq Debian package"
    elif command -v rpm >/dev/null 2>&1 && rpm -q oojq >/dev/null 2>&1; then
        sudo dnf remove -y oojq 2>/dev/null || sudo rpm -e oojq 2>/dev/null || true
        ok "Removed oojq RPM package"
    elif command -v pacman >/dev/null 2>&1 && pacman -Q oojq >/dev/null 2>&1; then
        sudo pacman -R --noconfirm oojq 2>/dev/null || true
        ok "Removed oojq Arch package"
    elif command -v pacman >/dev/null 2>&1 && pacman -Q oojq-bin >/dev/null 2>&1; then
        sudo pacman -R --noconfirm oojq-bin 2>/dev/null || true
        ok "Removed oojq Arch package"
    fi
    FOUND=0
    for p in /usr/local/bin/oojq "${HOME}/.local/bin/oojq" "${HOME}/.openooda/bin/oojq" /usr/bin/oojq \
             /usr/local/bin/oojq-uninstall "${HOME}/.local/bin/oojq-uninstall" "${HOME}/.openooda/bin/oojq-uninstall" /usr/bin/oojq-uninstall; do
        if [ -f "$p" ]; then
            rm -f "$p" 2>/dev/null || sudo rm -f "$p"
            ok "Banished ${BOLD}$p${RESET}"
            FOUND=1
        fi
    done
    for c in "${HOME}/.cache/oojq" "${HOME}/.config/oojq"; do
        if [ -d "$c" ]; then
            rm -rf "$c" 2>/dev/null || sudo rm -rf "$c" 2>/dev/null || true
            ok "Purged cache ${BOLD}$c${RESET}"
        fi
    done
    if [ "$FOUND" -eq 0 ]; then
        warn "No existing oojq installation detected in standard search paths."
    else
        ok "Clean uninstallation complete."
    fi
    say ""
    exit 0
fi


# --- DEB / APT Installation ---
if [ "$INSTALL_DEB" -eq 1 ]; then
    step "Installing oojq via DEB/apt (${VERSION_PIN})"
    RAW_VERSION="${VERSION_PIN#v}"
    DEB_NAME="oojq_${RAW_VERSION}-1_amd64.deb"
    DEB_URL="${GITHUB_URL}/releases/download/${VERSION_PIN}/${DEB_NAME}"
    if [ "$DRY_RUN" -eq 1 ]; then
        say "  ${DIM}fetch${RESET}   ${CYAN}${DEB_URL}${RESET}"
        say "  ${DIM}deploy${RESET}  ${CYAN}sudo dpkg -i ... || sudo apt-get install -f -y${RESET}"
        ok "Simulation complete."
        exit 0
    fi
    TMP_DEB="$(mktemp /tmp/oojq-deb.XXXXXX.deb)"
    story_line "Fetching Debian package from sovereign release channel…"
    curl -fsSL "$DEB_URL" -o "$TMP_DEB" &
    spin_while $! "Streaming ${DEB_NAME}"
    sudo dpkg -i "$TMP_DEB" || sudo apt-get install -f -y
    rm -f "$TMP_DEB"
    ok "Installed oojq Debian package."
    oojq --version
    exit 0
fi

# --- DNF / RPM Installation ---
if [ "$INSTALL_DNF" -eq 1 ]; then
    step "Installing oojq via DNF/rpm (${VERSION_PIN})"
    RAW_VERSION="${VERSION_PIN#v}"
    RPM_NAME="oojq-${RAW_VERSION}-1.x86_64.rpm"
    RPM_URL="${GITHUB_URL}/releases/download/${VERSION_PIN}/${RPM_NAME}"
    if [ "$DRY_RUN" -eq 1 ]; then
        say "  ${DIM}fetch${RESET}   ${CYAN}${RPM_URL}${RESET}"
        say "  ${DIM}deploy${RESET}  ${CYAN}sudo dnf install -y ${RPM_URL}${RESET}"
        ok "Simulation complete."
        exit 0
    fi
    sudo dnf install -y "$RPM_URL"
    ok "Installed oojq RPM package."
    oojq --version
    exit 0
fi

# --- Arch Linux / PKGBUILD Installation ---
if [ "$INSTALL_ARCH" -eq 1 ]; then
    step "Installing oojq via PKGBUILD (${VERSION_PIN})"
    if [ "$DRY_RUN" -eq 1 ]; then
        say "  ${DIM}fetch${RESET}   ${CYAN}${CANONICAL_URL}/PKGBUILD${RESET}"
        say "  ${DIM}deploy${RESET}  ${CYAN}makepkg -si --noconfirm${RESET}"
        ok "Simulation complete."
        exit 0
    fi
    if ! command -v makepkg >/dev/null 2>&1; then
        err "makepkg not found. Install base-devel on Arch Linux or install the standalone binary."
        exit 1
    fi
    BUILD_DIR="$(mktemp -d /tmp/oojq-pkgbuild.XXXXXX)"
    if [ -f "./packaging/PKGBUILD" ]; then
        cp "./packaging/PKGBUILD" "$BUILD_DIR/PKGBUILD"
    elif [ -f "./packaging/arch/PKGBUILD" ]; then
        cp "./packaging/arch/PKGBUILD" "$BUILD_DIR/PKGBUILD"
    else
        curl -fsSL "${CANONICAL_URL}/PKGBUILD" -o "$BUILD_DIR/PKGBUILD" 2>/dev/null || \
        curl -fsSL "${GITHUB_URL}/raw/main/packaging/PKGBUILD" -o "$BUILD_DIR/PKGBUILD"
    fi
    (cd "$BUILD_DIR" && makepkg -si --noconfirm)
    rm -rf "$BUILD_DIR"
    ok "Installed oojq via PKGBUILD."
    oojq --version
    exit 0
fi

# --- Phase 1: Identity & Attunement -------------------------------------------
step "[1/4]  Attuning host & kernel substrate"

OS="$(uname -s)"
if [ "$OS" != "Linux" ]; then
    warn "Non-Linux kernel detected: ${BOLD}${OS}${RESET}"
    story_line "oojq is architected for native Linux. Continuing best-effort…"
fi

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|amd64) TARGET_ARCH="x86_64" ;;
    aarch64|arm64) TARGET_ARCH="aarch64" ;;
    *)
        err "Unsupported hardware architecture: $ARCH (oojq requires x86_64 or aarch64)"
        exit 1
        ;;
esac

OS_PRETTY="Linux"
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_PRETTY="${PRETTY_NAME:-Linux}"
fi

say "  ${DIM}os${RESET}       ${GREEN}${OS_PRETTY}${RESET}"
say "  ${DIM}arch${RESET}     ${GREEN}${TARGET_ARCH}${RESET} ${DIM}(${ARCH})${RESET}"
say "  ${DIM}kernel${RESET}   ${GREEN}$(uname -r)${RESET}"

if ! command -v curl >/dev/null 2>&1; then
    err "curl is required to retrieve sovereign release assets"
    exit 1
fi

HASH_CMD=""
if command -v sha256sum >/dev/null 2>&1; then
    HASH_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
    HASH_CMD="shasum -a 256"
fi

if [ -z "$HASH_CMD" ]; then
    warn "No sha256 utility on PATH; cryptographic verification disabled."
else
    say "  ${DIM}crypto${RESET}   ${GREEN}${HASH_CMD}${RESET}"
fi

# Resolve destination directory
if [ -n "$CUSTOM_PREFIX" ]; then
    INSTALL_DIR="$CUSTOM_PREFIX"
elif [ "$(id -u)" -eq 0 ]; then
    INSTALL_DIR="/usr/local/bin"
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    INSTALL_DIR="/usr/local/bin"
else
    INSTALL_DIR="${HOME}/.local/bin"
fi
say "  ${DIM}target${RESET}   ${CYAN}${INSTALL_DIR}/oojq${RESET}"
pause 0.3

# --- Phase 2: Resolving Release & Provenance ----------------------------------
step "[2/4]  Scrying release channels & provenance"

story_line "Contacting sovereign registry at ${GITHUB_URL}…"
LATEST_TAG=$(curl -sSL -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null | grep '"tag_name":' | head -1 | cut -d '"' -f 4 || echo "")
if [ -z "$LATEST_TAG" ]; then
    LATEST_TAG="$VERSION_PIN"
fi

ASSET_NAME="oojq-linux-${TARGET_ARCH}"
ASSET_URL="${GITHUB_URL}/releases/download/${LATEST_TAG}/${ASSET_NAME}"
SHA_URL="${GITHUB_URL}/releases/download/${LATEST_TAG}/${ASSET_NAME}.sha256"

ok "Channel:  ${BOLD}${LATEST_TAG}${RESET} ${DIM}(canonical release)${RESET}"
ok "Artifact: ${BOLD}${ASSET_NAME}${RESET}"
pause 0.2

if [ "$DRY_RUN" -eq 1 ]; then
    step "[DRY RUN] Verification Plan"
    say "  ${DIM}fetch${RESET}   ${CYAN}${ASSET_URL}${RESET}"
    say "  ${DIM}verify${RESET}  ${CYAN}${SHA_URL}${RESET}"
    say "  ${DIM}deploy${RESET}  ${CYAN}${INSTALL_DIR}/oojq${RESET}"
    say ""
    ok "Simulation complete. No host modifications made."
    say ""
    exit 0
fi

# --- Phase 3: Transmission & Cryptographic Seal -------------------------------
step "[3/4]  Transmuting & verifying cryptographic seal"

TMP_DIR="$(mktemp -d /tmp/oojq-bootstrap.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

story_line "Streaming standalone binary artifact from release channel…"
curl -fsSL "$ASSET_URL" -o "${TMP_DIR}/${ASSET_NAME}" &
spin_while $! "Streaming ${ASSET_NAME}"
ok "Transmitted ${ASSET_NAME}"

story_line "Acquiring publisher's cryptographic SHA-256 seal…"
curl -fsSL "$SHA_URL" -o "${TMP_DIR}/${ASSET_NAME}.sha256" 2>/dev/null || true

if [ -f "${TMP_DIR}/${ASSET_NAME}.sha256" ] && [ -n "$HASH_CMD" ]; then
    EXPECTED_SHA=$(awk '{print $1}' "${TMP_DIR}/${ASSET_NAME}.sha256" | head -1)
    ACTUAL_SHA=$($HASH_CMD "${TMP_DIR}/${ASSET_NAME}" | awk '{print $1}')
    if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
        err "Cryptographic seal violation! Download corrupted or tampered."
        say "  ${DIM}Expected:${RESET} ${YELLOW}${EXPECTED_SHA}${RESET}"
        say "  ${DIM}Actual:  ${RESET} ${YELLOW}${ACTUAL_SHA}${RESET}"
        exit 1
    fi
    ok "Cryptographic seal verified: ${DIM}${ACTUAL_SHA}${RESET}"
else
    warn "Checksum manifest unavailable; skipped seal verification."
fi
pause 0.3

if [ "$DO_VERIFY" -eq 1 ]; then
    if [ ! -f "${TMP_DIR}/${ASSET_NAME}.sha256" ] || [ -z "$HASH_CMD" ]; then
        err "Verification failed: Checksum manifest or hash utility unavailable."
        exit 1
    fi
    ok "Cryptographic verification succeeded. Exiting per --verify."
    say ""
    exit 0
fi

# --- Phase 4: Deploying oojq --------------------------------------------------
step "[4/4]  Awakening sovereign JSON tool"

if [ ! -d "$INSTALL_DIR" ]; then
    mkdir -p "$INSTALL_DIR" 2>/dev/null || sudo mkdir -p "$INSTALL_DIR"
fi

chmod +x "${TMP_DIR}/${ASSET_NAME}"

story_line "Placing binary into ${INSTALL_DIR}…"
if [ -w "$INSTALL_DIR" ]; then
    mv "${TMP_DIR}/${ASSET_NAME}" "${INSTALL_DIR}/oojq"
else
    sudo mv "${TMP_DIR}/${ASSET_NAME}" "${INSTALL_DIR}/oojq"
fi
ok "Binary situated at ${BOLD}${INSTALL_DIR}/oojq${RESET}"

story_line "Equipping clean uninstaller at ${INSTALL_DIR}/oojq-uninstall…"
cat << 'EOF_UNINSTALL' > "${TMP_DIR}/oojq-uninstall"
#!/bin/sh
# oojq Clean Uninstaller
set -eu

DRY_RUN=0

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help)
            echo "Usage: oojq-uninstall [--dry-run]"
            echo "Cleanly removes oojq binaries, package manager registrations, and caches."
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 1
            ;;
    esac
done

if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
    CYAN="\033[38;5;51m"
    GREEN="\033[38;5;82m"
    YELLOW="\033[38;5;220m"
    DIM="\033[38;5;242m"
    BOLD="\033[1m"
    RESET="\033[0m"
else
    CYAN="" GREEN="" YELLOW="" DIM="" BOLD="" RESET=""
fi

say()  { printf '%b\n' "$*"; }
ok()   { say "  ${GREEN}✔${RESET} $*"; }
warn() { say "  ${YELLOW}!${RESET} $*"; }
step() { say ""; say " ${CYAN}${BOLD}$*${RESET}"; }

step "Relinquishing oojq"

# Check packages
if command -v dpkg >/dev/null 2>&1 && dpkg -s oojq >/dev/null 2>&1; then
    if [ "$DRY_RUN" -eq 1 ]; then
        say "  ${DIM}[dry-run] Would remove oojq Debian package${RESET}"
    else
        sudo apt-get remove -y oojq 2>/dev/null || sudo dpkg -r oojq 2>/dev/null || true
        ok "Removed oojq Debian package"
    fi
elif command -v rpm >/dev/null 2>&1 && rpm -q oojq >/dev/null 2>&1; then
    if [ "$DRY_RUN" -eq 1 ]; then
        say "  ${DIM}[dry-run] Would remove oojq RPM package${RESET}"
    else
        sudo dnf remove -y oojq 2>/dev/null || sudo rpm -e oojq 2>/dev/null || true
        ok "Removed oojq RPM package"
    fi
elif command -v pacman >/dev/null 2>&1 && pacman -Q oojq >/dev/null 2>&1; then
    if [ "$DRY_RUN" -eq 1 ]; then
        say "  ${DIM}[dry-run] Would remove oojq Arch package${RESET}"
    else
        sudo pacman -R --noconfirm oojq 2>/dev/null || true
        ok "Removed oojq Arch package"
    fi
elif command -v pacman >/dev/null 2>&1 && pacman -Q oojq-bin >/dev/null 2>&1; then
    if [ "$DRY_RUN" -eq 1 ]; then
        say "  ${DIM}[dry-run] Would remove oojq-bin Arch package${RESET}"
    else
        sudo pacman -R --noconfirm oojq-bin 2>/dev/null || true
        ok "Removed oojq Arch package"
    fi
fi

# Remove binaries
FOUND=0
for p in /usr/local/bin/oojq "${HOME}/.local/bin/oojq" "${HOME}/.openooda/bin/oojq" /usr/bin/oojq; do
    if [ -f "$p" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            say "  ${DIM}[dry-run] Would remove $p${RESET}"
        else
            rm -f "$p" 2>/dev/null || sudo rm -f "$p" 2>/dev/null || true
            ok "Banished ${BOLD}$p${RESET}"
        fi
        FOUND=1
    fi
done

# Clean caches & runtime files
for c in "${HOME}/.cache/oojq" "${HOME}/.config/oojq"; do
    if [ -d "$c" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            say "  ${DIM}[dry-run] Would remove cache directory $c${RESET}"
        else
            rm -rf "$c" 2>/dev/null || sudo rm -rf "$c" 2>/dev/null || true
            ok "Cleaned $c"
        fi
    fi
done

if [ "$FOUND" -eq 0 ]; then
    warn "No oojq binary found in standard paths."
fi

# Self-removal
THIS="$0"
case "$THIS" in
    /*) SELF="$THIS" ;;
    *)  SELF="$(pwd)/$THIS" ;;
esac

if [ "$DRY_RUN" -eq 1 ]; then
    say "  ${DIM}[dry-run] Would remove uninstaller $SELF${RESET}"
    say ""
    ok "Simulation complete. No host modifications made."
    exit 0
fi

for u in "$SELF" /usr/local/bin/oojq-uninstall "${HOME}/.local/bin/oojq-uninstall" "${HOME}/.openooda/bin/oojq-uninstall" /usr/bin/oojq-uninstall; do
    if [ -f "$u" ]; then
        rm -f "$u" 2>/dev/null || sudo rm -f "$u" 2>/dev/null || true
    fi
done

say ""
ok "oojq and all related components cleanly uninstalled."
EOF_UNINSTALL
chmod +x "${TMP_DIR}/oojq-uninstall"
if [ -w "$INSTALL_DIR" ]; then
    mv "${TMP_DIR}/oojq-uninstall" "${INSTALL_DIR}/oojq-uninstall"
else
    sudo mv "${TMP_DIR}/oojq-uninstall" "${INSTALL_DIR}/oojq-uninstall"
fi
ok "Clean uninstaller situated at ${BOLD}${INSTALL_DIR}/oojq-uninstall${RESET}"

if "${INSTALL_DIR}/oojq" --version >/dev/null 2>&1; then
    VER_PROVE=$("${INSTALL_DIR}/oojq" --version)
    ok "Living proof: ${GREEN}${BOLD}${VER_PROVE}${RESET}"
else
    warn "Verification probe non-responsive."
fi

# PATH Inspection
case ":$PATH:" in
    *":${INSTALL_DIR}:"*) ;;
    *)
        warn "${INSTALL_DIR} is not currently in your \$PATH."
        say "  ${DIM}Append to your shell profile (~/.bashrc, ~/.zshrc):${RESET}"
        say "  ${CYAN}export PATH=\"${INSTALL_DIR}:\$PATH\"${RESET}"
        ;;
esac

victory_banner
say "  ${BOLD}Ready for transmission:${RESET}"
say "    oojq . package.json"
say "    oojq -c '.items[] | {id, name}' data.json"
say "    oojq --mcp"
say ""
say "  ${BOLD}Clean uninstaller:${RESET}"
say "    ${INSTALL_DIR}/oojq-uninstall"
say "    ${DIM}or:${RESET} curl -fsSL ${CANONICAL_URL}/install.sh | bash -s -- --uninstall"
say ""
say "  ${DIM}Canonical portal:${RESET} ${CANONICAL_URL}"
say "  ${DIM}Source registry:${RESET}  ${GITHUB_URL}"
say ""

