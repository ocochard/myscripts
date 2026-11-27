---
name: freebsd-src
description: Create an improvement to the FreeBSD source tree, or review a FreeBSD src commit for bugs.
---

To review a commit (or a batch by the same author), follow review.md in
this skill directory.

Before writing or reviewing kernel code that decides a process is dying,
handles signals in a kernel loop, or touches the VM fault path, device
pagers or LinuxKPI mmap/faults, read kernel-facts.md in this skill
directory: verified facts and reviewer rules from earlier patches.

The code:
1. need to be style(9) compliant (cf .clang-format in top of FreeBSD source tree).
2. must not include any copy/past from GPL code.
3. must not include any UTF8 characters
4. must include datasheet spec for drivers if used to wrote the driver
5. Before publishing, prove every new access is in bounds and guarded by
   something that covers it. For each new register/memory access, show the
   mapped resource is at least offset + width bytes. When the new code
   reuses an existing guard (flag, predicate, state), open its definition:
   it was written for the old accesses, so check it still proves what the
   new, possibly wider, access needs.
6. Before designing a fix, search the tree for how the kernel already
   handles the same class of problem (a stuck loop, a retry, a timeout, a
   resource shortage) and start from that pattern. (PR 131: three designs
   before kib pointed to the bounded retry of vm_fault_allocate_oom().)
7. No special case or fast path without a measurement showing it happens.
   When the data says it does not, drop it. (PR 131: a first-retry
   kern_yield() "for the common case" stayed after DTrace showed no retry
   at all; kib had to ask for its removal.)
8. A comment names the concrete condition, then the reason: "if err ==
   VM_FAULT_NOPAGE and no page was inserted, the handler asked to be called
   again", not "the handler asks to be called again". Reviewers read the
   comment first and do not share our context.
9. A tunable default, timeout or limit is justified in the commit message
   by measurement: the distribution in normal use, plus the longest
   legitimate case derived from the code, and the margin chosen. No round
   number without that basis.

## Testing and hand-off

1. For a change to a kernel path, build a minimal reproducer first (for
   example a test module run in a bhyve guest with FreeBSD/kern-test-vm),
   so each design variant and each reviewer suggestion can be measured
   A/B in minutes before any hardware test. Example:
   FreeBSD/docs/linuxkpi_fault_repro/.
2. Before handing over, the PR branch holds the tested commit, already
   rebased on the current freebsd/main, and the hand-off shows
   `git range-diff <tested>~1..<tested> <branch>~1..<branch>` (must show
   `=`); the user then only runs `git pr`. After every push, fetch
   refs/pull/N/head and range-diff it against the tested commit before
   saying anything else about the PR. (PR 131: two pushes carried
   something other than the tested commit.)
3. Keep the PR branch correct yourself, never as a manual step for the
   user. If `git branch -f <pr-branch> <hash>` fails because the branch is
   checked out in the user's tree, update it there (`git reset --hard
   <hash>`, explicit hashes) after checking `git status` shows no changed
   tracked files, and show the range-diff. Pushing stays with the user.

## Tutorial document

Every patch ships with a tutorial written for a first-year computer science
student: someone who knows C and what an OS is, but not this subsystem.
Put it next to the patch as Markdown: `FreeBSD/docs/<patch-name>.md` beside
`<patch-name>.patch` in ~/myscripts, or make the bug report itself the
tutorial when the patch has one (`bugreport_<topic>.md`).

1. Background first: the concepts needed to follow the bug, each defined in
   plain words with the source file and line that implements it.
2. The problem: how to repeat it and the measured output (console, numbers),
   not a description of what would happen.
3. The fix: the diff, why it is the right place, and the alternatives with
   their tradeoffs, including what the patch does NOT fix.
4. Tested: a table of configuration vs measured result, with untested cases
   stated as untested.
5. Mermaid diagrams only where a picture teaches more than prose: data or
   control flow across components, memory/address layouts, decision paths.
   No decorative diagrams; one good diagram beats three.  Bugzilla does not
   render Mermaid, so keep the text readable without them.

## Commit messages

Content and length follow the commit-message rule in the global
CLAUDE.md. This section covers the FreeBSD format only.

1. Subject: `subsystem: Imperative summary`, <= 50 chars if possible, no
   trailing period. The prefix is the component (`mkimg:`, `tpm:`,
   `powerpc/radix:`), not the path.
2. Body: wrapped at 72 columns.
3. Blank line, then metadata tags, values aligned with tabs.

Tags, in the order they usually appear. Verify a tag is real by grepping
the tree (`git log --format=%B | grep -oE '^[A-Z][A-Za-z-]+:' | sort |
uniq -c | sort -rn`) rather than trusting recall; conventions drift, and
`contrib/`, `sys/contrib/` and `sys/cddl/` carry vendored Linux-style
tags that are not native usage.

- `PR:`: only for a bug that this change actually closes. Never inherit
  the PR number of the commit being fixed; `Fixes:` already carries that
  lineage.
- `Fixes:`: `<12-hex> ("original subject")`. Native and common.
- `Reported by:`, `Reviewed by:`, `Tested by:`, `Sponsored by:`: the
  committer's guide spellings, with a tab after the colon. They dominate
  main (2026 commits: 4837 `Reviewed by:` against 2103 `Reviewed-by:`).
  `Co-authored-by:` keeps its hyphens. Name a reviewer once they have
  reviewed and are fine with the change, approval click or not.
- `MFC after:`: a duration such as `1 week`. Drop it if the change is
  not headed to a stable branch.
- `Pull Request:`: the URL of a ron-dev.freebsd.org or GitHub pull
  request (2026: 456 against 79 `Pull-Request:`).
- `Differential Revision:`: a Phabricator review
  (`https://reviews.freebsd.org/D###`) only.

Example:

```
mkimg: Restore offset support for the SIZE partition form

Commit 50c1240ebfaf moved the offset parsing into the PART_KIND_FILE
case of the switch, leaving PART_KIND_SIZE with no offset handling.
The offset was then silently ignored, so "-p efi::$size:$start" as used
by release/${ARCH}/mkisoimages.sh packed the ESP immediately after the
preceding partition.

Parse the offset outside the switch so both forms honour it.  Add tests
covering absolute and relative offsets in both forms.

Fixes:		50c1240ebfaf ("mkimg: Fix parsing of filenames containing colons")
MFC after:	1 week
```
