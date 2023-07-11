# git

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
