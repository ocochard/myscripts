# Pull requests on ron-dev.freebsd.org with git-pr

ron-dev.freebsd.org is a test Forgejo instance for the FreeBSD project. It
mirrors the official `src`, `ports` and `doc` repositories and accepts pull
requests through the AGit workflow. The "-dev" in the name matters: this is
not the final instance, and data on it can disappear.

This document covers account setup, the `git-pr` tool, the day-to-day
workflow, and the merge rule that is easy to break.

## Account setup

- Log in with your Kerberos username.
- You cannot change the password from the web UI. Use the usual FreeBSD
  password tools.
- Add your SSH public key in the web UI (Settings, SSH / GPG Keys). Pushes go
  over SSH.
- Enable MFA after the first login. It may become mandatory on the final
  instance.
- You cannot create or migrate repositories. Ask gitadm if you need one.
- Issues stay in Bugzilla. Forgejo issues redirect there.
- External contributors cannot use the instance yet. They need
  [forgejo#11965](https://codeberg.org/forgejo/forgejo/pulls/11965) in a
  Forgejo release in the ports tree.

## How AGit works

A classic fork workflow needs a copy of the repository per contributor. That
is expensive for `src` and `ports`. AGit avoids the copy: you push your
branch to a magic ref on the shared repository, and the server turns the push
into a pull request.

```
git push review HEAD:refs/for/main/mytopic
```

- `main` is the branch the pull request targets.
- `mytopic` names the pull request. Pushing again to the same topic updates
  the same pull request.

Read-only access is enough, so no ref ACLs are needed. Details:
<https://forgejo.org/docs/latest/user/agit-support/>.

`git-pr` wraps this push and adds the title, description and force-push
options for you.

### AGit compared to the usual workflows

In the fork workflow (GitHub, Codeberg), you work in your own copy of the
repository:

1. Fork `FreeBSD/src` on the server. The server stores a second copy of the
   repository, and you own it.
2. Push your branch to the fork: `git push myfork mybranch`. A branch named
   `mybranch` now exists on the server, in the fork.
3. Open the pull request in the web UI, from `myfork:mybranch` to
   `FreeBSD/src:main`.
4. To update, push to the same fork branch again.

In the shared-repository workflow, everyone pushes review branches to the
main repository (`git push origin review/mybranch`). That needs write access
and per-ref ACLs, so that a contributor can create `review/*` but not touch
`main`.

AGit removes both the fork and the review branches:

| | Fork | Shared repository | AGit |
|---|---|---|---|
| Copy of the repository on the server | one per contributor | no | no |
| Branch created on the server | yes, in the fork | yes, in the main repository | no |
| Access needed | write on the fork | write on the main repository, with ref ACLs | read on the main repository |
| Create the pull request | push, then web UI | push, then web UI | one push (`git pr main`) |
| Update the pull request | push to the branch | push to the branch | push to the same topic |

The server intercepts the push to `refs/for/<target>/<topic>`. It does not
create a branch. It stores the commits under `refs/pull/<N>/head` and opens
or updates pull request `<N>`. The push options (`-o title=...`,
`-o description=...`, `-o force-push=true`) carry the metadata that the web
UI would otherwise ask for.

### What stays local

Your local branches stay local. A plain `git commit` sends nothing anywhere.
The server only receives something when you run `git pr` (or `git push`).

When you run `git pr`, the server receives:

- the commits reachable from `HEAD` that are not already on the server, in
  practice every commit of the branch since `main`;
- the topic name, which is the branch name by default. A branch named
  `local-experimental` creates a pull request with the head
  `local-experimental`. Use `-o <topic>` to publish under another name.

Everything you push is public to every user with read access, and it stays
on the server under `refs/pull/<N>/head` even after the pull request closes.
Squash or drop private experiments before you run `git pr`, and check the
commit list in the editor template (or `git log review/main..HEAD`) before
you save.

Other branches are never sent. `git pr` pushes `HEAD` only. Uncommitted
changes in the working tree are never sent.

Never run `git pr` from `main`. The topic is the branch name, so the push
goes to `refs/for/main/main` and every later `git pr` from `main` updates
that same pull request. Create a topic branch first, even for one commit.

## Install git-pr

Install the package:

```
pkg install freebsd-git-pr
```

Or build the port `devel/freebsd-git-pr`. It installs `git-pr` and its
manual page, git-pr(1). Dependencies: git, curl and jq. curl and jq are only
for the API modes (`--status`, `--list`, `--merge`).

The announcement mail points to <http://people.freebsd.org/~bapt/git-pr>.
That copy is older than the port (no `--status`, `--list`, `--merge`, `-o`).
Prefer the package. If an old copy sits in `~/bin`, remove it so that only
one `git-pr` is in `PATH`:

```
which -a git-pr
```

## Configure a repository

You need two remotes:

- `freebsd`: the official repository, where commits land. The Committer's
  Guide uses this name, with anonymous fetch and push to gitrepo.
- `review`: the Forgejo mirror, where pull requests live.

```
cd ~/freebsd-official/src
git remote add freebsd https://git.FreeBSD.org/src.git
git remote set-url --push freebsd git@gitrepo.freebsd.org:src.git
git remote add review git@ron-dev.freebsd.org:FreeBSD/src.git
git config --add remote.review.fetch "+refs/pull/*/head:refs/remotes/review/pr/*"
git fetch freebsd
git fetch review
git config pr.remote review
```

If `freebsd` already exists, skip the two `freebsd` lines. The push URL can
also be written `ssh://git@gitrepo.freebsd.org/src.git`; both forms are in
the Committer's Guide. Other remotes (a GitHub fork as `origin`, for
example) do not matter to `git pr`.

