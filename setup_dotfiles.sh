#!/bin/bash

# set -o xtrace
set -o pipefail
set -o errexit
set -o nounset

function show_help {
cat << EOF
Usage: ${0##*/} [-nwm] <source> <target>

Setup the dotfiles for a computer.  The system type is detected
automatically.

    -c          publish dotfiles using cp
    -f          force overwrite existing files
    -n          dryrun, don't acutally do anything
    -s          publish dotfiles using symlinks, the default
    -h          display the help
EOF
}

dryrun=false
force=false
copy_items=false
link_items=false

OPTIND=1
while getopts ":nfcsh" opt; do
    case "$opt" in
        n) dryrun=true ;;
        f) force=true ;;
        c) copy_items=true ;;
        s) link_items=true ;;
        h) show_help
           exit
           ;;
        \?) echo "Invalid option: -$OPTARG" >&2
            show_help
            exit 1
            ;;
    esac
done
shift "$((OPTIND - 1))"

if [ "$copy_items"  = "true" ] && [ "$link_items" = "true" ]; then
    printf "Cannot specify both -c (copy) and -s (symlink).  Pick \
 one or the other.\n"
    exit 1
fi

PUBLISH_CMD=''
published=''
if  "$copy_items"; then
    PUBLISH_CMD='cp -r '
    published='copied'
elif "$link_items"; then
    PUBLISH_CMD='ln -s '
    published='linked'
else
    case "$OSTYPE" in
        darwin*)
            PUBLISH_CMD="ln -s"
            published='linked'
            ;;
        msys*)
            PUBLISH_CMD='cp -r '
            published='copied'
            ;;
        \?)
            PUBLISH_CMD="ln -s"
            published='linked'
            ;;
    esac
fi

RESTORE='\033[0m'
RED='\033[00;31m'
GREEN='\033[00;32m'
YELLOW='\033[00;33m'

ok="${GREEN}    ok${RESTORE}"
skip="${GREEN}  skip${RESTORE}"
warn="${YELLOW}  warn${RESTORE}"
error="${RED} error${RESTORE}"

# shellcheck disable=2059
function items_identical {
    local diff_cmd="diff --ignore-all-space \
         --ignore-blank-lines \
         --brief \
         $source $target > /dev/null"

    # diff returns 0 if the folders were identical
    if eval "$diff_cmd"; then
        printf "$skip: $target_pretty is identical to $source_pretty\n"
        return 0
    else
        return 1
    fi
}

# Link or copy item from $source into $target.
#
# By default, link on an Unix-like OS, copy on Windows because it
# doesn't support symbolic links.
function publish_item {
    if [[ $# -ne 2 ]]; then
        echo "publish_item takes 2 arguments" >&2
        return 1
    fi

    if "$dryrun"; then
        echo "dryrun: $PUBLISH_CMD $1 $2"
    elif [[ "$force" && -e "$target" ]]; then
        rm -rf "$target"
        eval "$PUBLISH_CMD $1 $2"
    else
        eval "$PUBLISH_CMD $1 $2"
    fi
}

# shellcheck disable=2059
function publish_file {
    local source="$1"
    local target="$2"
    local source_pretty=${source/"$HOME"/'~'}
    local target_pretty=${target/"$HOME"/'~'}

    if [[ ! -f "$target" ]]; then
        printf "$error: $target_pretty is not a file"
        return 1
    fi

    if items_identical "$source" "$target"; then
        printf "$skip: $source_pretty is identical to $target_pretty\n"
        return 0
    #TODO: elif force
    elif [[ "$force" ]]; then
        publish_item "$source" "$target"
        printf "$ok: $source_pretty overwrote $target_pretty\n"
    else
        printf "$error: $source_pretty is different from $target_pretty\n"
        return 1
    fi
}
# shellcheck disable=2059
function publish_directory() {
    local source="$1"
    local target="$2"
    local source_pretty=${source/"$HOME"/'~'}
    local target_pretty=${target/"$HOME"/'~'}

    if [[ ! -d "$target" ]]; then
        printf "$error: $target_pretty is not a directory"
        return 1
    fi

    local sources=$(find_files_to_publish "$source")
    for file in $sources; do
        publish "$file" "$target/$(basename $file)"
    done

    # Check if target has more files.  If it does,
    # warn that some files exist in target, but not in
    # source
    local files_in_target=$(find_files_to_publish "$target")
    for file in $files_in_target; do
        file=$(basename "$file")
        if [[ ! -e "$source/$file" ]]; then
            printf "$warn: $target_pretty/$file is excess compared to $source_pretty\n"
        fi
    done
}

# shellcheck disable=2059
function publish {
    local source="$1"
    local target="$2"
    local source_pretty=${source/"$HOME"/'~'}
    local target_pretty=${target/"$HOME"/'~'}

    # $target doesn't exist
    if [[ ! -e "$target" ]]; then
        publish_item "$source" "$target"
        printf "$ok: $source_pretty $published to $target_pretty\n"

    # $target already points at $source
    elif [[ -h "$target" ]]; then
        existing_target=$(readlink "$target")
        if [[ "$existing_target" = "$source" ]]; then
            printf "$skip: $source_pretty is already linked by $target_pretty\n"
            return 0
        else
            printf "$error: $target_pretty points to $existing_target_pretty instead of $source_pretty\n"
            return 1
        fi

    elif items_identical "$source" "$target"; then
        printf "$skip: $source_pretty is identical to $target_pretty\n"
        return 0

    elif [[ -d "$source" ]]; then
        publish_directory "$source" "$target"

    elif [[ -f "$source" ]]; then
        publish_file "$source" "$target"

    else
        printf "$error: publishing $source_pretty failed\n"
        return 1
    fi
    return $?
}

# Return all files in a directory except '.'
function find_files_to_publish {
    find "$1" -mindepth 1 -maxdepth 1
}

# shellcheck disable=2059
function publish_dotfiles {
    # First dotfiles
    local dotfiles=$(find_files_to_publish "$HOME/.dotfiles/home")
    for f in $dotfiles; do
        publish "$f" "$HOME/$(basename $f)" || true
   done

    local system_home_dir=''
    case "$OSTYPE" in
        darwin*) system_home_dir="home-mac" ;;
        linux-gnu*) system_home_dir="home-linux" ;;
        msys*) system_home_dir="home-win" ;;
        \?*) printf "$warn: unknown 'OSTYPE', skipping system config\n"
             exit 0
             ;;
    esac

    local system_dotfiles=$(find_files_to_publish "$HOME/.dotfiles/$system_home_dir")
    for f in $system_dotfiles; do
        publish "$f" "$HOME/$(basename $f)" || true
    done
}

if [[ $# -gt 0 ]]; then
    echo "error: $0 doesn't take positional arguments" >&2
    show_help
    exit 1
fi

if "$dryrun"; then
    printf "Executing a dryrun\n"
fi

publish_dotfiles
