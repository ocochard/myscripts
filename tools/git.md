# git

## Sources
https://docs.freebsd.org/en/articles/committers-guide/#git-primer

## Diff

Diff from a specific hash:

```
git diff b97a47e94662^!
```

## Find date

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

## Keeping working branch up-to-date with origin

```
git switch branch-name
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

## Forking FreeBSD port
 From git webui: Fork freebsd/freebsd-ports
# clone forked
git clone git@github.com:ocochard/freebsd-ports.git
# git clone git@github.com:ocochard/freebsd-src.git
cd freebsd-ports
# Add upstream
```
git remote add upstream git@github.com:freebsd/freebsd-ports
```

Therminology:
 - Origin = own fork
 - upstream = FreeBSD official
 - main = name of the main branch (was called 'master' previously)

# Creating a BSDRP branch
# https://git-scm.com/book/en/v2/Git-Branching-Basic-Branching-and-Merging
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
