#!/bin/bash
# Shared variables and setup functions — sourced by run.sh, deploy.sh, validate.sh
# Must be run from the project root (directory containing nanoc.yaml)

current_dir="$(pwd)"
default_ruby_version="3.4.7"
ruby_version=""

# Colours
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
WHITE='\033[0;37m'
UNDERLINE='\033[4;37m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

FAIL="${RED} [FAIL]${NC}"
WARN="${YELLOW} [WARNING]${NC}"
PASS="${GREEN} [OK]${NC}"

trap 'status=$?; [[ $status -ne 0 ]] && echo "exiting $0 with status code $status"' EXIT

function sha256_file() {
    # Cross-platform SHA256: Linux uses sha256sum, macOS uses shasum -a 256
    local file="$1"
    if command -v sha256sum &>/dev/null; then
        sha256sum "$file"
    else
        shasum -a 256 "$file"
    fi
}

function get_ruby_version() {
    # Read ruby version from .ruby-version (if present); fall back to default
    ruby_version="$default_ruby_version"
    if [[ -f "$current_dir/.ruby-version" ]]; then
        ruby_version=$(<"$current_dir/.ruby-version")
        ruby_version="${ruby_version//$'\r'/}"
        ruby_version="$(echo -n "$ruby_version" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        if [[ -z "$ruby_version" ]]; then
            ruby_version="$default_ruby_version"
        fi
        echo -e "${PASS} Using ruby version: ${ruby_version}"
    else
        echo -e "${WARN} .ruby-version file not found, using default ruby version: ${ruby_version}"
    fi
}

function sudo_cmd(){
    # Sets SUDO to "sudo" when needed/available, or "" when already root
    # (e.g. inside a container) or when sudo isn't installed at all.
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        SUDO=""
    elif command -v sudo &> /dev/null; then
        SUDO="sudo"
    else
        SUDO=""
    fi
}

function detect_pkg_manager(){
    # Sets PKG_MANAGER to brew (darwin), apt, dnf, pacman, zypper, or unknown
    if [[ "$OSTYPE" == "darwin"* ]]; then
        PKG_MANAGER="brew"
    elif command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt"
    elif command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
    elif command -v pacman &> /dev/null; then
        PKG_MANAGER="pacman"
    elif command -v zypper &> /dev/null; then
        PKG_MANAGER="zypper"
    else
        PKG_MANAGER="unknown"
    fi
}

function pkg_install(){
    # Usage: pkg_install <apt_pkg> <dnf_pkg> <pacman_pkg> <zypper_pkg> <brew_pkg>
    local apt_pkg="$1" dnf_pkg="$2" pacman_pkg="$3" zypper_pkg="$4" brew_pkg="$5"
    [[ -z "${PKG_MANAGER:-}" ]] && detect_pkg_manager
    [[ -z "${SUDO+x}" ]] && sudo_cmd
    case "$PKG_MANAGER" in
        apt)
            ${SUDO} apt-get update -qq && ${SUDO} apt-get install -y "$apt_pkg"
            ;;
        dnf)
            ${SUDO} dnf install -y "$dnf_pkg"
            ;;
        pacman)
            ${SUDO} pacman -Sy --noconfirm "$pacman_pkg"
            ;;
        zypper)
            ${SUDO} zypper install -y "$zypper_pkg"
            ;;
        brew)
            brew install "$brew_pkg"
            ;;
        *)
            echo -e "${FAIL} No supported package manager found — install '${apt_pkg}' manually"
            return 1
            ;;
    esac
}

function port_in_use(){
    # Usage: port_in_use <port> — returns 0 (true) if something is listening
    local port="$1"
    if command -v lsof &> /dev/null; then
        lsof -i :"$port" -sTCP:LISTEN &>/dev/null
    elif command -v ss &> /dev/null; then
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${port}\$"
    else
        (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && { exec 3>&-; return 0; } || return 1
    fi
}

function check_for_build_deps(){
    # Linux-only: native libs ruby-build needs to compile Ruby from source
    [[ "$OSTYPE" == "darwin"* ]] && return 0
    [[ -z "${PKG_MANAGER:-}" ]] && detect_pkg_manager
    [[ -z "${SUDO+x}" ]] && sudo_cmd
    echo -e "${PASS} Installing Ruby build dependencies via ${PKG_MANAGER}..."
    case "$PKG_MANAGER" in
        apt)
            ${SUDO} apt-get update -qq
            ${SUDO} apt-get install -y build-essential libssl-dev libreadline-dev zlib1g-dev libyaml-dev
            ;;
        dnf)
            # Explicit packages rather than `dnf groupinstall "Development
            # Tools"` — newer Fedora ships dnf5, which dropped the
            # groupinstall subcommand syntax entirely (it's `dnf5 group
            # install` now); explicit packages work on both dnf4 and dnf5.
            ${SUDO} dnf install -y gcc gcc-c++ make patch git openssl-devel readline-devel zlib-devel libyaml-devel
            ;;
        pacman)
            ${SUDO} pacman -Sy --noconfirm base-devel openssl readline zlib libyaml
            ;;
        zypper)
            ${SUDO} zypper install -y -t pattern devel_basis
            ${SUDO} zypper install -y libopenssl-devel readline-devel zlib-devel libyaml-devel
            ;;
        *)
            echo -e "${WARN} No supported package manager found — install Ruby build dependencies manually (see https://github.com/rbenv/ruby-build/wiki)"
            ;;
    esac
}

