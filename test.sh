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
  "pr view") if [[ $5 == headRefName ]]; then echo "feature-$3"
             elif [[ $3 == 1 ]]; then echo MERGED; else echo OPEN; fi ;;
esac
EOF
chmod +x "$tmp/bin/gh"
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

cd /
"$here/install.sh" "$tmp/rc" >/dev/null 2>&1
"$here/install.sh" "$tmp/rc" >/dev/null 2>&1
check "install legger til source-linje én gang" '[[ $(grep -c "source \"$here/pr-worktree.sh\"" "$tmp/rc") -eq 1 ]]'
check "install fra annen katalog peker på repoet" 'bash -c "source $tmp/rc && declare -F pr" >/dev/null'
exit $fail
