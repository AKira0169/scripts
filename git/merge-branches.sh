#!/usr/bin/env bash
# Merge a source branch (default: main) into a target branch (default: dev) across
# the UnifiedPlatform repos, after verifying each repo is clean and up to date.
#
# Workspace-wide copy of bg.unified.fe.common/scripts/merge-workspace-branches, kept in
# the umbrella's scripts/git/. It operates on every repo in the workspace root (see NOTES).
#
# main/master: backends use 'master', frontends use 'main'. The two are treated as ONE
# branch: the picker shows "main/master", and each repo merges whichever it has. So
# "main -> uat" merges master -> uat in the backends and main -> uat in the frontends.
# Auto-discovers git repos under the root that actually have BOTH the source and
# target branches (locally or on origin). Repos missing the target branch (e.g.
# bg.unified.fe.common has no 'dev') are listed as ineligible and skipped.
#
# Flow:
#   0. BRANCHES - unless --source AND --target are both given (or --yes), scan every
#                 candidate repo for its branches, keep the "common" ones (present in
#                 2+ repos: normally main/dev/uat), and interactively ask which branch
#                 to merge FROM (source) and INTO (target). Each is shown with a repo
#                 count, e.g. "main (7 repos)". Explicit --source/--target bypass this
#                 and accept ANY branch, including single-repo feature branches.
#   1. SELECT   - interactive checkbox menu (or --repos) to choose which repos to merge.
#   2. PREFLIGHT- git fetch --prune; report each repo's working-tree state and how far
#                 behind origin main/dev are. Repos that are dirty or can't fast-forward
#                 are marked and SKIPPED (they are never force-updated or stashed).
#   3. CONFIRM  - shows the plan; asks to proceed (skip with --yes).
#   4. MERGE    - per clean repo: ff-pull main, ff-pull dev, merge main -> dev.
#                 A conflicting merge is aborted and reported (working tree left clean).
#   5. PUSH     - optional. Off by default; prompts in interactive mode, or force --push.
#   6. SUMMARY  - pass/fail table. The original branch of each repo is restored.
#
# Usage:
#   bash merge-branches.sh                  # interactive: pick source/target, repos, prompt to push
#   bash merge-branches.sh --yes            # all eligible repos, main -> dev, no confirm, no push
#   bash merge-branches.sh --push --yes     # all eligible, merge AND push, no prompts
#   bash merge-branches.sh --repos bg.unified.fe.core,bg.unified.fe.permits
#   bash merge-branches.sh --source main --target uat --push   # explicit branches skip the picker
#   bash merge-branches.sh --fetch-branches # fetch --prune every repo before listing branches
#   bash merge-branches.sh --root /path/to/UnifiedPlatform
#   (PowerShell-style flags like -Source / -Yes / -FetchBranches also work)
#
# NOTES:
#   The workspace root is found dynamically by walking up from this script until a
#   folder holding bg.unified.fe.core (or a *.code-workspace file) is found, so the
#   script's own folder name and depth don't matter. Override with --root <path> or the
#   UNIFIED_ROOT env var if auto-detection guesses wrong. Restores the starting branch
#   of every repo it touches.
#
#   Branch discovery reads each repo's EXISTING refs (local heads + origin/*); it does
#   not fetch unless you pass --fetch-branches, so a brand-new remote branch may not show
#   up until you fetch. The per-repo preflight step still fetches the selected repos.
#
#   Menus: arrows or j/k move, space toggles, enter confirms, q (or esc) cancels.
#   Without a terminal on stdin they fall back to typed numbers.

REPOS=()
SOURCE=main
TARGET=dev
PUSH=0
YES=0
FETCH_BRANCHES=0
ROOT=''
SRC_EXPLICIT=0
TGT_EXPLICIT=0

while [ $# -gt 0 ]; do
    case "$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d '-')" in
        repos)         REPOS+=($(printf '%s' "$2" | tr ',' ' ')); shift ;;
        source)        SOURCE=$2; SRC_EXPLICIT=1; shift ;;
        target)        TARGET=$2; TGT_EXPLICIT=1; shift ;;
        push)          PUSH=1 ;;
        yes)           YES=1 ;;
        fetchbranches) FETCH_BRANCHES=1 ;;
        root)          ROOT=$2; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_CYAN=$'\033[36m'; C_YELLOW=$'\033[93m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'
    C_GRAY=$'\033[90m'; C_LIGHT=$'\033[37m'; C_RESET=$'\033[0m'
