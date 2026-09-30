# pr-worktree — sjekk ut GitHub- og Forgejo-PR-er i egne git worktrees.
#
# Installer: legg til i ~/.bashrc eller ~/.zshrc:
#     source /sti/til/pr-worktree.sh
# Krever: git >= 2.31, fzf (kun for interaktivt valg), og for GitHub: gh (innlogget),
# for Forgejo/Gitea: tea (innlogget) og jq.
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

# Godtar 123, #123 og PR-URL-er (også .../pull/123/files, Forgejos .../pulls/123 og
# ...#issuecomment-1).
_pr_num() {
    local n=${1#\#}
    n=${n#*/pulls/}
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

# Remoten PR-ene hentes fra: pr.remote, ellers origin, ellers den første.
_pr_remote() {
    local r
    r=$(git config --get pr.remote) || r=$(git remote | grep -Fx origin) || r=$(git remote | head -n 1)
    [[ -n $r ]] || { _pr_err "Repoet har ingen remote."; return 1; }
    echo "$r"
}

# github eller forgejo. pr.forge overstyrer; ellers forgejo hvis remotens vert er
# registrert i `tea logins`, og github ellers (gh håndterer også GitHub Enterprise).
_pr_forge() {
    local f url host
    f=$(git config --get pr.forge) && { echo "$f"; return; }
    url=$(git remote get-url "$(_pr_remote 2>/dev/null)" 2>/dev/null)
    host=${url#*://}; host=${host#*@}; host=${host%%[:/]*}
    if [[ $host != github.com ]] && command -v tea >/dev/null &&
        tea logins list -o simple 2>/dev/null | awk -v h="$host" '
            { u = $2; sub(/^[a-z]+:\/\//, "", u); sub(/[:\/].*/, "", u) }
            u == h || $3 == h { f = 1 } END { exit !f }'; then
        echo forgejo
    else
        echo github
    fi
}

# Forgejo: PR-en som JSON fra API-et (tom hvis den ikke finnes).
_pr_fj_json() {
    tea api -R "$(_pr_remote)" "repos/{owner}/{repo}/pulls/$1" 2>/dev/null | jq -c 'select(.number)'
}

# Forgejo: head-branchen hvis PR-en er fra samme repo. Tom for forks, og for AGit-PR-er og
# PR-er med slettet head-branch, der head.ref er refs/pull/N/head og ikke en branch.
_pr_fj_ref() {
    jq -r 'select(.head.repo_id == .base.repo_id and (.head.ref | startswith("refs/") | not)).head.ref'
}

# Sjekk at verktøyene for forgen finnes.
_pr_need_forge() {
    case $1 in
        github) _pr_need gh ;;
        forgejo) _pr_need tea && _pr_need jq ;;
        *) _pr_err "Ukjent pr.forge: $1 (bruk github eller forgejo)"; return 1 ;;
    esac
}

# Åpne PR-er, én per linje: nummer<TAB>tittel...
_pr_list() {
    case $1 in
        github) gh pr list --limit 200 ;;
        forgejo) tea pr list -R "$(_pr_remote)" --limit 200 -o tsv -f index,title,author,head |
            tail -n +2 ;;
    esac
}

# Head-branchen til PR-en, men bare når den ligger i samme repo (ikke fork).
_pr_head() {
    case $1 in
        github) gh pr view "$2" --json headRefName,isCrossRepository \
            -q 'select(.isCrossRepository | not).headRefName' 2>/dev/null ;;
        forgejo) _pr_fj_json "$2" | _pr_fj_ref ;;
    esac
}

# OPEN, CLOSED eller MERGED.
_pr_state() {
    case $1 in
        github) gh pr view "$2" --json state -q .state 2>/dev/null ;;
        forgejo) _pr_fj_json "$2" |
            jq -r 'if .merged then "MERGED" else .state | ascii_upcase end' ;;
    esac
}

