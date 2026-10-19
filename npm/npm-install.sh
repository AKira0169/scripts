#!/usr/bin/env bash
# Run `npm i` in every npm project of the workspace that needs it.
#
# Finds package.json files (with dependencies) inside the nested repos, top-most per
# folder tree only, so library manifests like fe.common/projects/unified/common are skipped.
# A project "needs install" when:
#   - node_modules is missing, or
#   - package.json or package-lock.json is newer than node_modules/.package-lock.json
#     (npm rewrites that file on every install, so a pull that changes deps makes it stale).
#
# Usage:
#   bash scripts/npm/npm-install.sh                 # only where needed
#   bash npm-install.sh --dry-run                   # just list what needs install
#   bash npm-install.sh --all                       # install everywhere
#   bash npm-install.sh --repos fe.core,sso         # filter by repo name
#   (PowerShell-style flags like -DryRun / -All / -Repos also work)

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd -P)
REPOS=()
ALL=0
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d '-')" in
        root)   ROOT=$(cd "$2" && pwd -P) || exit 1; shift ;;
        repos)  REPOS+=("$2"); shift ;;
        all)    ALL=1 ;;
        dryrun) DRY_RUN=1 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_CYAN=$'\033[36m'; C_YELLOW=$'\033[93m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'
    C_GRAY=$'\033[90m'; C_DKYELLOW=$'\033[33m'; C_RESET=$'\033[0m'
fi
say() { local c=$1; shift; printf '%s%s%s\n' "$c" "$*" "$C_RESET"; }

REPO_DIRS=()
for d in "$ROOT"/*/; do
    d=${d%/}
    [ -e "$d/.git" ] && REPO_DIRS+=("$d")
done
FILTERS=($(printf '%s ' "${REPOS[@]}" | tr ',' ' '))
if [ ${#FILTERS[@]} -gt 0 ]; then
    shopt -s nocasematch
    keep=()
    for d in "${REPO_DIRS[@]}"; do
        n=${d##*/}
        for f in "${FILTERS[@]}"; do [[ $n == *"$f"* ]] && { keep+=("$d"); break; }; done
    done
    shopt -u nocasematch
    REPO_DIRS=("${keep[@]}")
fi

# exit 0 if the package.json on stdin declares dependencies or devDependencies
has_deps() {
    node -e "
        let p; try { p = JSON.parse(require('fs').readFileSync(0, 'utf8').replace(/^﻿/, '')); } catch { process.exit(1); }
        process.exit(p.dependencies || p.devDependencies ? 0 : 1);"
}

# ---- discover projects ------------------------------------------------------
PROJECTS=()
for r in "${REPO_DIRS[@]}"; do
    kept=()
    # shortest paths first, so a parent project is kept before anything nested under it
    while IFS= read -r -u 3 dir; do
        nested=0
        for k in "${kept[@]}"; do case "$dir" in "$k"/*) nested=1; break ;; esac; done
        [ $nested -eq 1 ] && continue
        has_deps <"$dir/package.json" || continue
        kept+=("$dir")
    done 3< <(find "$r" -mindepth 1 -maxdepth 4 \
                \( -type d \( -iname node_modules -o -iname dist -o -iname bin -o -iname obj -o -iname .angular -o -iname 'release-*' \) -prune \) \
                -o -type f -name package.json -print 2>/dev/null |
              sed 's#/package\.json$##' | awk '{ print length($0) "\t" $0 }' | sort -n | cut -f2-)
    PROJECTS+=("${kept[@]}")
done

install_reason() {
    local dir=$1 marker="$1/node_modules/.package-lock.json" f
    if [ ! -d "$dir/node_modules" ]; then echo 'no node_modules'; return; fi
    if [ ! -e "$marker" ]; then echo 'no install marker'; return; fi
    for f in package.json package-lock.json; do
        if [ -e "$dir/$f" ] && [ "$dir/$f" -nt "$marker" ]; then echo "$f changed"; return; fi
    done
}

# ---- plan -------------------------------------------------------------------
TODO=(); TODO_LABEL=(); lines=()
for dir in "${PROJECTS[@]}"; do
    reason=$(install_reason "$dir")
    [ $ALL -eq 1 ] && [ -z "$reason" ] && reason='forced (-All)'
    label=${dir#"$ROOT"/}
    if [ -n "$reason" ]; then
        TODO+=("$dir"); TODO_LABEL+=("$label")
        lines+=("$C_YELLOW  [install] $label  ($reason)$C_RESET")
    else
        lines+=("$C_GRAY  [ok]      $label$C_RESET")
    fi
done

say "$C_CYAN" "Found ${#PROJECTS[@]} npm projects, ${#TODO[@]} need install."
for l in "${lines[@]}"; do printf '%s\n' "$l"; done
if [ $DRY_RUN -eq 1 ] || [ ${#TODO[@]} -eq 0 ]; then exit 0; fi

# ---- install ----------------------------------------------------------------
RESULTS=(); failed=0; width=7
for i in "${!TODO[@]}"; do
    dir=${TODO[$i]}; label=${TODO_LABEL[$i]}
    echo; say "$C_CYAN" "=== npm i : $label ==="
    if [ ! -e "$dir/.npmrc" ] && grep -q '@borderguardsunifiedplatform/' "$dir/package.json"; then
        say "$C_DKYELLOW" "  warning: no .npmrc here; @borderguardsunifiedplatform/* needs a GitHub Packages token."
    fi
    (cd "$dir" && npm i --no-fund --no-audit)
    code=$?
    if [ $code -eq 0 ]; then status=OK; say "$C_GREEN" "  -> $status"
    else status="FAILED ($code)"; say "$C_RED" "  -> $status"; failed=1; fi
    RESULTS+=("$status")
    [ ${#label} -gt $width ] && width=${#label}
done

echo; say "$C_CYAN" "===== Summary ====="
printf "%-${width}s  %s\n" Project Result "$(printf '%*s' $width '' | tr ' ' '-')" ------
for i in "${!TODO_LABEL[@]}"; do printf "%-${width}s  %s\n" "${TODO_LABEL[$i]}" "${RESULTS[$i]}"; done
exit $failed
