#!/usr/bin/env bash
# Delete local branches whose remote branch no longer exists, in every workspace repo.
#
#   - Runs `fetch --all --prune` first so the "gone" status is current.
#   - Targets only branches that tracked a remote branch which was deleted ([gone]).
#     Branches that were never pushed are listed but never deleted (they may hold unpushed work).
#   - Uses `git branch -d` (refuses unmerged branches). With --force it uses `-D`.
#   - Never deletes the checked-out branch or one checked out in another worktree.
#   - --dry-run only lists what would be deleted.
#
# Usage:
#   bash scripts/git/prune-local.sh --dry-run
#   bash prune-local.sh --force --repos fe.core
#   (PowerShell-style flags like -DryRun / -Force / -Repos also work)

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd -P)
REPOS=()
FORCE=0
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d '-')" in
        root)   ROOT=$(cd "$2" && pwd -P) || exit 1; shift ;;
        repos)  REPOS+=("$2"); shift ;;
        force)  FORCE=1 ;;
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

join_by() { local sep=$1 out='' x; shift; for x in "$@"; do out+="${out:+$sep}$x"; done; printf '%s' "$out"; }

# true if $1 is one of the newline-separated lines in $2
in_lines() { case $'\n'"$2"$'\n' in *$'\n'"$1"$'\n'*) return 0 ;; esac; return 1; }

# ---- discover repos -------------------------------------------------------
REPO_DIRS=()
[ -e "$ROOT/.git" ] && REPO_DIRS+=("$ROOT")
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
if [ ${#REPO_DIRS[@]} -eq 0 ]; then echo "No git repos found under $ROOT"; exit 1; fi

if [ $DRY_RUN -eq 1 ]; then mode='DRY RUN'; elif [ $FORCE -eq 1 ]; then mode='force (-D)'; else mode='safe (-d)'; fi
say "$C_CYAN" "Pruning local branches whose remote is gone in ${#REPO_DIRS[@]} repos [$mode]..."

total_deleted=0; total_kept=0
for dir in "${REPO_DIRS[@]}"; do
    if [ "$dir" = "$ROOT" ]; then name='(umbrella)'; else name=${dir##*/}; fi

    if ! out=$(git -C "$dir" fetch --all --prune --quiet 2>&1); then
        say "$C_RED" "$name : fetch FAILED, skipped. $out"; continue
    fi

    current=$(git -C "$dir" branch --show-current 2>/dev/null)
    wt_branches=$(git -C "$dir" worktree list --porcelain 2>/dev/null | sed -n 's#^branch refs/heads/##p')

    deleted=(); kept=(); never_pushed=()
    while IFS='|' read -r -u 3 b up track; do
        [ -n "$b" ] || continue
        if [ -z "$up" ]; then never_pushed+=("$b"); continue; fi
        [ "$track" = '[gone]' ] || continue
        if [ "$b" = "$current" ] || in_lines "$b" "$wt_branches"; then kept+=("$b(checked out)"); continue; fi
        if [ $DRY_RUN -eq 1 ]; then deleted+=("$b"); continue; fi
        if [ $FORCE -eq 1 ]; then flag=-D; else flag=-d; fi
        if git -C "$dir" branch "$flag" "$b" >/dev/null 2>&1; then deleted+=("$b"); else kept+=("$b(not merged)"); fi
    done 3< <(git -C "$dir" for-each-ref '--format=%(refname:short)|%(upstream:short)|%(upstream:track)' refs/heads)

    if [ ${#deleted[@]} -gt 0 ] || [ ${#kept[@]} -gt 0 ] || [ ${#never_pushed[@]} -gt 0 ]; then
        echo; say "$C_YELLOW" "$name"
        if [ ${#deleted[@]} -gt 0 ]; then
            if [ $DRY_RUN -eq 1 ]; then verb='would delete'; else verb='deleted'; fi
            say "$C_GREEN" "  $verb: $(join_by ', ' "${deleted[@]}")"
        fi
        [ ${#kept[@]} -gt 0 ]         && say "$C_RED"  "  kept: $(join_by ', ' "${kept[@]}")"
        [ ${#never_pushed[@]} -gt 0 ] && say "$C_GRAY" "  never pushed (not touched): $(join_by ', ' "${never_pushed[@]}")"
    fi
    total_deleted=$((total_deleted + ${#deleted[@]})); total_kept=$((total_kept + ${#kept[@]}))
done

if [ $DRY_RUN -eq 1 ]; then verb='would be deleted'; else verb='deleted'; fi
echo; say "$C_CYAN" "Summary: $total_deleted branches $verb, $total_kept kept."
if [ $total_kept -gt 0 ] && [ $FORCE -eq 0 ] && [ $DRY_RUN -eq 0 ]; then
    say "$C_DKYELLOW" "'not merged' branches were kept to protect unmerged commits (common after squash-merge). Use prune:force to delete them anyway."
fi
