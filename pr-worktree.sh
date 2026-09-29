# pr-worktree — sjekk ut GitHub-PR-er i egne git worktrees.
#
# Installer: legg til i ~/.bashrc eller ~/.zshrc:
#     source /sti/til/pr-worktree.sh
# Krever: git >= 2.31, gh (innlogget), fzf (kun for interaktivt valg).
# Kjør `pr help` for bruk.

_pr_err() { echo "pr: $*" >&2; }

# Roten til hovedrepoet (første worktree). Samme svar fra roten, en undermappe eller en
# annen worktree, og riktig også for submoduler og --separate-git-dir.
_pr_root() {
    git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p' | grep .
}

# Katalogen PR-worktrees legges i. Relative stier regnes fra repo-roten.
_pr_wt_dir() {
    local root dir
    root=$(_pr_root) || return 1
    dir=$(git config --type=path --get pr.worktreedir)
    if [[ -z $dir ]]; then
        if [[ -d $root/worktrees ]]; then dir=worktrees
        elif [[ -d $root/../worktrees ]]; then dir=../worktrees
        else dir=..
        fi
    fi
    [[ $dir == /* ]] || dir="$root/$dir"
    echo "${dir%/}"
}

# Stier til alle PR-worktrees (basename er pr-N eller <repo>-pr-N), én per linje.
_pr_worktrees() {
    git worktree list --porcelain | sed -n 's/^worktree //p' | grep -E '(/|-)pr-[0-9]+$'
}

# Godtar 123, #123 og PR-URL-er (også .../pull/123/files og ...#issuecomment-1).
_pr_num() {
    local n=${1#\#}
    n=${n#*/pull/}
    n=${n%%[/#?]*}
    [[ $n =~ ^[0-9]+$ ]] || { _pr_err "Ugyldig PR: $1"; return 1; }
    echo "$n"
}

_pr_find() { _pr_worktrees | grep -E "(/|-)pr-$1\$" | head -n 1; }

# Worktree der en branch allerede er sjekket ut (tom hvis ingen).
_pr_branch_wt() {
    git worktree list --porcelain |
        awk -v b="branch refs/heads/$1" '/^worktree /{w=substr($0,10)} $0==b{print w; exit}'
}

_pr_need() { command -v "$1" >/dev/null || { _pr_err "$1 er ikke installert."; return 1; }; }

_pr_checkout() {
    local num wt dir
    _pr_need gh || return 1
    if [[ -n $1 ]]; then
        num=$(_pr_num "$1") || return 1
    else
        _pr_need fzf || { _pr_err "Oppgi PR-nummer: pr <nummer>"; return 1; }
        num=$(gh pr list --limit 200 |
            fzf --prompt="Velg PR > " --preview 'gh pr view {1}' | cut -f1)
        [[ -n $num ]] || { _pr_err "Ingen PR valgt."; return 1; }
    fi

    wt=$(_pr_find "$num")
    # Branchen kan være sjekket ut i en worktree som ikke heter *-pr-N.
    [[ -n $wt ]] || wt=$(_pr_branch_wt "$(gh pr view "$num" --json headRefName -q .headRefName 2>/dev/null)")
    if [[ -n $wt ]]; then
        echo "PR #$num har allerede worktree: $wt"
        cd "$wt" || return 1
        return
    fi

    dir=$(_pr_wt_dir) || return 1
    wt="$dir/$(basename "$(_pr_root)")-pr-$num"
    mkdir -p "$dir" || return 1
    echo "Oppretter worktree i $wt..."
    git worktree add --detach "$wt" || return 1
    cd "$wt" || return 1
    if ! gh pr checkout "$num"; then
        _pr_err "gh pr checkout feilet (er branchen sjekket ut et annet sted?)."
        _pr_err "Worktreen står igjen i detached HEAD. Fjern med: pr clean $num"
        return 1
    fi
}

_pr_clean() {
    local force='' merged='' wt num branch root state
    local -a targets=()
    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--force) force=1 ;;
            --merged) merged=1 ;;
            *)
                num=$(_pr_num "$1") || return 1
                wt=$(_pr_find "$num")
                if [[ -n $wt ]]; then targets+=("$wt"); else _pr_err "Ingen worktree for PR #$num"; fi
                ;;
        esac
        shift
    done

    if [[ -n $merged ]]; then
        _pr_need gh || return 1
        while IFS= read -r wt; do
            num=${wt##*pr-}
            state=$(gh pr view "$num" --json state -q .state 2>/dev/null)
            [[ $state == MERGED || $state == CLOSED ]] && targets+=("$wt")
        done < <(_pr_worktrees)
    elif [[ ${#targets[@]} -eq 0 ]]; then
        [[ -n $(_pr_worktrees) ]] || { echo "Ingen PR-worktrees funnet."; return 0; }
        _pr_need fzf || { _pr_err "Oppgi PR-nummer: pr clean <nummer>"; return 1; }
        while IFS= read -r wt; do targets+=("$wt"); done < <(
            _pr_worktrees | fzf -m --prompt="Slett worktree (Tab = flervalg) > ")
    fi
    [[ ${#targets[@]} -gt 0 ]] || { echo "Ingenting å rydde."; return 0; }

    root=$(_pr_root) || return 1
    local here del=-d
    here=$(pwd -P)
    [[ -n $force ]] && del=-D
    for wt in "${targets[@]}"; do
        # Ikke bli stående i en katalog som slettes.
        [[ $here == "$wt" || $here == "$wt"/* ]] && { cd "$root" || return 1; }
        branch=$(git -C "$wt" branch --show-current 2>/dev/null)
        if ! git -C "$root" worktree remove ${force:+--force} "$wt"; then
            _pr_err "Beholdt $wt (ulagrede endringer? bruk --force)"
            continue
        fi
        echo "Fjernet $wt"
        [[ -n $branch ]] || continue
        # -d nekter hvis branchen har commits som ikke er pushet; -D med --force.
        if git -C "$root" branch "$del" "$branch" >/dev/null 2>&1; then
            echo "Slettet branch $branch"
        else
            _pr_err "Beholdt branch $branch (ikke pushet? bruk --force)"
        fi
    done
    git -C "$root" worktree prune
}

_pr_config() {
    local scope=--local
    [[ $1 == --global ]] && { scope=--global; shift; }
    if [[ -z $1 ]]; then
        echo "Worktree-katalog: $(_pr_wt_dir)"
        return
    fi
    git config "$scope" pr.worktreedir "$1" && echo "pr.worktreedir ($scope) = $1 -> $(_pr_wt_dir)"
}

_pr_help() {
    cat <<'EOF'
Bruk: pr [kommando] [argumenter]

  pr                         Velg PR med fzf og sjekk den ut i en worktree
  pr <nr|#nr|url>            Sjekk ut PR (eller hopp til eksisterende worktree)
  pr co|checkout [nr]        Samme som over
  pr ls|list                 List PR-worktrees
  pr rm|clean [nr...]        Slett worktree(s) + lokal branch (fzf-flervalg uten nr)
       --merged              ... alle worktrees der PR-en er merget/lukket
       -f, --force           ... selv med ulagrede endringer / upushede commits
  pr config [--global] [sti] Vis eller sett worktree-katalog (relativ til repo-roten)
  pr help                    Denne teksten
EOF
}

pr() {
    case $1 in help|-h|--help) _pr_help; return ;; esac
    git rev-parse --git-dir >/dev/null 2>&1 || { _pr_err "Ikke i et git-repo."; return 1; }
    local cmd=$1
    [[ $# -gt 0 ]] && shift
    case $cmd in
        ""|co|checkout) _pr_checkout "$@" ;;
        [0-9]*|\#*|http*) _pr_checkout "$cmd" ;;
        ls|list) git worktree list | grep -E '(/|-)pr-[0-9]+ ' || echo "Ingen PR-worktrees." ;;
        rm|clean) _pr_clean "$@" ;;
        config) _pr_config "$@" ;;
        *) _pr_err "Ukjent kommando: $cmd. Se 'pr help'."; return 1 ;;
    esac
}

# Tab-completion
if [[ -n ${ZSH_VERSION-} ]]; then
    # shellcheck disable=SC2154  # $words kommer fra zsh sin completion
    _pr_zsh() {
        if (( CURRENT == 2 )); then compadd co checkout ls list rm clean config help
        elif [[ ${words[2]} == rm || ${words[2]} == clean ]]; then compadd -- --force --merged
        fi
    }
    if whence compdef >/dev/null; then compdef _pr_zsh pr; fi
else
    _pr_bash() {
        local cur=${COMP_WORDS[COMP_CWORD]} w=""
        if (( COMP_CWORD == 1 )); then w="co checkout ls list rm clean config help"
        elif [[ ${COMP_WORDS[1]} == rm || ${COMP_WORDS[1]} == clean ]]; then w="--force --merged"
        fi
        # shellcheck disable=SC2207
        COMPREPLY=( $(compgen -W "$w" -- "$cur") )
    }
    complete -F _pr_bash pr
fi
