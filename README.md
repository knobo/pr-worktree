# pr-worktree

Review GitHub and Forgejo/Gitea pull requests in their own [git worktrees](https://git-scm.com/docs/git-worktree),
so you never have to stash or switch branches in your main checkout.

```
$ pr            # pick a PR with fzf (preview included), get a worktree and cd into it
$ pr 123        # same, for PR #123 (also accepts #123 or the PR URL)
$ pr ls         # list PR worktrees
$ pr clean      # pick worktrees to delete (Tab for multi-select)
$ pr clean --merged   # remove every worktree whose PR is merged or closed
```

## Installation

Requires `git` >= 2.31 and [`fzf`](https://github.com/junegunn/fzf) for interactive picking
(optional if you always pass a PR number), plus:

- GitHub: [`gh`](https://cli.github.com/), logged in with `gh auth login`
- Forgejo/Gitea: [`tea`](https://gitea.com/gitea/tea), logged in with `tea login add`, and `jq`

Works in bash and zsh.

```sh
git clone https://github.com/knobo/pr-worktree
cd pr-worktree
./install.sh            # or: ./install.sh ~/.some-other-rc
```

`install.sh` adds a `source` line pointing at wherever you cloned the repo to `~/.zshrc`
(if your shell is zsh) or `~/.bashrc`. Running it again does nothing. To update, `git pull`.

`pr` is a shell function rather than a script because it has to `cd` your shell into the worktree.

> **Note:** the function shadows the coreutils `pr` command (the text paginator).
> If you need that one, call `command pr`.

## Commands

| Command | What it does |
|---|---|
| `pr` / `pr co` | Pick an open PR with fzf and check it out in a new worktree |
| `pr <nr\|#nr\|url>` | Check out that PR, or `cd` into its worktree if one exists |
| `pr ls` | List PR worktrees |
| `pr clean [nr...]` | Remove the worktree(s) and their local branch. With no number: pick with fzf |
| `pr clean --merged` | Remove all worktrees whose PR is merged or closed |
| `pr clean -f` | Also remove when there are uncommitted changes or unpushed commits |
| `pr config [--global] [dir]` | Show or set where worktrees go |
| `pr help` | Help |

`clean` is careful by default. It keeps a worktree that has uncommitted changes, and it keeps
a branch that has commits you haven't pushed. Pass `--force` to remove them anyway. If you are
standing inside the worktree being removed, you are moved back to the repo root.

## GitHub or Forgejo

`pr` looks at the host of the remote (`origin`, or the first one): if it is registered in
`tea logins`, it talks to Forgejo/Gitea; otherwise it uses `gh`. Override per repo with
`git config pr.forge forgejo` (or `github`), and pick another remote with `git config pr.remote upstream`.

On Forgejo, a PR from a branch in the same repo is checked out as that branch, tracking the
remote. A PR from a fork is fetched from `refs/pull/<nr>/head` into a local branch `pr-<nr>`.
`pr` does not use `tea pr checkout`, which adds a remote per PR author.

## Where worktrees go

A worktree is named `<repo>-pr-<nr>` and created in the first match of:

1. `git config pr.worktreedir` (set it with `pr config <dir>`, or `pr config --global <dir>` for every repo)
2. `worktrees/` inside the repo, if it exists
3. `../worktrees/`, if it exists
4. `..`, next to the repo

Relative paths are resolved from the root of the main repo, so `pr` behaves the same whether
you run it from the root, a subdirectory, or another worktree.

## Development

```sh
bash test.sh          # smoke test against temp repos with stubbed gh and tea
shellcheck -s bash pr-worktree.sh && shellcheck test.sh install.sh
```

CI runs both of these, plus a zsh load check, on every push and PR.

## License

MIT
