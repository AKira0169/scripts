#!/usr/bin/env bash
# Fetch every nested repo in the workspace and fast-forward every local branch to its upstream.
#
# Safe by design: it never merges, rebases, stashes, resets or discards anything.
#   - Fetches all remotes (with --prune and --tags) for every repo, in parallel.
#   - Fast-forwards each local branch that is strictly behind its upstream.
#     * Non-checked-out branches are moved with a guarded update-ref (only if still at the old SHA).
#     * The checked-out branch is updated with `merge --ff-only`, only when the working tree is clean.
#   - Skips and reports branches that are diverged, ahead (unpushed), dirty, or whose upstream is gone.
#   - With --track-all, also creates local tracking branches for remote branches that have no local copy.
#
# Usage:
#   bash scripts/git/pull-all.sh
#   bash pull-all.sh --track-all
#   bash pull-all.sh --repos fe.core,be.eskan
#   bash pull-all.sh --fetch-only --throttle 4
#   (PowerShell-style flags like -TrackAll / -Repos also work)

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd -P)
REPOS=()
TRACK_ALL=0
FETCH_ONLY=0
THROTTLE=6

while [ $# -gt 0 ]; do
    case "$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d '-')" in
        root)      ROOT=$(cd "$2" && pwd -P) || exit 1; shift ;;
        repos)     REPOS+=("$2"); shift ;;
        trackall)  TRACK_ALL=1 ;;
        fetchonly) FETCH_ONLY=1 ;;
        throttle)  THROTTLE=$2; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_CYAN=$'\033[36m'; C_RESET=$'\033[0m'
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

say "$C_CYAN" "Fetching ${#REPO_DIRS[@]} repos (throttle $THROTTLE)..."

# ---- phase 1: parallel fetch ---------------------------------------------
# Each fetch writes its output and exit code to $TMP/<index>.out / .code.
# GIT_TERMINAL_PROMPT=0: a background fetch can't answer a password prompt, so fail instead of hanging.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pull-all.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
for i in "${!REPO_DIRS[@]}"; do
    while [ "$(jobs -rp | wc -l)" -ge "$THROTTLE" ]; do sleep 0.2; done
    (
        GIT_TERMINAL_PROMPT=0 git -C "${REPO_DIRS[$i]}" fetch --all --prune --tags --quiet >"$TMP/$i.out" 2>&1
        echo $? >"$TMP/$i.code"
    ) &
done
wait

# ---- phase 2: fast-forward branches --------------------------------------
n_rows=0; n_upd=0; n_skp=0; n_failed=0
for i in "${!REPO_DIRS[@]}"; do
    dir=${REPO_DIRS[$i]}
    if [ "$dir" = "$ROOT" ]; then name='(umbrella)'; else name=${dir##*/}; fi
    n_rows=$((n_rows + 1))
    updated=(); skipped=(); created=(); ahead=()

    if [ "$(cat "$TMP/$i.code" 2>/dev/null)" = 0 ]; then
        fetch_status=ok
    else
        fetch_status="FAILED: $(tr '\n' ' ' <"$TMP/$i.out" 2>/dev/null)"
        n_failed=$((n_failed + 1))
    fi

    if [ $FETCH_ONLY -eq 1 ] || [ "$fetch_status" != ok ]; then
        printf 'Repo    : %s\nFetch   : %s\nUpdated : \nCreated : \nAhead   : \nSkipped : \n\n' "$name" "$fetch_status"
        continue
    fi

    current=$(git -C "$dir" branch --show-current 2>/dev/null)
    dirty=$(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null)

    # branches checked out in other worktrees must not be moved from here
    wt_branches=$(git -C "$dir" worktree list --porcelain 2>/dev/null | sed -n 's#^branch refs/heads/##p')

    branches=$(git -C "$dir" for-each-ref '--format=%(refname:short)|%(upstream:short)|%(upstream:track)' refs/heads)
    locals=''

    while IFS='|' read -r -u 3 b up track; do
        [ -n "$b" ] || continue
        locals+="$b"$'\n'
        [ -n "$up" ] || continue
        if [ "$track" = '[gone]' ]; then skipped+=("$b(upstream gone)"); continue; fi

        read -r n_ahead n_behind < <(git -C "$dir" rev-list --left-right --count "$b...$up" 2>/dev/null)
        n_ahead=${n_ahead:-0}; n_behind=${n_behind:-0}

        if [ "$n_ahead" -gt 0 ] && [ "$n_behind" -gt 0 ]; then skipped+=("$b(diverged +$n_ahead/-$n_behind)"); continue; fi
        if [ "$n_ahead" -gt 0 ]; then ahead+=("$b(+$n_ahead)"); continue; fi
        [ "$n_behind" -eq 0 ] && continue

        if [ "$b" = "$current" ]; then
            if [ -n "$dirty" ]; then skipped+=("$b(dirty, -$n_behind)"); continue; fi
            git -C "$dir" merge --ff-only --quiet "$up" >/dev/null 2>&1
        elif in_lines "$b" "$wt_branches"; then
            skipped+=("$b(in other worktree)"); continue
        else
            old=$(git -C "$dir" rev-parse "refs/heads/$b")
            new=$(git -C "$dir" rev-parse "$up")
            git -C "$dir" update-ref -m 'git-latest: fast-forward' "refs/heads/$b" "$new" "$old" >/dev/null 2>&1
        fi
        if [ $? -eq 0 ]; then updated+=("$b(-$n_behind)"); else skipped+=("$b(error)"); fi
    done 3<<<"$branches"

    if [ $TRACK_ALL -eq 1 ]; then
        while read -r -u 3 rb; do
            [ -n "$rb" ] || continue
            case "$rb" in */HEAD) continue ;; */*) ;; *) continue ;; esac   # skip HEAD symrefs, need a remote/ prefix
            local_name=${rb#*/}
            in_lines "$local_name" "$locals" && continue
            if git -C "$dir" branch --quiet --track "$local_name" "$rb" >/dev/null 2>&1; then
                created+=("$local_name"); locals+="$local_name"$'\n'
            fi
        done 3< <(git -C "$dir" for-each-ref '--format=%(refname:short)' refs/remotes)
    fi

    if [ ${#created[@]} -gt 5 ]; then created_txt="${#created[@]} branches"; else created_txt=$(join_by ', ' "${created[@]}"); fi
    [ ${#updated[@]} -gt 0 ] && n_upd=$((n_upd + 1))
    [ ${#skipped[@]} -gt 0 ] && n_skp=$((n_skp + 1))
    printf 'Repo    : %s\nFetch   : %s\nUpdated : %s\nCreated : %s\nAhead   : %s\nSkipped : %s\n\n' \
        "$name [$current]" "$fetch_status" "$(join_by ', ' "${updated[@]}")" "$created_txt" \
        "$(join_by ', ' "${ahead[@]}")" "$(join_by ', ' "${skipped[@]}")"
done

# ---- report ---------------------------------------------------------------
say "$C_CYAN" "Summary: $n_rows repos, $n_upd with updates, $n_skp with skipped branches, $n_failed fetch failures"
[ $n_failed -gt 0 ] && exit 2
exit 0
