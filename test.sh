#!/usr/bin/env bash
# shellcheck disable=SC2016,SC1091  # eval-strenger og source er med vilje
# Røyktest for pr-worktree.sh mot et temp-repo med falsk `gh`. Kjør: bash test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Falsk gh: `pr checkout N` lager branch feature-N, `pr view N` gir headRefName feature-N
# og sier PR 1 er merget.
mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr checkout") git checkout -q -b "feature-$3" ;;
  "pr view") if [[ $5 == headRefName* ]]; then echo "feature-$3"
             elif [[ $3 == 1 ]]; then echo MERGED; else echo OPEN; fi ;;
esac
EOF
chmod +x "$tmp/bin/gh"

# Falsk tea: git.example.org er innlogget. PR 7 er merget, fra branch feature-7 i samme repo;
# PR 8 er åpen, fra en fork (head main, annen repo_id). PR 9 er AGit (head.ref er refs/pull/9/head).
cat >"$tmp/bin/tea" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "logins list") echo "fj https://git.example.org git.example.org meg true" ;;
  "pr list") printf 'index\ttitle\n7\tSju\n8\tÅtte\n' ;;
  "api -R") case $4 in
      */pulls/7) echo '{"number":7,"state":"closed","merged":true,"head":{"ref":"feature-7","repo_id":1},"base":{"repo_id":1}}' ;;
      */pulls/9) echo '{"number":9,"state":"open","merged":false,"head":{"ref":"refs/pull/9/head","repo_id":1},"base":{"repo_id":1}}' ;;
      */pulls/8) echo '{"number":8,"state":"open","merged":false,"head":{"ref":"main","repo_id":2},"base":{"repo_id":1}}' ;;
      *) echo '{"message":"not found"}' ;;
    esac ;;
esac
EOF
chmod +x "$tmp/bin/tea"
PATH="$tmp/bin:$PATH"

git init -q "$tmp/repo" && cd "$tmp/repo" || exit 1
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir sub
source "$here/pr-worktree.sh"

fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

cd sub && pr 1 >/dev/null
check "pr <nr> fra undermappe havner i ../repo-pr-1" '[[ $PWD == "$tmp/repo-pr-1" ]]'
check "branch sjekket ut" '[[ $(git branch --show-current) == feature-1 ]]'
pr '#2' >/dev/null
check "#2 fra inni en worktree havner ved siden av repoet" '[[ $PWD == "$tmp/repo-pr-2" ]]'
cd "$tmp/repo" && pr https://github.com/o/r/pull/1/files >/dev/null
check "eksisterende worktree gjenbrukes" '[[ $PWD == "$tmp/repo-pr-1" ]]'
check "list viser begge" '[[ $(pr ls | wc -l) -eq 2 ]]'

touch dirty
pr clean 1 2>/dev/null
check "clean nekter ved ulagrede endringer" '[[ -d $tmp/repo-pr-1 ]]'
pr clean --merged --force >/dev/null
check "clean --merged --force fjerner PR 1" '[[ ! -d $tmp/repo-pr-1 ]]'
check "... og står ikke i slettet katalog" '[[ $PWD == "$tmp/repo" ]]'
check "... og sletter branchen" '! git show-ref -q refs/heads/feature-1'
check "PR 2 er urørt" '[[ -d $tmp/repo-pr-2 ]]'
ln -s "$tmp/repo-pr-2" "$tmp/lenke" && cd "$tmp/lenke" && pr clean --force 2 >/dev/null
check "clean via symlink flytter deg ut av worktreen" '[[ -d $PWD && ! -d $tmp/repo-pr-2 ]]'

pr config worktrees >/dev/null && cd sub && pr 3 >/dev/null
check "config er relativ til repo-roten" '[[ $PWD == "$tmp/repo/worktrees/repo-pr-3" ]]'
git worktree add -q -b feature-5 "$tmp/egen" 2>/dev/null && pr 5 >/dev/null
check "branch sjekket ut i annen worktree: hopp dit" '[[ $PWD == "$tmp/egen" && ! -d $tmp/repo/worktrees/repo-pr-5 ]]'
check "ugyldig PR avvises" '! pr abc 2>/dev/null'