# Sjekk ut PR-en i gjeldende (detached) worktree.
_pr_fetch() {
    case $1 in
        github) gh pr checkout "$2" ;;
        forgejo)
            # Ikke `tea pr checkout`: den legger til en remote per PR-forfatter og lager
            # branchen pulls/N. Her blir det som gh: head-branchen med tracking, og ellers
            # en lokal pr-N som følger refs/pull/N/head (så `git pull` oppdaterer den).
            # Siste hentede commit lagres i refs/pr-worktree/pull/N, så clean ser at
            # branchen ikke har upushede commits. Ikke under refs/remotes: der ville git
            # tro at den var en branch på serveren.
            local json remote ref branch tip
            json=$(_pr_fj_json "$2")
            [[ -n $json ]] || { _pr_err "Fant ikke PR #$2"; return 1; }
            remote=$(_pr_remote) || return 1
            ref=$(_pr_fj_ref <<<"$json")
            if [[ -n $ref ]]; then
                branch=$ref tip=refs/remotes/$remote/$ref
                git fetch "$remote" "+refs/heads/$ref:$tip" || return 1
            else
                branch=pr-$2 tip=refs/pr-worktree/pull/$2
                git fetch "$remote" "+refs/pull/$2/head:$tip" || return 1
            fi
            if git show-ref -q --verify "refs/heads/$branch"; then
                # Som gh: fast-forward en eksisterende branch, men rør ikke lokale commits.
                git switch "$branch" || return 1
                git merge -q --ff-only "$tip" ||
                    _pr_err "$branch har egne commits og er ikke oppdatert fra PR-en"
            elif [[ -n $ref ]]; then
                git switch -c "$branch" --track "$remote/$ref"
            else
                git switch --no-track -c "$branch" "$tip" &&
                    git config "branch.$branch.remote" "$remote" &&
                    git config "branch.$branch.merge" "refs/pull/$2/head"
            fi
            ;;
    esac
}

_pr_checkout() {
    local num wt dir forge preview
    forge=$(_pr_forge)
    _pr_need_forge "$forge" || return 1
    if [[ -n $1 ]]; then
        num=$(_pr_num "$1") || return 1
    else
        _pr_need fzf || { _pr_err "Oppgi PR-nummer: pr <nummer>"; return 1; }
        preview='gh pr view {1}'
        [[ $forge == forgejo ]] && preview="tea pr -R $(printf %q "$(_pr_remote)") {1} --comments=false"
        num=$(_pr_list "$forge" |
            fzf --prompt="Velg PR > " --preview "$preview" | cut -f1)
        [[ -n $num ]] || { _pr_err "Ingen PR valgt."; return 1; }
    fi

    wt=$(_pr_find "$num")
    # Branchen kan være sjekket ut i en worktree som ikke heter *-pr-N. Ikke for forks:
    # der er head-branchen forkens navn (ofte main) og peker ikke på en lokal branch.
    [[ -n $wt ]] || wt=$(_pr_branch_wt "$(_pr_head "$forge" "$num")")
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
    if ! _pr_fetch "$forge" "$num"; then
        _pr_err "Utsjekk feilet (er branchen sjekket ut et annet sted?)."
        _pr_err "Worktreen står igjen i detached HEAD. Fjern med: pr clean $num"
        return 1
    fi
}

_pr_clean() {
    local force='' merged='' wt num branch root state forge
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
        forge=$(_pr_forge)
        _pr_need_forge "$forge" || return 1
        while IFS= read -r wt; do
            num=${wt##*pr-}
            state=$(_pr_state "$forge" "$num")
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
    local here del=-d d pull
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
        # -d nekter hvis branchen har commits som ikke er pushet; -D med --force. Forgejo-
        # branchen pr-N (fork/AGit) regnes som pushet hvis den er med i refs/pr-worktree/pull/N.
        num=${wt##*pr-} d=$del pull=refs/pr-worktree/pull/$num
        git -C "$root" show-ref -q --verify "$pull" || pull=''
        [[ -n $pull ]] && git -C "$root" merge-base --is-ancestor "$branch" "$pull" && d=-D
        if git -C "$root" branch "$d" "$branch" >/dev/null 2>&1; then
            echo "Slettet branch $branch"
            [[ -n $pull ]] && git -C "$root" update-ref -d "$pull"
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

Forge: GitHub (gh) eller Forgejo/Gitea (tea), valgt ut fra remoten. Overstyr med
`git config pr.forge github|forgejo`, og velg remote med `git config pr.remote <navn>`.
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
