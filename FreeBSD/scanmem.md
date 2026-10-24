# Editing a game value with scanmem (FreeBSD, Wine game)

[scanmem](https://github.com/scanmem/scanmem) is a command-line memory scanner, the
equivalent of Cheat Engine's "search value, then search again after it changed".
The FreeBSD port reads target memory through linprocfs(5).

## Prerequisites

```sh
pkg install scanmem
mount -t linprocfs linprocfs /compat/linux/proc   # if not already mounted
```

Running as the same user as the game is enough when
`security.bsd.unprivileged_proc_debug=1` (the default).

## Find the game's PID

Wine processes show up as `wine64.bin`; pick the game executable itself, not
`UnityCrashHandler64.exe` or the Wine services:

```sh
ps -axo pid,command | grep -i '\.exe'
```

```
50750 Snapshot!.exe (wine64.bin)
```

## Attach and do the first scan

```sh
scanmem -p 50750
```

```
info: maps file located at /compat/linux/proc/50750/maps opened.
info: 680 suitable regions found.
Please enter current value, or "help" for other commands.
> 117584
...
info: we currently have 24 matches.
24>
```

Typing a number scans every memory region for it. The default data type
(`int`) matches all integer widths; `list` shows the candidates:

```
24> list
[ 0]     69226ea9, 114 +       3e6ea9,  misc, 117584, [I64 I32 ]
...
[ 6]     69e2126c, 114 +       fe126c,  misc, 117584, [I32 ]
...
```

The game keeps running between scans; it is only paused while a scan is in
progress.

## Narrow down after the value changes

Play until the in-game value changes, then type the new value. scanmem only
re-checks the previous matches:

```
24> 130634
info: we currently have 1 matches.
info: match identified, use "set" to modify value.
1> list
[ 0]     69e2126c, 114 +       fe126c,  misc, 130634, [I32 ]
```

Repeat until only one match (or a handful) remains.

## Set the new value

```
1> set 10000000
1> update
1> list
[ 0]     69e2126c, 114 +       fe126c,  misc, 10000000, [I32 ]
```

`set` writes to all current matches (`set 0=10000000` targets match #0 only).
`update` re-reads memory so `list` shows the real current value. An `I32` match
holds values up to 2147483647.

Check in the game that the displayed value changed. If it reverts, the address
was only a display copy: rescan on the next change.

The address is not stable: after a game restart or level reload, redo the scan.

## Driving scanmem from a script (tmux)

To keep the scanmem session alive across commands, run it in a detached tmux
session and send keystrokes to it:

```sh
tmux new-session -d -s scanmem 'scanmem -p 50750'
tmux send-keys -t scanmem '117584' Enter
tmux capture-pane -p -t scanmem | tail
tmux kill-session -t scanmem      # when done
```
