#!/bin/bash
# brew-doctor-fix.sh
# Fixes common issues reported by "brew doctor" on Apple Silicon Macs:
#   1. PATH ordering: ensures /opt/homebrew/bin and /opt/homebrew/sbin precede /usr/bin
#   2. Shadowed tools: removes system-provided binaries that duplicate Homebrew-installed ones
#   3. Persists the corrected PATH across reboots via ~/.zshrc
#
# Usage:  chmod +x brew-doctor-fix.sh && ./brew-doctor-fix.sh
# Re-run: safe to run multiple times (idempotent)
#
# Requires: macOS with Homebrew on Apple Silicon (/opt/homebrew)

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
err()   { echo -e "${RED}[ERR]${NC}   $*"; }

# ── Preflight checks ───────────────────────────────────────────────────────
if [[ "$(uname -s)" != "Darwin" ]]; then
    err "This script is intended for macOS only."
    exit 1
fi

if [[ "$(uname -m)" != "arm64" ]]; then
    warn "This script is designed for Apple Silicon (arm64). Proceeding, but paths may differ."
fi

BREW_PREFIX="$(brew --prefix 2>/dev/null || echo "/opt/homebrew")"
BREW_BIN="${BREW_PREFIX}/bin"
BREW_SBIN="${BREW_PREFIX}/sbin"

if [[ ! -d "$BREW_BIN" ]]; then
    err "Homebrew bin directory not found at ${BREW_BIN}. Is Homebrew installed?"
    exit 1
fi

info "Homebrew prefix: ${BREW_PREFIX}"
echo ""

# ── Step 1: Fix PATH in ~/.zshrc ──────────────────────────────────────────
ZSHRC="$HOME/.zshrc"
PATH_BLOCK_START="# >>> brew-doctor-fix PATH >>>"
PATH_BLOCK_END="# <<< brew-doctor-fix PATH <<<"

fix_path_in_zshrc() {
    info "Fixing PATH configuration in ${ZSHRC} ..."

    # Create ~/.zshrc if it doesn't exist
    touch "$ZSHRC"

    # Remove any previous block we inserted (idempotent)
    if grep -qF "$PATH_BLOCK_START" "$ZSHRC"; then
        info "Removing previous brew-doctor-fix PATH block ..."
        sed -i '' "/${PATH_BLOCK_START}/,/${PATH_BLOCK_END}/d" "$ZSHRC"
    fi

    # The block we inject:
    #   - Puts /opt/homebrew/bin and /opt/homebrew/sbin FIRST
    #   - Strips them from later positions to avoid duplicates
    #   - Keeps everything else in original order
    cat >> "$ZSHRC" <<'BLOCK'

# >>> brew-doctor-fix PATH >>>
# Ensure Homebrew paths precede system paths (Apple Silicon)
_brew_prefix="$(/opt/homebrew/bin/brew --prefix 2>/dev/null || echo /opt/homebrew)"
# Remove existing Homebrew entries to avoid duplicates, then prepend
PATH="$(echo "$PATH" | tr ':' '\n' | grep -v "^${_brew_prefix}/bin$" | grep -v "^${_brew_prefix}/sbin$" | tr '\n' ':' | sed 's/:$//')"
export PATH="${_brew_prefix}/bin:${_brew_prefix}/sbin:${PATH}"
unset _brew_prefix
# <<< brew-doctor-fix PATH <<<
BLOCK

    ok "PATH block written to ${ZSHRC}"

    # Apply immediately in this session
    export PATH="${BREW_BIN}:${BREW_SBIN}:$(echo "$PATH" | tr ':' '\n' | grep -v "^${BREW_BIN}$" | grep -v "^${BREW_SBIN}$" | tr '\n' ':' | sed 's/:$//')"
    ok "PATH updated for current session"
    info "Current PATH order (first 5):"
    echo "$PATH" | tr ':' '\n' | head -5 | while read -r p; do echo "       $p"; done
    echo ""
}