# Forgejo: en bare "server" med feature-7 og refs/pull/8/head.
git init -q "$tmp/fjrepo" && cd "$tmp/fjrepo" || exit 1
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git clone -q --bare "$tmp/fjrepo" "$tmp/fj.git"
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m sju
git push -q "$tmp/fj.git" HEAD:refs/heads/feature-7
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m aatte
git push -q "$tmp/fj.git" HEAD:refs/pull/8/head
git clone -q "$tmp/fj.git" "$tmp/fj" && cd "$tmp/fj" || exit 1
git remote set-url origin ssh://git@git.example.org:2222/o/r.git
check "forgejo gjenkjennes fra tea logins" '[[ $(_pr_forge) == forgejo ]]'
git remote set-url origin git@github.com:o/r.git
check "github.com gir github" '[[ $(_pr_forge) == github ]]'
git remote set-url origin "$tmp/fj.git" && git config pr.forge forgejo
check "Forgejo-URL med /pulls/ godtas" '[[ $(_pr_num https://git.example.org/o/r/pulls/7/files) == 7 ]]'
pr 7 >/dev/null 2>&1
check "forgejo: samme-repo-PR gir head-branch med tracking" \
    '[[ $PWD == "$tmp/fj-pr-7" && $(git rev-parse --abbrev-ref @{u}) == origin/feature-7 ]]'
pr 8 >/dev/null 2>&1
check "forgejo: fork-PR hentes fra refs/pull/8/head som pr-8" \
    '[[ $(git branch --show-current) == pr-8 && $(git log -1 --format=%s) == aatte ]]'
check "forgejo: ingen ekstra remotes" '[[ $(git remote) == origin ]]'
pr clean --merged >/dev/null 2>&1
check "forgejo: clean --merged fjerner merget PR 7, beholder 8" '[[ ! -d $tmp/fj-pr-7 && -d $tmp/fj-pr-8 ]]'
check "forgejo: ukjent PR feiler" '! pr 99 2>/dev/null'
cd "$tmp/fj" && pr clean --force 99 >/dev/null 2>&1

cd "$tmp/fjrepo" && git push -q "$tmp/fj.git" HEAD:refs/pull/9/head
cd "$tmp/fj" && pr 9 >/dev/null 2>&1
check "forgejo: AGit-PR hentes fra refs/pull/9/head" '[[ $(git branch --show-current) == pr-9 ]]'
check "forgejo: pr-9 følger refs/pull/9/head (git pull virker)" \
    '[[ $(git config branch.pr-9.merge) == refs/pull/9/head ]] && git pull -q --ff-only'
cd "$tmp/fj" && pr clean 8 >/dev/null 2>&1
check "forgejo: clean sletter fork-branchen pr-8 uten --force" \
    '! git show-ref -q refs/heads/pr-8 && ! git show-ref -q refs/pr-worktree/pull/8'
# Nye commits på serveren: eksisterende lokale branches skal fast-forwardes.
git branch feature-7 origin/feature-7 && git branch pr-8 "$(git -C "$tmp/fj.git" rev-parse refs/pull/8/head)"
cd "$tmp/fjrepo" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m ny &&
    git push -q "$tmp/fj.git" HEAD:refs/heads/feature-7 +HEAD:refs/pull/8/head
cd "$tmp/fj" && pr 7 >/dev/null 2>&1
check "forgejo: eksisterende head-branch fast-forwardes" '[[ $(git log -1 --format=%s) == ny ]]'
cd "$tmp/fj" && pr 8 >/dev/null 2>&1
check "forgejo: eksisterende pr-8 fast-forwardes" '[[ $(git log -1 --format=%s) == ny ]]'

cd /
"$here/install.sh" "$tmp/rc" >/dev/null 2>&1
"$here/install.sh" "$tmp/rc" >/dev/null 2>&1
check "install legger til source-linje én gang" '[[ $(grep -c "source \"$here/pr-worktree.sh\"" "$tmp/rc") -eq 1 ]]'
check "install fra annen katalog peker på repoet" 'bash -c "source $tmp/rc && declare -F pr" >/dev/null'
exit $fail
