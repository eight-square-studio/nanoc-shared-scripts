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
        echo -e "${WARN} Sorry, only configured to run on a Mac. You will need to manually install rbenv, awscli and ruby ${ruby_version}"
    fi
}

function check_for_rbenv(){
    if ! command -v rbenv &> /dev/null; then
        read -p "rbenv commandline is not installed. Would you like it installed (Y/n)?" install_rbenv
        if [[ "$install_rbenv" != "${install_rbenv#[Yy]}" && "$OSTYPE" == "darwin"* ]]; then
            brew install rbenv
            rbenv init
        else
            echo -e "${FAIL} Exiting rbenv needs to be installed. Read more at https://rbenv.org/"
            echo -e "${FAIL} Or use command: ${WHITE}curl -fsSL https://rbenv.org/install.sh | bash${NC}"
            exit 2
        fi
    else
        echo -e "${PASS} rbenv is installed"
    fi
}

function validate_and_install_ruby(){
    ruby_value=`ruby -v`
    if [[ "${ruby_value}" == *"${ruby_version}"* ]]; then
        echo -e "${PASS} ruby ${ruby_version} is installed"
    else
        (cd ~/.rbenv/plugins/ruby-build && git pull)
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
