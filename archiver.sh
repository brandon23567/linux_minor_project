#!/usr/bin/env bash
#==============================================================================
# archiver.sh -- Linux Archive Manager
#------------------------------------------------------------------------------
# Description : A bash script that creates, lists, and extracts .zip archives
#               through an interactive text menu.
# Author      : Student Name (UID: 26MCA22333)
# Course      : Master of Computer Applications (MCA)
# Institution : Chandigarh University, Punjab, India
# Supervisor  : Mr. Ajay Yadav (E13382)
# Version     : 1.0.0
# License     : MIT
#==============================================================================

set -o pipefail
shopt -s extglob

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
ARCHIVER_NAME="Linux Archive Manager"
ARCHIVER_VERSION="1.0.0"

# Colour codes (auto-disabled when stdout is not a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
fi

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log_info()    { printf "${BLUE}[INFO]${NC}  %s\n"  "$*"; }
log_success() { printf "${GREEN}[OK]${NC}    %s\n"  "$*"; }
log_warn()    { printf "${YELLOW}[WARN]${NC}  %s\n"  "$*"; }
log_error()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
log_section() { printf -- "\n${CYAN}${BOLD}--- %s ---${NC}\n" "$*"; }

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
check_dependencies() {
    local missing=()
    local cmd
    for cmd in zip unzip file find du mkdir rm basename dirname realpath; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if (( ${#missing[@]} != 0 )); then
        log_error "Missing required commands: ${missing[*]}"
        log_info  "On Debian/Ubuntu : sudo apt-get install zip unzip file coreutils"
        log_info  "On RHEL/Fedora   : sudo dnf install zip unzip file coreutils"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------
is_valid_file() {
    local f="$1"
    [[ -e "$f" ]] || return 1
    [[ -f "$f" ]] || return 1
    [[ -s "$f" ]] || return 1
    return 0
}

confirm() {
    local prompt="$1" default="${2:-n}" reply
    read -r -p "${prompt} [y/N]: " reply
    reply="${reply:-$default}"
    case "${reply,,}" in
        y|yes) return 0 ;;
        *)     return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Core operation: Create a new ZIP archive
# ---------------------------------------------------------------------------
create_archive() {
    log_section "Create a new ZIP archive"

    # 1. Read archive name
    read -r -p "Enter the output archive name (e.g. backup.zip): " archive_name
    if [[ -z "$archive_name" ]]; then
        log_error "Archive name cannot be empty."
        return 1
    fi

    # 2. Normalise extension to .zip
    case "$archive_name" in
        *.zip) : ;;
        *)     archive_name="${archive_name}.zip" ;;
    esac

    # 3. Overwrite protection
    if [[ -e "$archive_name" ]]; then
        log_warn "File '$archive_name' already exists."
        confirm "Overwrite it?" "n" || { log_info "Aborted by user."; return 1; }
        rm -f -- "$archive_name"
    fi

    # 4. Read source files/dirs
    read -r -p "Enter files/directories to add (space-separated): " -a sources
    if (( ${#sources[@]} == 0 )); then
        log_error "No source files provided."
        return 1
    fi

    # 5. Validate sources
    local valid=() invalid=()
    for s in "${sources[@]}"; do
        if [[ -e "$s" ]]; then
            valid+=("$s")
        else
            invalid+=("$s")
        fi
    done
    (( ${#invalid[@]} != 0 )) && log_warn "Skipped (not found): ${invalid[*]}"
    if (( ${#valid[@]} == 0 )); then
        log_error "No valid source files to archive."
        return 1
    fi

    # 6. Optional encryption
    local zip_args=(-r)
    read -r -p "Encrypt archive with a password? (y/N): " enc
    case "${enc,,}" in
        y|yes)
            local passwd=""
            read -s -p "Enter password: " passwd; echo
            if [[ -z "$passwd" ]]; then
                log_warn "Empty password -- skipping encryption."
            else
                zip_args+=("-P" "$passwd")
            fi
            ;;
    esac

    # 7. Build the archive
    # NOTE: zip does NOT accept the standard `--` end-of-options marker before
    # the archive name ("zip error: Invalid command arguments"). We pass the
    # archive name and validated sources directly. Sources beginning with `-`
    # are out of scope for this mini-project and should be renamed by the user.
    log_info "Creating '$archive_name' with ${#valid[@]} item(s)..."
    local err_log; err_log=$(mktemp)
    if zip "${zip_args[@]}" "$archive_name" "${valid[@]}" >/dev/null 2>"$err_log"; then
        if [[ -s "$archive_name" ]]; then
            local size_human entries
            size_human=$(du -h -- "$archive_name"  | cut -f1)
            entries=$(unzip -l -- "$archive_name" 2>/dev/null | tail -1 | awk '{print $2}')
            log_success "Archive created successfully."
            log_info "Path    : $(realpath -- "$archive_name" 2>/dev/null || echo "$archive_name")"
            log_info "Size    : $size_human"
            log_info "Entries : ${entries:-0}"
            rm -f -- "$err_log"
            return 0
        fi
    fi
    log_error "Archive creation failed."
    [[ -s "$err_log" ]] && log_error "$(cat -- "$err_log")"
    rm -f -- "$err_log"
    return 1
}

# ---------------------------------------------------------------------------
# Core operation: Extract an existing ZIP archive
# ---------------------------------------------------------------------------
extract_archive() {
    log_section "Extract an existing ZIP archive"

    # 1. Read path
    read -r -p "Enter path to the .zip file: " archive_path
    if ! is_valid_file "$archive_path"; then
        log_error "File does not exist or is empty: '$archive_path'"
        return 1
    fi

    # 2. MIME-type sanity check
    local mime
    mime=$(file --mime-type -b -- "$archive_path" 2>/dev/null)
    if [[ "$mime" != *zip* ]]; then
        log_error "Not a valid ZIP file (detected MIME: ${mime:-unknown})."
        return 1
    fi

    # 3. Integrity test (with optional password retry for encrypted archives)
    log_info "Verifying archive integrity..."
    local unzip_pw_args=()
    if ! unzip -tq -- "$archive_path" >/dev/null 2>&1; then
        # Likely an encrypted archive -- prompt for password and retry
        log_warn "Archive appears to be encrypted or integrity check failed."
        read -r -p "Enter password (leave blank to skip): " pw
        if [[ -n "$pw" ]]; then
            unzip_pw_args+=("-P" "$pw")
            if ! unzip -tq "${unzip_pw_args[@]}" -- "$archive_path" >/dev/null 2>&1; then
                log_error "Integrity test failed even with the provided password."
                return 1
            fi
        else
            log_error "Archive integrity test failed. The file may be corrupted or password-protected."
            return 1
        fi
    fi

    # 4. Target directory
    local default_dir
    default_dir="$(basename -- "$archive_path")"
    default_dir="${default_dir%.zip}_extracted"
    read -r -p "Extract to directory [default: $default_dir]: " target_dir
    target_dir="${target_dir:-$default_dir}"

    # 5. Overwrite protection
    if [[ -e "$target_dir" ]]; then
        log_warn "Directory '$target_dir' already exists."
        confirm "Overwrite its contents?" "n" || { log_info "Aborted by user."; return 1; }
        rm -rf -- "$target_dir"
    fi

    # 6. Create target dir
    if ! mkdir -p -- "$target_dir"; then
        log_error "Cannot create target directory '$target_dir'."
        return 1
    fi

    # 7. Extract
    log_info "Extracting '$archive_path' -> '$target_dir'..."
    local err_log; err_log=$(mktemp)
    if unzip -q "${unzip_pw_args[@]}" -- "$archive_path" -d "$target_dir" 2>"$err_log"; then
        local n
        n=$(find -- "$target_dir" -type f 2>/dev/null | wc -l)
        log_success "Extraction complete."
        log_info "Destination : $(realpath -- "$target_dir" 2>/dev/null || echo "$target_dir")"
        log_info "Files       : $n"
        rm -f -- "$err_log"
        return 0
    fi
    log_error "Extraction failed."
    [[ -s "$err_log" ]] && log_error "$(cat -- "$err_log")"
    rm -f -- "$err_log"
    return 1
}

# ---------------------------------------------------------------------------
# Core operation: List the contents of a ZIP archive
# ---------------------------------------------------------------------------
list_archive() {
    log_section "List contents of a ZIP archive"

    read -r -p "Enter path to the .zip file: " archive_path
    if ! is_valid_file "$archive_path"; then
        log_error "File does not exist or is empty: '$archive_path'"
        return 1
    fi

    if ! unzip -l -- "$archive_path" 2>/dev/null; then
        log_error "Failed to list archive. Not a valid ZIP file?"
        return 1
    fi
    echo
    log_success "Listing complete."
    return 0
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
show_menu() {
    echo
    printf -- "${CYAN}${BOLD}==================================================${NC}\n"
    printf -- "${CYAN}${BOLD}  %s v%s${NC}\n" "$ARCHIVER_NAME" "$ARCHIVER_VERSION"
    printf -- "${CYAN}${BOLD}==================================================${NC}\n"
    printf -- "  ${BOLD}1${NC}.  Create a new ZIP archive\n"
    printf -- "  ${BOLD}2${NC}.  Extract a ZIP archive\n"
    printf -- "  ${BOLD}3${NC}.  List contents of a ZIP archive\n"
    printf -- "  ${BOLD}4${NC}.  Exit\n"
    printf -- "${CYAN}${BOLD}--------------------------------------------------${NC}\n"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
    check_dependencies || exit 1

    while true; do
        show_menu
        local choice
        read -r -p "Select an option [1-4]: " choice
        case "$choice" in
            1) create_archive ;;
            2) extract_archive ;;
            3) list_archive ;;
            4) printf -- "${GREEN}Goodbye!${NC}\n"; break ;;
            *) log_error "Invalid option '$choice'. Please choose 1-4." ;;
        esac
        echo
        read -r -p "Press Enter to continue..." _
    done
}

main "$@"
