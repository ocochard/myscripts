# Pull requests on ron-dev.freebsd.org with git-pr

ron-dev.freebsd.org is a test Forgejo instance for the FreeBSD project. It
mirrors the official `src`, `ports` and `doc` repositories and accepts pull
requests through the AGit workflow. It is not the final instance: data on
it can disappear.

## Account setup

- Log in with your Kerberos username. The password cannot be changed from
  the web UI; use the usual FreeBSD password tools.
- Add your SSH public key (Settings, SSH / GPG Keys): pushes go over SSH.
- Enable MFA after the first login; it may become mandatory.
- You cannot create repositories (ask gitadm). Issues stay in Bugzilla.
- External contributors cannot use the instance yet: they need
  [forgejo#11965](https://codeberg.org/forgejo/forgejo/pulls/11965) in a
  Forgejo release in the ports tree.

## How AGit works

You push your branch to a magic ref of the shared repository, and the
server turns the push into a pull request:

```
git push review HEAD:refs/for/main/mytopic
```

`main` is the target branch, `mytopic` names the pull request; pushing
again to the same topic updates it. The server creates no branch: it
stores the commits under `refs/pull/<N>/head`. Push options
(`-o title=...`, `-o description=...`, `-o force-push=true`) carry the
metadata. `git-pr` wraps all this. Details:
<https://forgejo.org/docs/latest/user/agit-support/>.

| | Fork (GitHub) | Shared repository | AGit |
|---|---|---|---|
| Copy of the repository on the server | one per contributor | no | no |
| Branch created on the server | yes, in the fork | yes, with ref ACLs | no |
| Access needed | write on the fork | write on the main repository | read only |
| Create the pull request | push, then web UI | push, then web UI | one push (`git pr main`) |
| Update it | push to the branch | push to the branch | push to the same topic |

What the server receives, and when:

- Nothing until you run `git pr` (or `git push`). Commits, other branches
  and uncommitted changes stay local.
- `git pr` sends the commits of `HEAD` not yet on the server (in practice
  the branch since `main`) and the topic, which is the branch name. A
  branch named `main/mytopic` gives the topic `mytopic`; `-o <topic>`
  picks another.
- Everything pushed is public and stays under `refs/pull/<N>/head` even
  after the pull request closes. Check `git log review/main..HEAD` first.
- Never run `git pr` from `main`: the topic would be `main`, and every
  later `git pr` from `main` would update that same pull request.

## Install git-pr

```
pkg install freebsd-git-pr
```

(or the port `devel/freebsd-git-pr`). It installs `git-pr` and git-pr(1),
and needs git, curl and jq (the last two only for `--status`, `--list`,
`--merge`). The copy at <http://people.freebsd.org/~bapt/git-pr> named in
the announcement is older; remove any such copy so `which -a git-pr`
shows only the package.

## Configure a repository

Two remotes: `freebsd`, the official repository where commits land (the
Committer's Guide name), and `review`, the Forgejo mirror.

```
cd ~/freebsd-official/src
git remote add freebsd https://git.FreeBSD.org/src.git
git remote set-url --push freebsd git@gitrepo.freebsd.org:src.git
git remote add review git@ron-dev.freebsd.org:FreeBSD/src.git
git config --add remote.review.fetch "+refs/pull/*/head:refs/remotes/review/pr/*"
git config pr.remote review
git fetch freebsd
git fetch review
cp tools/tools/git/hooks/prepare-commit-msg .git/hooks/
```

Skip the `freebsd` lines if that remote exists. The fetch line maps every
pull request head to `review/pr/<N>`; add it once (`--add` twice
duplicates it, check with `git config --get-all remote.review.fetch`).
The hook lists the commit tags as comments in the editor. With
`pr.remote` set, `git pr main` is enough (otherwise `git pr review main`).
For ports use `FreeBSD/ports.git`.

Check without pushing:

```
git ls-remote freebsd refs/heads/main                           # anonymous fetch
git ls-remote git@gitrepo.freebsd.org:src.git refs/heads/main   # SSH key on gitrepo
git ls-remote review refs/heads/main                            # SSH key on ron-dev
```

The three hashes match when the mirror is in sync.

`--status`, `--list` and `--merge` use the Forgejo API. On the public
repositories they work without a token (tested 2026-11-01). If that
changes, create a token with read access (Settings, Applications) and
store it with `git config --global forgejo.token <token>` (or set
`FORGEJO_TOKEN`; the git config wins).

## Open a pull request

```
git fetch review
git switch -c mydevbranch review/main
# work, commit
git pr main
```

Fetch first: `git switch` does not contact the server. `git pr` opens an
editor: the first line is the title (default: subject of the last
commit), the text after the first blank line the description (default:
body of the last commit), and the commented lines list the commits being
sent. To skip the editor: `git pr main -t "title" -d "description"`. Dry
run: `git pr main -n`.

## Update a pull request

```
git pr main          # new commits on the same branch
git pr main -f       # after a rebase, amend or squash
```

- A push updates the commits only. The title and description stay as
  they were at creation (checked 2026-11-22 on #112, #113 and #114):
  edit them in the web UI.
- To see what the next push changes, compare with the pushed version
  (`git fetch review` first):

  ```
  git range-diff review/pr/112~2..review/pr/112 \
      pr/amdiommu-irte~2..pr/amdiommu-irte         # per commit, messages too
  git diff review/pr/112 pr/amdiommu-irte          # code only, same base
  ```

  `~2` is the number of commits in the pull request. `range-diff`
  compares the commits as patches, so it works after a rebase onto a
  newer `main` (`=` marks an unchanged commit, `!` a changed one).
  `git diff` compares whole trees: use it only when both versions have
  the same base, or it also shows every upstream change in between.

## Find and review pull requests

```
git pr --status                     # pull request of the current branch
git pr --list                       # all open pull requests
git switch --detach review/pr/3     # check out pull request #3
```

`--status` matches the branch name, so it survives a rebase.

## Merge rule: never merge on Forgejo

Forgejo is a mirror; the official repository stays git.freebsd.org. Never
use the merge button. Push the commits to the official repository:
Forgejo marks the pull request merged when the same hashes reach the
mirror. If you change the commits, update the pull request first
(`git pr main -f`), then push those exact commits.

## Commit to FreeBSD after the review

1. Rebase on the latest official `main` (linear history, no merges), and
   add the tags to each commit:

   ```
   git fetch freebsd
   git switch mydevbranch
   git rebase -i freebsd/main      # mark each commit "reword"
   ```

   ```
   Reviewed by:	reviewer1, reviewer2
   Pull Request:	https://ron-dev.freebsd.org/FreeBSD/src/pulls/3
   ```

   Put a tab after each colon. `Reviewed by:` names those who reviewed
   and are fine with the change. `Pull Request:` is what `main` uses for
   ron pull requests (about 100 commits, 2025-08 to 2026-11);
   `Differential Revision:` is for Phabricator.

   When every commit gets the same tags, skip the editor (tested
   2026-11-22; type the tabs with Ctrl-V Tab):

   ```
   git rebase --exec 'm=$(git log -1 --format=%B); printf "%s\n%s\n%s\n" "$m" \
     "Reviewed by:	kib" \
     "Pull Request:	https://ron-dev.freebsd.org/FreeBSD/src/pulls/112" \
     | git commit -q --amend -F -' freebsd/main
   ```

   To change only the messages and keep the reviewed base, rebase onto
   `$(git merge-base HEAD freebsd/main)` instead of `freebsd/main`.

2. Build and test the final commits: the rebase can break them.

3. Update the pull request: `git pr main -f`.

4. Push the same commits: `git push freebsd mydevbranch:main`. If it
   fails because `freebsd/main` moved, go back to step 1 (new hashes, so
   step 3 again).

5. Once the mirror syncs, Forgejo shows the pull request merged:

   ```
   git switch main
   git pull --ff-only freebsd main
   git branch -d mydevbranch
   ```

**Someone else's pull request:** start from `git switch -c pr3
review/pr/3` and run the same steps except step 3. Topics are per user,
so your `git pr` would open a new pull request: ask the author to push
your commits with `git pr main -f`, or close theirs by hand with a link
to the commit.

**`git pr --merge <N>`** fast-forwards your local `main` to pull request
`<N>`, keeping its hashes, so use it only when its commits already carry
all the tags. It does not push, and the `git push review main` it
suggests pushes to the mirror: **do not run it.** It compares with
`review/main`, which can lag, so check `freebsd/main` agrees, then:

```
git pr --merge 3
git push freebsd main
```

## Quick reference

| Task | Command |
|---|---|
| Open or update a pull request | `git pr main` |
| Update after a rebase | `git pr main -f` |
| Dry run | `git pr main -n` |
| What the next push changes | `git range-diff review/pr/N~K..review/pr/N mybranch~K..mybranch` (K commits) |
| Pull request of the current branch | `git pr --status` |
| All open pull requests | `git pr --list` |
| Check out pull request #N | `git switch --detach review/pr/N` |
| Commit after review | `git rebase -i freebsd/main` (reword), `git pr main -f`, `git push freebsd mydevbranch:main` |
| Commit final pull request #N as is | `git pr --merge N`, then `git push freebsd main` |