function rbenv_init_path(){
    export PATH="$(rbenv root)/shims:$PATH"
}

function check_os_type(){
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo -e "${PASS} Running on Mac OS system"
        if ! command -v brew &> /dev/null; then
            read -p "Homebrew commandline is not installed. Would you like it installed (Y/n)?" install_brew
            if [ "$install_brew" != "${install_brew#[Yy]}" ]; then
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            else
                echo -e "${FAIL} Exiting Homebrew needs to be installed"
                exit 1
            fi
        else
            echo -e "${PASS} brew is installed"
        fi
    else
        detect_pkg_manager
        if [[ "$PKG_MANAGER" == "unknown" ]]; then
            echo -e "${WARN} Could not detect a supported package manager (apt/dnf/pacman/zypper). You will need to manually install rbenv, awscli and ruby ${ruby_version}"
        else
            echo -e "${PASS} Running on Linux — detected package manager: ${PKG_MANAGER}"
        fi
    fi
}

function check_for_rbenv(){
    if ! command -v rbenv &> /dev/null; then
        read -p "rbenv commandline is not installed. Would you like it installed (Y/n)?" install_rbenv
        if [[ "$install_rbenv" != "${install_rbenv#[Yy]}" ]]; then
            if [[ "$OSTYPE" == "darwin"* ]]; then
                brew install rbenv
            else
                curl -fsSL https://rbenv.org/install.sh | bash
                # The official installer only wires ~/.rbenv/bin into
                # .bash_profile for *future* shells — add it now so the
                # rest of this script (and rbenv_init_path below, which
                # itself shells out to `rbenv root`) can find it.
                export PATH="$HOME/.rbenv/bin:$PATH"
            fi
            rbenv_init_path
            rbenv init - bash > /dev/null 2>&1 || true
        else
            echo -e "${FAIL} Exiting rbenv needs to be installed. Read more at https://rbenv.org/"
            echo -e "${FAIL} Or use command: ${WHITE}curl -fsSL https://rbenv.org/install.sh | bash${NC}"
            exit 2
        fi
    else
        echo -e "${PASS} rbenv is installed"
        rbenv_init_path
    fi
}

function validate_and_install_ruby(){
    # `ruby` may not exist on PATH at all yet (e.g. a fresh Linux box with
    # no system Ruby) — macOS always ships one, which previously masked
    # this. Treat "not found" the same as "wrong version" rather than
    # letting the bare `ruby -v` call crash the script under set -e.
    ruby_value="$(ruby -v 2>/dev/null || true)"
    if [[ "${ruby_value}" == *"${ruby_version}"* ]]; then
        echo -e "${PASS} ruby ${ruby_version} is installed"
    else
        check_for_build_deps
        [[ -d ~/.rbenv/plugins/ruby-build ]] && (cd ~/.rbenv/plugins/ruby-build && git pull)
        rbenv install --skip-existing $ruby_version
        rbenv rehash
    fi
}

function set_up_bundler(){
    rbenv local $ruby_version
    bundle install
}

function check_for_nanoc(){
    if ! command -v nanoc &> /dev/null; then
        echo -e "${FAIL} There has been an error with the install of nanoc"
        exit 3
    else
        echo -e "${PASS} nanoc has been found"
    fi
}

function initiate(){
    if [[ -n "${CI:-}" ]]; then
        echo -e "${PASS} CI environment detected — skipping local setup"
        return 0
    fi
    get_ruby_version
    check_os_type
    check_for_rbenv
    validate_and_install_ruby
    set_up_bundler
    check_for_nanoc
}
