# git

Quick-reference cheat-sheet. Validated against git 2.54.0.

Modern commands (`switch`, `restore`) are preferred over the older `checkout`
for branch/file operations — since git 2.23 they split `checkout`'s two jobs
apart, and git 2.54 updated its own advice messages to point at them.

## Sources
- https://docs.freebsd.org/en/articles/committers-guide/#git-primer
- https://blog.gitbutler.com/how-git-core-devs-configure-git/

---

## 1. The 25 commands you actually need

```
# Get a repo
git clone <url>
git remote add upstream <url>

# Inspect
git status
git log
git diff
git reflog

# Stage + commit
git add <path>            # or  git add .
git commit -m "msg"
git commit -am "msg"      # stage tracked + commit
git commit --amend        # fix last commit

# Sync
git fetch <remote>
git pull --ff-only
git push
git push -u origin <branch>

# Branches
git switch <branch>
git switch -c <branch>    # create + switch
git branch -D <branch>

# Rewrite / integrate
git rebase <base>
git rebase -i HEAD~<N>
git cherry-pick <hash>

# Undo / rescue
git restore <path>            # discard unstaged changes to file
git restore --staged <path>   # unstage
git reset --hard <ref>
git stash / git stash pop / git stash list

# Debug
git bisect
```

Terminology:
- **origin** = your fork (or the repo you cloned)
- **upstream** = the canonical repo you track
- **main** = the primary branch (was `master`)

---

## 2. Merge vs rebase

**merge** — record upstream changes into your fork as a merge commit.
Adds a noisy commit; prefer rebase for personal branches.

**rebase** — reapply your commits on top of an updated base. Linear history.

```
git remote add upstream <url>
git fetch upstream
git switch main
git rebase upstream/main
git switch working
git rebase main
```

---

## 3. Keep a branch in sync with upstream

One canonical recipe — works for any fork (GitHub PR flow, FreeBSD ports,
BSDRP, etc.):

```
git switch main
git pull --rebase upstream main   # fetch + rebase in one step
git push origin main              # update your fork's main

git switch <working-branch>
git rebase main
git push --force-with-lease       # safer than -f: refuses if remote moved
```

Use `--force-with-lease` instead of `-f` — it aborts the push if someone
else pushed in the meantime.

---

## 4. Diff recipes

```
git diff                          # unstaged
git diff --staged                 # staged
git diff HEAD^ HEAD               # last commit
git diff <hash>^!                 # a specific commit
git diff origin/main origin/feat  # between two branches
```

---

## 5. Patches (format-patch / am)

Create:
```
git format-patch HEAD^!           # last commit
git format-patch <hash>^!         # specific commit
git format-patch -N               # last N commits
```

Apply (preserves author + date):
```
git am file.patch
git commit --amend                # only if you need to edit the message
```

---

## 6. Squash last N commits

```
git log --oneline -N              # confirm what you're squashing
git rebase -i HEAD~N
```
In the editor, keep `pick` on the first line, change the rest to `s`
(squash). Save; edit the combined message; save.

```
git push --force-with-lease origin <branch>
```

---

## 7. Undo

Discard unstaged changes in one file:
```
git restore <path>
```

Discard all unstaged changes:
```
git restore .
```

Unstage a file (keep the edits):
```
git restore --staged <path>
```

Undo the last local commit, keep changes staged:
```
git reset --soft HEAD~1
```

Undo the last local commit, discard changes:
```
git reset --hard HEAD~1
```

Reset a local branch to match its upstream (`@{u}` = upstream shorthand):
```
git reset --hard @{u}
```

Revert a bad rebase (still known via reflog):
```
git reflog
git reset --hard HEAD@{N}
```

Force-overwrite a pushed working branch (**never on main**):
```
git reset --hard <good-hash>
git push --force-with-lease
```

---

## 8. Branches

Create a branch from a tag:
```
git switch -c newbranch tags/v1.0
```

Copy one file from another branch into the current one:
```
git restore --source=<other-branch> path/to/file
```

Delete a branch, locally and remotely:
```
git branch -d <branch>            # -D to force
git push origin -d <branch>
```

Tag a release:
```
git tag -a v1.992 -m "Release v1.992"
git push origin v1.992
```

---

## 9. Cherry-pick from another fork

```
git remote add someone <their-url>
git fetch someone
git switch <target-branch>
git cherry-pick <hash>
git push
```

---

## 10. Inspect history

When was a branch created off main?
```
git show --summary "$(git merge-base <branch> main)"
```

When was a file deleted?
```
git log --all -1 -- path/to/file
```

Which patchlevel is /usr/src at?
```
git -C /usr/src rev-list --count --first-parent HEAD
```

---

## 11. Bundle (offline repo transfer)

```
git bundle create repo.bundle --all
git clone repo.bundle <newrepo>
```

---

## 12. Fork a repo (GitHub-style)

Real example — forking both FreeBSD ports and src. Fork each via the
GitHub web UI first, then:

```
# freebsd-ports
git clone git@github.com:<you>/freebsd-ports.git
cd freebsd-ports
git remote add upstream git@github.com:freebsd/freebsd-ports
cd ..

# freebsd-src
git clone git@github.com:<you>/freebsd-src.git
cd freebsd-src
git remote add upstream git@github.com:freebsd/freebsd-src
```

After this, each clone has two remotes:
- `origin`   → your GitHub fork (where `git push` lands)
- `upstream` → the official FreeBSD repo (fetch-only in practice)

Keep either fork current — see section 3.