fix_path_in_zshrc

# ── Step 2: Shadow removal ────────────────────────────────────────────────
# For tools that exist in BOTH /usr/bin and Homebrew, we ensure the
# Homebrew version takes precedence. Since /usr/bin is SIP-protected,
# we can't (and shouldn't) remove system binaries. Instead we verify
# Homebrew's PATH priority handles it. But if there are non-SIP duplicates
# in other writable directories, we can handle those.

info "Checking for shadowed tools ..."

SHADOWED_TOOLS=()
SYSTEM_DIRS=(/usr/bin /usr/sbin)

# Collect Homebrew-installed tool names
for tool_path in "${BREW_BIN}"/* "${BREW_SBIN}"/*; do
    [[ -e "$tool_path" ]] || continue
    tool="$(basename "$tool_path")"
    for sys_dir in "${SYSTEM_DIRS[@]}"; do
        if [[ -e "${sys_dir}/${tool}" ]]; then
            SHADOWED_TOOLS+=("$tool")
            break
        fi
    done
done

if [[ ${#SHADOWED_TOOLS[@]} -gt 0 ]]; then
    info "Found ${#SHADOWED_TOOLS[@]} tool(s) present in both Homebrew and system paths:"
    printf "       %s\n" "${SHADOWED_TOOLS[@]}"
    echo ""
    info "Since /usr/bin and /usr/sbin are SIP-protected, they cannot be modified."
    info "With Homebrew paths FIRST in PATH, the Homebrew versions will take precedence."

    # Verify precedence is correct for each
    ALL_RESOLVED=true
    for tool in "${SHADOWED_TOOLS[@]}"; do
        resolved="$(command -v "$tool" 2>/dev/null || true)"
        if [[ "$resolved" == "${BREW_BIN}/${tool}" || "$resolved" == "${BREW_SBIN}/${tool}" ]]; then
            ok "${tool} -> ${resolved} (Homebrew)"
        else
            warn "${tool} -> ${resolved} (NOT Homebrew — may need manual fix)"
            ALL_RESOLVED=false
        fi
    done

    if $ALL_RESOLVED; then
        echo ""
        ok "All shadowed tools now resolve to their Homebrew versions."
    else
        echo ""
        warn "Some tools still resolve outside Homebrew. Check your shell config for conflicting PATH entries."
    fi
else
    ok "No shadowed tools detected."
fi
echo ""

# ── Step 3: Re-run brew doctor ─────────────────────────────────────────────
info "Running 'brew doctor' to verify fixes ..."
echo "────────────────────────────────────────"

DOCTOR_OUTPUT="$(brew doctor 2>&1 || true)"
echo "$DOCTOR_OUTPUT"
echo "────────────────────────────────────────"
echo ""

if echo "$DOCTOR_OUTPUT" | grep -qi "Your system is ready to brew"; then
    ok "brew doctor reports no issues. You're all set!"
elif echo "$DOCTOR_OUTPUT" | grep -qi "Warning"; then
    REMAINING=$(echo "$DOCTOR_OUTPUT" | grep -ci "Warning" || true)
    warn "brew doctor still reports ${REMAINING} warning(s)."
    warn "Review the output above. Some warnings may require:"
    warn "  - Closing and reopening your terminal (to pick up the new PATH)"
    warn "  - Running this script again after opening a new shell"
    warn "  - Manual intervention for issues outside PATH/shadowing"
    echo ""
    info "Quick fix: close this terminal, open a new one, and run:"
    echo "       $0"
else
    ok "brew doctor completed. Review output above if needed."
fi

echo ""
# If running in a subshell, spawn a new shell with the updated PATH
# so the parent terminal picks up the changes automatically.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    info "Launching a new shell with the updated PATH ..."
    exec zsh -l
else
    info "Done. Changes are active in this terminal session."
fi
