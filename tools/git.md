# git

## Sources
https://docs.freebsd.org/en/articles/committers-guide/#git-primer
https://blog.gitbutler.com/how-git-core-devs-configure-git/

## Definition

### merge

Here is a fork of this other repository that contains some changes.
Now record the changes from the upstream to my fork.

### rebase

Here is a fork of this other repository that contains some changes.
Now remove all my changes, fetch all changes from upstream, then re-apply my changes
on top of this up-to-date fork.

## Diff

Diff from a specific hash:

```
git diff b97a47e94662^!
```

Create a patch from a specific hash:
```
git format-patch b5711fa4a98^!
```

Diff from the last commit:
```
git diff HEAD^ HEAD
```

Between a mann and a feature branch:
```
git diff origin/main origin/feature
```

## Apply git patch

Preserving original author name, and tunning commit if it needs:
```
git am file.patch
git commit --amend
```

## Find data

### date

When was the branch branched ?

```
$ git show --summary `git merge-base working-branch-name main`
commit xxxxxx
Merge: yyyyy
Author: root
Date:   Wed May 24 19:13:34 2023 +0000

    Pull request #????: branch-xxx

    Merge in xxx/yyy from branch-zzz to main

    * commit 'xxxx'
      blah.
```

When was that file detele?

```
git log --all -1 -- path/to/file
```

What version was patched:

```
git -C /usr/src rev-list --count --first-parent HEAD
```
patch?

## Keeping working branch up-to-date with origin

Create a new branch:
```
git checkout -b new-branch
```

hack....

push changes:
```
git push origin -u new-branch
```

But now, need to get new commit from the origin:

```
git switch new-name
git fetch origin
git rebase
```
=> resolve conflict (and commit it!) then git rebase --continue
```
git push
```

## Squash multiples commit in one

Display all last commits to be squashed:
```
git log --pretty=oneline
```

Let’s use an example of 5 last commits here:
```
git rebase -i HEAD~5
```
First text editor that open:
- first line, kept the 'pick' keyword
- all others 4 lines: Replace 'pick' by 's' (squash)
=> save & exit
- Adapt the squashed commit message
=> save & exit

Now push back your rebase:
```
git push origin +branch-name
```

## Revert a rebase

You’ve squashed a wrong commit, so your rebase need to be reverted.

```
git reset --hard origin/branch-name
```

## Revert a commit with no log

To be done on working branch only, not main:
```
git reset --hard last-hash-to-kept
git push -f
```

## Forking FreeBSD port
From git webui: Fork freebsd/freebsd-ports

```
git clone git@github.com:ocochard/freebsd-ports.git
git clone git@github.com:ocochard/freebsd-src.git
cd freebsd-ports
git remote add upstream git@github.com:freebsd/freebsd-ports
```

Therminology:
 - Origin = own fork
 - upstream = FreeBSD official
 - main = name of the main branch (was called 'master' previously)

Keeping fork up-to-date with upstream:
```
git checkout main
git pull --rebase upstream master
```

# Creating a BSDRP branch

From https://git-scm.com/book/en/v2/Git-Branching-Basic-Branching-and-Merging
```
git checkout -b BSDRP
=> hack
git commit
```

# Sending this local-only branch to upstream, need to create it remotely the first time:

```
git push -u origin BSDRP
=> hack
git commit
git push
```

# keeping BSDRP branch with main up-to-date
# Need to start with the main branch, then the BSDRP

```
git checkout main
git pull
git checkout branch-name
git rebase main
git push -f
```
# => Now, local main is up-to-date with upstream
```
git checkout BSDRP
#git rebase main
git pull --rebase upstream/main ?, this one is equivalent to git fetch + git rebase origin/master
git push
```

Or sync WIP branch with the main:
```
git checkout WIP
git rebase master WIP
```
# https://stackoverflow.com/questions/42861353/git-pull-after-git-rebase/42862404

# Cherry pick
```
git remote add motoprogger git@github.com:motoprogger/FreeVRRPd.git
git checkout <branch>
git fetch motoprogger
git cherry-pick <commit-hash>
git push <your-fork-alias>
```

# Taging a new release

```
git tag -a v1.992 -m "Releasing version v1.992"
git push origin v1.992
```

# Branch

## Deleting

Local and remote:
```
git branch -d branch-name
git push origin -d branch-name
```

## Reset all local change and replace with remote

@{u} is shorthand for upstream branch

```
git reset --hard @{u}
```

## Create a branch from a tag

```
git checkout -b newbranch tags/v1.0
```

 Copying file between branch

```
git checkout otherbranch myfile.txt
```

Or:

```
git restore --source otherbranch path/to/myfile.txt
```
