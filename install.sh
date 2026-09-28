#!/usr/bin/env bash
# Legger `source <denne katalogen>/pr-worktree.sh` til i shell-rc-fila.
# Bruk: ./install.sh [rc-fil]   (standard: ~/.zshrc for zsh, ellers ~/.bashrc)
set -eu
dir=$(cd "$(dirname "$0")" && pwd)
case ${SHELL-} in
    */zsh) default_rc=${ZDOTDIR:-$HOME}/.zshrc ;;
    *) default_rc=~/.bashrc ;;
esac
rc=${1:-$default_rc}
line="source \"$dir/pr-worktree.sh\""

if grep -qF "$line" "$rc" 2>/dev/null; then
    echo "Allerede installert i $rc"
else
    printf '\n# pr-worktree\n%s\n' "$line" >>"$rc"
    echo "La til i $rc: $line"
fi

for cmd in git gh fzf; do
    command -v "$cmd" >/dev/null || echo "Advarsel: $cmd er ikke installert." >&2
done
echo "Åpne et nytt skall eller kjør: source \"$rc\""