fi
say() { local c=$1; shift; printf '%s%s%s\n' "$c" "$*" "$C_RESET"; }

join_by() { local sep=$1 out='' x; shift; for x in "$@"; do out+="${out:+$sep}$x"; done; printf '%s' "$out"; }

# --- locate this script robustly ---------------------------------------------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)
[ -n "$SCRIPT_DIR" ] || SCRIPT_DIR=$(pwd -P)

# A directory is the workspace root if it holds the host repo or a *.code-workspace.
is_workspace_root() {
    local f
    [ -d "$1/bg.unified.fe.core" ] && return 0
    for f in "$1"/*.code-workspace; do [ -f "$f" ] && return 0; done
    return 1
}

# Walk up from the script dir, then the CWD, to find the workspace root.
find_workspace_root() {
    local start d parent
    for start in "$1" "$(pwd -P)"; do
        d=$start
        while [ -n "$d" ]; do
            if is_workspace_root "$d"; then printf '%s' "$d"; return 0; fi
            parent=$(dirname "$d")
            [ "$parent" = "$d" ] && break   # reached filesystem root
            d=$parent
        done
    done
    return 1
}

# --- resolve workspace root (dynamic; folder name/location independent) ------
if [ -n "$ROOT" ]; then
    root=$ROOT
elif [ -n "${UNIFIED_ROOT:-}" ]; then
    root=$UNIFIED_ROOT
else
    root=$(find_workspace_root "$SCRIPT_DIR")
fi
if [ -z "$root" ] || [ ! -d "$root" ]; then
    say "$C_RED" "ERROR: workspace root not found: '$root'"
    say "$C_RED" "  Pass --root <path> or set UNIFIED_ROOT to the folder that holds the repos."
    exit 1
fi
root=$(cd "$root" && pwd -P)   # normalize to an absolute path

# --- git helpers ---------------------------------------------------------------
# Capture output + exit code into GOUT / GCODE; nothing streamed.
git_cap() {
    local dir=$1; shift
    GOUT=$(git -C "$dir" "$@" 2>&1)
    GCODE=$?
    return $GCODE
}

# Run and stream output to the console (for pull/merge/push progress).
git_run() { local dir=$1; shift; git -C "$dir" "$@"; }

# 'local' | 'remote' | '' (uses whatever refs currently exist; refine after fetch)
branch_loc() {
    if git -C "$1" rev-parse --verify --quiet "refs/heads/$2" >/dev/null 2>&1; then echo local
    elif git -C "$1" rev-parse --verify --quiet "refs/remotes/origin/$2" >/dev/null 2>&1; then echo remote
    fi
}

# Backends use 'master', frontends use 'main': treat the two as one branch and print
# whichever this repo actually has. Any other name must exist as-is. Empty = not found.
resolve_repo_branch() {
    local alias=''
    if [ -n "$(branch_loc "$1" "$2")" ]; then echo "$2"; return; fi
    case "$2" in main) alias=master ;; master) alias=main ;; esac
    if [ -n "$alias" ] && [ -n "$(branch_loc "$1" "$alias")" ]; then echo "$alias"; fi
}

# Picker label: show the main/master pair as one entry.
format_branch_name() { if [ "$1" = main ]; then echo 'main/master'; else echo "$1"; fi; }

current_branch() { git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null; }

is_clean() { git_cap "$1" status --porcelain && [ -z "$GOUT" ]; }

# commits that <ref2> has and <ref1> does not (i.e. how far ref1 is BEHIND ref2); -1 on error
count_behind() {
    local n
    n=$(git -C "$1" rev-list --count "$2..$3" 2>/dev/null) || { echo -1; return; }
    echo "$n"
}

# All branch names known to a repo: local heads + origin/* remote-tracking, with the
# 'origin/' prefix stripped, master counted as main, one per line, unique.
repo_branches() {
    git -C "$1" for-each-ref --format='%(refname:short)' refs/heads refs/remotes/origin 2>/dev/null |
        sed -e 's#^origin/##' -e 's#^master$#main#' | grep -vx -e origin -e HEAD | sort -u
}

# --- interactive menus -------------------------------------------------------
# Menus need a terminal for raw key input; otherwise callers use a typed fallback.
can_raw() { [ -t 0 ] && [ -t 1 ]; }

# Esc needs a short timeout to tell it apart from arrow keys; bash 3.2 (macOS) only takes whole seconds.
if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then ESC_WAIT=0.05; else ESC_WAIT=1; fi

# Reads one key into KEY: up | down | enter | space | all | cancel | other
read_key() {
    local k rest=''
    IFS= read -rsn1 k || { KEY=cancel; return; }
    case "$k" in
        $'\033')
            IFS= read -rsn2 -t "$ESC_WAIT" rest
            case "$rest" in '[A'|'OA') KEY=up ;; '[B'|'OB') KEY=down ;; '') KEY=cancel ;; *) KEY=other ;; esac ;;
        ''|$'\r') KEY=enter ;;
        ' ') KEY=space ;;
        k|K) KEY=up ;;
        j|J) KEY=down ;;
        a|A) KEY=all ;;
        q|Q) KEY=cancel ;;
        *) KEY=other ;;
    esac
}

MENU_ACTIVE=0
menu_cleanup() { [ $MENU_ACTIVE -eq 1 ] && printf '\033[?25h'; MENU_ACTIVE=0; }
trap 'menu_cleanup' EXIT
trap 'menu_cleanup; echo; exit 130' INT

term_pad() {
    local w
    w=$(tput cols 2>/dev/null) || w=80
    [ -n "$w" ] || w=80
    w=$((w - 1)); [ $w -lt 20 ] && w=20
    echo $w
}

# draw_line <pad> <color> <text>: clear the row, print text cut to the terminal width
draw_line() { local t=$3; printf '\r\033[2K%s%s%s\n' "$2" "${t:0:$1}" "$C_RESET"; }

# radio_menu <title> <default index> <items...>
# Sets MENU_STATUS = OK (with MENU_INDEX, 0-based) | CANCEL | UNSUPPORTED.
radio_menu() {
    local title=$1 cursor=$2; shift 2
    local items=("$@") count=$# lines i pad first=1
    if [ $count -eq 0 ]; then MENU_STATUS=OK; MENU_INDEX=-1; return; fi
    if ! can_raw; then MENU_STATUS=UNSUPPORTED; return; fi
    [ "$cursor" -ge 0 ] && [ "$cursor" -lt $count ] || cursor=0
    lines=$((count + 2))   # title + hint + items
    pad=$(term_pad)
    MENU_ACTIVE=1; printf '\033[?25l'
    while true; do
        [ $first -eq 1 ] || printf '\033[%dA' $lines
        first=0
        draw_line $pad "$C_CYAN" "$title"
        draw_line $pad "$C_GRAY" "  up/down move   enter select   q/esc cancel"
        for ((i = 0; i < count; i++)); do
            if [ $i -eq $cursor ]; then draw_line $pad "$C_YELLOW" " > (o) ${items[$i]}"
            else draw_line $pad "$C_LIGHT" "   ( ) ${items[$i]}"; fi
        done
        read_key
        case $KEY in
            up)     cursor=$(( (cursor - 1 + count) % count )) ;;
            down)   cursor=$(( (cursor + 1) % count )) ;;
            enter)  MENU_STATUS=OK; MENU_INDEX=$cursor; break ;;
            cancel) MENU_STATUS=CANCEL; break ;;
        esac
    done
    menu_cleanup
}

# checkbox_menu <title> <items...>   (everything preselected)
# Sets MENU_STATUS = OK (with MENU_INDICES, 0-based array) | CANCEL | UNSUPPORTED.
checkbox_menu() {
    local title=$1; shift
    local items=("$@") count=$# lines i n pad cursor=0 first=1 any_off checked=()
    MENU_INDICES=()
    if [ $count -eq 0 ]; then MENU_STATUS=OK; return; fi
    if ! can_raw; then MENU_STATUS=UNSUPPORTED; return; fi
    for ((i = 0; i < count; i++)); do checked[$i]=1; done
    lines=$((count + 3))   # title + hint + items + trailing summary line
    pad=$(term_pad)
    MENU_ACTIVE=1; printf '\033[?25l'
    while true; do
        [ $first -eq 1 ] || printf '\033[%dA' $lines
        first=0
        draw_line $pad "$C_CYAN" "$title"
        draw_line $pad "$C_GRAY" "  up/down move   space toggle   a all/none   enter confirm   q/esc cancel"
        n=0
        for ((i = 0; i < count; i++)); do
            local box='[ ]'; [ ${checked[$i]} -eq 1 ] && { box='[x]'; n=$((n + 1)); }
            if [ $i -eq $cursor ]; then draw_line $pad "$C_YELLOW" " > $box ${items[$i]}"
            else draw_line $pad "$C_LIGHT" "   $box ${items[$i]}"; fi
        done
        draw_line $pad "$C_GRAY" "  $n of $count selected"
        read_key
        case $KEY in
            up)    cursor=$(( (cursor - 1 + count) % count )) ;;
            down)  cursor=$(( (cursor + 1) % count )) ;;
            space) checked[$cursor]=$(( 1 - checked[cursor] )) ;;
            all)
                any_off=0
                for ((i = 0; i < count; i++)); do [ ${checked[$i]} -eq 0 ] && any_off=1; done
                for ((i = 0; i < count; i++)); do checked[$i]=$any_off; done ;;
            enter)
                for ((i = 0; i < count; i++)); do [ ${checked[$i]} -eq 1 ] && MENU_INDICES+=($i); done
                MENU_STATUS=OK; break ;;
            cancel) MENU_STATUS=CANCEL; break ;;
        esac
    done
    menu_cleanup
}

# Typed fallback for a single pick: prints the 0-based index of the choice.
typed_pick() {
    local prompt=$1 max=$2 a
    while true; do
        read -r -p "$prompt " a || exit 1
        if [[ $a =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] && [ "$a" -le "$max" ]; then echo $((a - 1)); return; fi
        say "$C_YELLOW" "  invalid, try again." >&2
    done
}

# --- discover candidate repos ------------------------------------------------
# A candidate is any immediate subfolder of $root that is a git repo.
ALL_REPOS=()
if [ ${#REPOS[@]} -gt 0 ]; then
    # honor an explicit list (validated against $root)
    for r in "${REPOS[@]}"; do
        if [ -d "$r" ]; then ALL_REPOS+=("$(cd "$r" && pwd -P)"); else ALL_REPOS+=("$root/$r"); fi
    done
else
    for d in "$root"/*/; do
        d=${d%/}
        [ -e "$d/.git" ] && ALL_REPOS+=("$d")
    done
fi

# --- choose source/target branches from the "common" set ---------------------
# "Common" = a branch that exists (locally or on origin) in 2+ candidate repos, so
# normally main/dev/uat; per-repo feature branches don't qualify. This picker is
# skipped when --yes is set or when BOTH --source and --target are passed explicitly
# (an explicit branch may be a single-repo one — that still flows through unchanged).
if [ $YES -eq 0 ] && ! { [ $SRC_EXPLICIT -eq 1 ] && [ $TGT_EXPLICIT -eq 1 ]; }; then
    if [ $FETCH_BRANCHES -eq 1 ]; then
        say "$C_GRAY" "Fetching candidate repos for branch discovery ..."
        for d in "${ALL_REPOS[@]}"; do git -C "$d" fetch --prune origin >/dev/null 2>&1; done
    fi

    # "<count> <branch>" for branches in 2+ repos; most-widely-shared first, then alphabetical
    common=$(
        for d in "${ALL_REPOS[@]}"; do [ -e "$d/.git" ] && repo_branches "$d"; done |
            sort | uniq -c | awk '$1 >= 2 { print $1, $2 }' | sort -k1,1nr -k2,2
    )
    names=(); counts=()
    while read -r -u 3 c b; do [ -n "$b" ] && { names+=("$b"); counts+=("$c"); }; done 3<<<"$common"

    if [ ${#names[@]} -lt 2 ]; then
        say "$C_GRAY" "  (fewer than 2 common branches found; using $SOURCE -> $TARGET)"
    else
        branch_label() { local s=s; [ "$2" -eq 1 ] && s=''; echo "$(format_branch_name "$1")  ($2 repo$s)"; }

        labels=(); def=0
        for i in "${!names[@]}"; do
            labels+=("$(branch_label "${names[$i]}" "${counts[$i]}")")
            [ "${names[$i]}" = "$SOURCE" ] && def=$i
        done

        echo
        # --- source ("from") --------------------------------------------------
        radio_menu "Merge FROM  (source branch):" $def "${labels[@]}"
        case $MENU_STATUS in
            CANCEL) say "$C_YELLOW" "Aborted."; exit 0 ;;
            UNSUPPORTED)
                say "$C_CYAN" "Common branches:"
                for i in "${!labels[@]}"; do echo "  [$((i + 1))] ${labels[$i]}"; done
                SOURCE=${names[$(typed_pick "Merge FROM (source) #:" ${#names[@]})]} ;;
            *) SOURCE=${names[$MENU_INDEX]} ;;
        esac

        # --- target ("into") — exclude the chosen source; map back by NAME -----
        tgt_names=(); tgt_labels=(); def=0
        for i in "${!names[@]}"; do
            [ "${names[$i]}" = "$SOURCE" ] && continue
            [ "${names[$i]}" = "$TARGET" ] && def=${#tgt_names[@]}
            tgt_names+=("${names[$i]}"); tgt_labels+=("${labels[$i]}")
        done
        if [ ${#tgt_names[@]} -eq 0 ]; then
            say "$C_YELLOW" "No other common branch to merge into. Aborted."; exit 0
        fi
        echo
        radio_menu "Merge INTO  (target branch), from '$SOURCE':" $def "${tgt_labels[@]}"
        case $MENU_STATUS in
            CANCEL) say "$C_YELLOW" "Aborted."; exit 0 ;;
            UNSUPPORTED)
                for i in "${!tgt_labels[@]}"; do echo "  [$((i + 1))] ${tgt_labels[$i]}"; done
                TARGET=${tgt_names[$(typed_pick "Merge INTO (target) #:" ${#tgt_names[@]})]} ;;
            *) TARGET=${tgt_names[$MENU_INDEX]} ;;
        esac

        say "$C_GREEN" "Merging  $SOURCE  ->  $TARGET"
    fi
fi

# Classify: eligible needs BOTH source and target reachable; else ineligible.
E_NAME=(); E_DIR=(); E_CUR=(); E_SRC=(); E_TGT=()
I_NAME=(); I_REASON=()
for dir in "${ALL_REPOS[@]}"; do
    name=${dir##*/}
    if [ ! -e "$dir/.git" ]; then I_NAME+=("$name"); I_REASON+=('not a git repo'); continue; fi
    src=$(resolve_repo_branch "$dir" "$SOURCE")
    tgt=$(resolve_repo_branch "$dir" "$TARGET")
    if [ -z "$src" ]; then
        I_NAME+=("$name"); I_REASON+=("no '$SOURCE' branch")
    elif [ -z "$tgt" ]; then
        I_NAME+=("$name"); I_REASON+=("no '$TARGET' branch")
    elif [ "$src" = "$tgt" ]; then
        I_NAME+=("$name"); I_REASON+=("source and target are both '$src'")
    else
        E_NAME+=("$name"); E_DIR+=("$dir"); E_CUR+=("$(current_branch "$dir")"); E_SRC+=("$src"); E_TGT+=("$tgt")
    fi
done

echo
say "$C_CYAN" "== Merge $SOURCE -> $TARGET =="
say "$C_GRAY" "  root : $root"

if [ ${#E_NAME[@]} -eq 0 ]; then
    say "$C_RED" "No eligible repos (need both '$SOURCE' and '$TARGET' branches)."
    for i in "${!I_NAME[@]}"; do say "$C_GRAY" "  - ${I_NAME[$i]}: ${I_REASON[$i]}"; done
    exit 1
fi

# --- selection ---------------------------------------------------------------
# Parse things like: "all", "1,3,5", "1-4", "2,4-6" -> 1-based indexes, one per line.
# Returns 1 on an invalid token.
parse_selection() {
    local text=$1 max=$2 t a b i tmp out=''
    if [ -z "${text// /}" ] || [[ $text =~ ^[[:space:]]*(a|all)[[:space:]]*$ ]]; then seq 1 "$max"; return 0; fi
    for t in $(printf '%s' "$text" | tr ',' ' '); do
        if [[ $t =~ ^([0-9]+)-([0-9]+)$ ]]; then
            a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}
            [ "$a" -gt "$b" ] && { tmp=$a; a=$b; b=$tmp; }
            for ((i = a; i <= b; i++)); do [ $i -ge 1 ] && [ $i -le "$max" ] && out+="$i"$'\n'; done
        elif [[ $t =~ ^[0-9]+$ ]]; then
            [ "$t" -ge 1 ] && [ "$t" -le "$max" ] && out+="$t"$'\n'
        else
            return 1   # invalid token
        fi
    done
    printf '%s' "$out" | sort -n -u
}

SEL=()   # selected indexes into E_*
if [ ${#REPOS[@]} -gt 0 ] || [ $YES -eq 1 ]; then
    SEL=("${!E_NAME[@]}")   # explicit list or --yes: take them all (already filtered to eligible)
else
    if [ ${#I_NAME[@]} -gt 0 ]; then
        echo
        say "$C_GRAY" "Ineligible (skipped):"
        for i in "${!I_NAME[@]}"; do say "$C_GRAY" "  - ${I_NAME[$i]}  (${I_REASON[$i]})"; done
    fi

    # Labels for the picker: repo name + the actual branch pair + current branch if not on target.
    labels=()
    for i in "${!E_NAME[@]}"; do
        cur=''
        [ -n "${E_CUR[$i]}" ] && [ "${E_CUR[$i]}" != "${E_TGT[$i]}" ] && cur="  (on ${E_CUR[$i]})"
        labels+=("${E_NAME[$i]}  [${E_SRC[$i]} -> ${E_TGT[$i]}]$cur")
    done

    echo
    checkbox_menu "Select repos to merge  ($SOURCE -> $TARGET):" "${labels[@]}"

    case $MENU_STATUS in
        UNSUPPORTED)
            # No raw key input (piped / non-interactive host) -> typed fallback.
            say "$C_CYAN" "Eligible repos (have '$TARGET'):"
            for i in "${!labels[@]}"; do echo "  [$((i + 1))] ${labels[$i]}"; done
            while [ ${#SEL[@]} -eq 0 ]; do
                echo
                say "$C_CYAN" "Select repos  (e.g. 1 3 5  or  1,3,5  or  1-4  or  all;  blank = all)"
                read -r -p "Selection: " sel || exit 1
                if ! idx=$(parse_selection "$sel" ${#E_NAME[@]}) || [ -z "$idx" ]; then
                    say "$C_YELLOW" "  invalid selection, try again."
                    continue
                fi
                for i in $idx; do SEL+=($((i - 1))); done
            done ;;
        CANCEL)
            say "$C_YELLOW" "Aborted."; exit 0 ;;
        *)
            if [ ${#MENU_INDICES[@]} -eq 0 ]; then say "$C_YELLOW" "No repos selected. Aborted."; exit 0; fi
            SEL=("${MENU_INDICES[@]}")
            picked=(); for i in "${SEL[@]}"; do picked+=("${E_NAME[$i]}"); done
            say "$C_GREEN" "Selected: $(join_by ', ' "${picked[@]}")" ;;
    esac
fi

# --- preflight: fetch + report update state ----------------------------------
echo
say "$C_CYAN" "== Preflight (fetch + status) =="
P_READY=(); P_NOTE=(); ready_names=()
for k in "${!SEL[@]}"; do
    e=${SEL[$k]}
    dir=${E_DIR[$e]}; name=${E_NAME[$e]}; S=${E_SRC[$e]}; T=${E_TGT[$e]}
    echo
    say "$C_CYAN" "--- $name ---"

    if ! git_cap "$dir" fetch --prune origin; then
        say "$C_RED" "  fetch FAILED:"
        say "$C_RED" "  $GOUT"
        P_READY[$k]=0; P_NOTE[$k]='fetch failed'
        continue
    fi

    if is_clean "$dir"; then clean=True; else clean=False; fi
    # behind counts vs origin (how many commits we'd need to pull)
    src_behind=$(count_behind "$dir" "$S" "origin/$S")
    tgt_behind=$(count_behind "$dir" "$T" "origin/$T")
    # would the merge actually bring anything? (source commits not yet in target)
    to_merge=$(count_behind "$dir" "$T" "$S")

    # ff-safe means local branch is an ancestor of its origin (no local-only commits diverging)
    src_ahead=$(count_behind "$dir" "origin/$S" "$S")   # local-only commits on source
    tgt_ahead=$(count_behind "$dir" "origin/$T" "$T")   # local-only commits on target

    reasons=()
    [ $clean = False ]                                     && reasons+=('dirty working tree')
    [ "$src_behind" -gt 0 ] && [ "$src_ahead" -gt 0 ] && reasons+=("$S diverged from origin")
    [ "$tgt_behind" -gt 0 ] && [ "$tgt_ahead" -gt 0 ] && reasons+=("$T diverged from origin")

    echo "  clean: $clean   $S behind origin: $src_behind   $T behind origin: $tgt_behind   to merge: $to_merge"
    if [ ${#reasons[@]} -eq 0 ]; then
        say "$C_GREEN" "  -> READY"
        P_READY[$k]=1; ready_names+=("$name")
    else
        say "$C_YELLOW" "  -> SKIP ($(join_by '; ' "${reasons[@]}"))"
        P_READY[$k]=0
    fi
    P_NOTE[$k]=$(join_by '; ' "${reasons[@]}")
done

if [ ${#ready_names[@]} -eq 0 ]; then
    echo
    say "$C_YELLOW" "Nothing ready to merge (all selected repos were skipped)."
    exit 1
fi

# --- confirm + push decision -------------------------------------------------
DO_PUSH=$PUSH
if [ $YES -eq 0 ]; then
    echo
    say "$C_CYAN" "Plan:"
    echo "  merge  : $SOURCE -> $TARGET"
    echo "  repos  : ${#ready_names[@]} -> $(join_by ', ' "${ready_names[@]}")"
    if [ $PUSH -eq 0 ]; then
        read -r -p "Push each merged '$TARGET' to origin afterwards? [y/N]: " a
        case "$a" in [Yy]*) DO_PUSH=1 ;; *) DO_PUSH=0 ;; esac
    fi
    if [ $DO_PUSH -eq 1 ]; then echo "  push   : yes -> origin/$TARGET"; else echo "  push   : no (local merge only)"; fi
    read -r -p "Proceed? [Y/n]: " a
    case "$a" in [Nn]*) echo "Aborted."; exit 0 ;; esac
fi

# --- merge -------------------------------------------------------------------
# Merges one repo; sets MERGE_STATUS / PUSH_STATUS / NOTE. Returns 1 with NOTE set on error.
merge_repo() {
    local dir=$1 S=$2 T=$3 before after ahead
    # 1) update source to latest (fast-forward only)
    git_run "$dir" checkout "$S" || { NOTE="checkout $S failed"; return 1; }
    if [ "$(count_behind "$dir" "$S" "origin/$S")" -gt 0 ]; then
        say "$C_GRAY" "  pulling $S ..."
        git_run "$dir" pull --ff-only origin "$S" || { NOTE="pull $S failed"; return 1; }
    fi

    # 2) update target to latest (create local tracking branch if needed)
    if [ "$(branch_loc "$dir" "$T")" = local ]; then
        git_run "$dir" checkout "$T" || { NOTE="checkout $T failed"; return 1; }
        if [ "$(count_behind "$dir" "$T" "origin/$T")" -gt 0 ]; then
            say "$C_GRAY" "  pulling $T ..."
            git_run "$dir" pull --ff-only origin "$T" || { NOTE="pull $T failed"; return 1; }
        fi
    else
        git_run "$dir" checkout -b "$T" "origin/$T" || { NOTE="create $T failed"; return 1; }
    fi

    # 3) merge source -> target
    before=$(git -C "$dir" rev-parse HEAD)
    say "$C_GRAY" "  merging $S -> $T ..."
    if ! git_run "$dir" merge --no-edit "$S"; then
        git_cap "$dir" merge --abort   # leave tree clean
        MERGE_STATUS=CONFLICT
        NOTE='merge conflict (aborted)'
        say "$C_RED" "  CONFLICT - merge aborted, no changes kept."
        return 0
    fi
    after=$(git -C "$dir" rev-parse HEAD)
    if [ "$after" = "$before" ]; then
        MERGE_STATUS=UP-TO-DATE
        say "$C_GREEN" "  already up to date."
    else
        MERGE_STATUS=MERGED
        say "$C_GREEN" "  MERGED."
    fi

    # 4) push (optional) - only if target has commits origin doesn't
    if [ $DO_PUSH -eq 1 ]; then
        ahead=$(count_behind "$dir" "origin/$T" "$T")
        if [ "$ahead" -gt 0 ]; then
            say "$C_GRAY" "  pushing $T -> origin ($ahead commit(s)) ..."
            if git_run "$dir" push origin "$T"; then
                PUSH_STATUS=PUSHED; say "$C_GREEN" "  pushed."
            else
                PUSH_STATUS=PUSH-FAILED; say "$C_RED" "  push FAILED."
            fi
        else
            PUSH_STATUS=NOTHING
        fi
    fi
}

R_REPO=(); R_MERGE=(); R_PUSH=(); R_NOTE=()
for k in "${!SEL[@]}"; do
    e=${SEL[$k]}
    dir=${E_DIR[$e]}; name=${E_NAME[$e]}

    if [ "${P_READY[$k]}" != 1 ]; then
        R_REPO+=("$name"); R_MERGE+=(SKIP); R_PUSH+=(-); R_NOTE+=("${P_NOTE[$k]}")
        continue
    fi

    orig=$(current_branch "$dir")
    echo
    say "$C_CYAN" "=== $name ==="
    MERGE_STATUS=PENDING; PUSH_STATUS=-; NOTE=''

    if ! merge_repo "$dir" "${E_SRC[$e]}" "${E_TGT[$e]}"; then
        MERGE_STATUS=ERROR
        say "$C_RED" "  ERROR: $NOTE"
        # best-effort: don't leave a half-done merge in progress
        git_cap "$dir" merge --abort
    fi
    # restore the branch the repo started on
    if [ -n "$orig" ] && [ "$(current_branch "$dir")" != "$orig" ]; then
        git_cap "$dir" checkout "$orig"
    fi

    R_REPO+=("$name"); R_MERGE+=("$MERGE_STATUS"); R_PUSH+=("$PUSH_STATUS"); R_NOTE+=("$NOTE")
done

# --- summary -----------------------------------------------------------------
echo
say "$C_CYAN" "===== Summary ($SOURCE -> $TARGET) ====="
w=4; for r in "${R_REPO[@]}"; do [ ${#r} -gt $w ] && w=${#r}; done
printf "%-${w}s %-10s %-11s %s\n" Repo Merge Push Note
printf "%-${w}s %-10s %-11s %s\n" "$(printf '%*s' $w '' | tr ' ' '-')" ----- ---- ----
bad=0
for i in "${!R_REPO[@]}"; do
    printf "%-${w}s %-10s %-11s %s\n" "${R_REPO[$i]}" "${R_MERGE[$i]}" "${R_PUSH[$i]}" "${R_NOTE[$i]}"
    case "${R_MERGE[$i]}" in CONFLICT|ERROR) bad=1 ;; esac
    [ "${R_PUSH[$i]}" = PUSH-FAILED ] && bad=1
done
exit $bad