Install the in-tree commit message hook, which pre-fills the trailers
(`Reviewed by:`, `Pull Request:`, ...):

```
cp tools/tools/git/hooks/prepare-commit-msg .git/hooks/
```

Check the setup without pushing anything:

```
git remote -v
git config --get pr.remote                    # review
git ls-remote freebsd refs/heads/main         # anonymous fetch works
git ls-remote git@gitrepo.freebsd.org:src.git refs/heads/main   # SSH key accepted by gitrepo
git ls-remote review refs/heads/main          # SSH key accepted by ron-dev
```

The three hashes are the same when the mirror is in sync.

With `pr.remote` set, `git pr main` is enough. Without it, write
`git pr review main`.

For the ports tree, use `FreeBSD/ports.git`. For the documentation, use the
`doc` repository path shown in the web UI.

### API token

`--status`, `--list` and `--merge` call the Forgejo REST API. On the public
`src` repository they work without a token (tested 2026-11-01). The tool
sends a token when one is configured, which matters if the instance later
requires login or rate-limits anonymous calls. Create one in the web UI
(Settings, Applications) with read access to repositories, then store it:

```
git config --global forgejo.token <token>
```

The `FORGEJO_TOKEN` environment variable also works. The git config value
wins when both are set.

The tool derives the API address from the remote URL:
`git@ron-dev.freebsd.org:FreeBSD/src.git` gives
`https://ron-dev.freebsd.org/api/v1`.

## Open a pull request

```
git switch -c mydevbranch review/main
# work, commit, work, commit
git pr main
```

`git pr` opens your editor with a template:

- The first line is the pull request title. It defaults to the subject of the
  last commit.
- The text after the first blank line is the description.
- Lines starting with `#` are ignored. The template lists the commits between
  `main` and `HEAD` as comments, so you can check what you are about to send.

To skip the editor:

```
git pr main -t "rge: add debugnet support" -d "Tested on RTL8126."
```

To see the push command without running it:

```
git pr main -n
```

The topic is the current branch name. A branch named `main/mytopic` gives
the topic `mytopic`. Use `-o <topic>` to choose another name.

## Update a pull request

Commit on the same branch and run the same command again:

```
git pr main
```

If you rewrote the history (rebase, amend, squash), the push is not a
fast-forward. Add `-f`:

```
git rebase review/main
git pr main -f
```

## Find pull requests

```
git pr --status          # pull requests for the current branch
git pr --list            # every open pull request on the remote
```

`--status` matches on the branch name, not on commit hashes, so it still
finds the pull request after a rebase.

## Review someone else's pull request

The `refs/pull/*` fetch line from the setup section maps every pull request
head to `review/pr/<N>`. Add it once per clone if it is missing (`--add`
twice duplicates the line):

```
git config --get-all remote.review.fetch
git fetch review
git switch --detach review/pr/3     # pull request #3
```

## Merge rule: never merge on Forgejo

Forgejo is a mirror. The official repository stays git.freebsd.org, and the
normal commit workflow must keep working.

- Do not use the merge button in the web UI.
- Push the commits to the official repository. Forgejo marks the pull request
  as merged when the same commits (same hashes) appear in the mirror.
- If you change the commits before you push, the hashes change. Update the
  pull request first, then push those exact commits to the official `main`.
  Otherwise Forgejo never sees the pull request as merged.

## Commit to FreeBSD after the review

Do these steps in order, once the reviewers approve the pull request.

1. Rebase on the latest official `main`. The history must stay linear: no
   merge commits in `main`.

   ```
   git fetch freebsd
   git switch mydevbranch
   git rebase freebsd/main
   ```

2. Edit the commit messages. Add the usual trailers, one set per commit:

   ```
   git rebase -i freebsd/main      # mark each commit "reword"
   ```

   ```
   rge: add debugnet support

   <description>

   Reviewed by:	reviewer1, reviewer2
   Pull Request:	https://ron-dev.freebsd.org/FreeBSD/src/pulls/3
   ```

   `Reviewed by:` lists the logins that approved on Forgejo. The
   `Pull Request:` trailer is the one the Committer's Guide uses for GitHub
   pull requests. No commit in `main` references ron yet, so this use is a
   suggestion, not an established rule. Check with your reviewers.

3. Build and test the final commits. The rebase can break what the reviewers
   saw working.

4. Update the pull request with the final commits:

   ```
   git pr main -f
   ```

5. Push the same commits to the official repository:

   ```
   git push freebsd mydevbranch:main
   ```

   If the push fails because `freebsd/main` moved, go back to step 1. The
   rebase creates new hashes, so step 4 is needed again.

6. Wait for the mirror to sync. Forgejo then shows the pull request as
   merged. Delete the local branch:

   ```
   git switch main
   git pull --ff-only freebsd main
   git branch -d mydevbranch
   ```

### Committing someone else's pull request

The flow is the same, from a local branch on top of the pull request:

```
git fetch review
git switch -c pr3 review/pr/3
```

Then run steps 1 to 6, except step 4. Topics are per user: `git pr --list`
shows heads such as `bapt/libusb-compat`. A `git pr` from you creates a new
pull request under your login instead of updating the author's one. Ask the
author to push your rewritten commits with `git pr main -f`, or skip step 4
and close the pull request by hand with a link to the commit.

### git pr --merge

`git pr --merge <num>` fast-forwards your local base branch to the head of
pull request `<num>`. It refuses to run on a dirty tree, on a closed pull
request, or when the fast-forward is not possible. It does not push.

Use it only when the pull request commits are final, with all trailers
already in the messages, because it keeps the hashes unchanged.

At the end it prints a hint such as `git push review main`. **Do not run
that command.** It pushes to the Forgejo mirror, not to the official
repository. Push to the official remote instead:

```
git pr --merge 3
git push freebsd main
```

`--merge` compares your local `main` with `review/main`. The mirror can lag
behind git.freebsd.org, so run `git fetch freebsd` and check that
`freebsd/main` and `review/main` agree before you push.

## Quick reference

| Task | Command |
|---|---|
| Open or update a pull request | `git pr main` |
| Update after a rebase | `git pr main -f` |
| Dry run | `git pr main -n` |
| Pull request of the current branch | `git pr --status` |
| All open pull requests | `git pr --list` |
| Check out pull request #N | `git switch --detach review/pr/N` |
| Commit after review | rebase, reword, `git pr main -f`, `git push freebsd mydevbranch:main` |
| Commit final pull request #N as is | `git pr --merge N`, then `git push freebsd main` |
