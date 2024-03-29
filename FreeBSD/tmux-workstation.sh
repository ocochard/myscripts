#!/bin/sh
# Create or re-attache to a tmux session with 1 window and 6 panes
SESSION=$USER

# tmux base concept
# --------------------------------------
# |              session               |
# | --------------------- ------------ |
# | |       window      | |  window  | |
# | | -------- -------- | | -------- | |
# | | | pane | | pane | | | | pane | | |
# | | -------- -------- | | -------- | |
# | --------------------- ------------ |
# --------------------------------------
#
# -2 Force 256 color mode
# -u Force UTF-8
# -t Target-session
tmux -2 -u attach-session -t $SESSION ||

# 1. Create a new session
# 2. The default created window is named (-n) 'w0'
# 3. With a default pane (0) (if .tmux.conf doesn't set base-index or pane-base-index to other like 1)
# 4. From default pane 0, create new pane (1) by vertical split pane 0
# #  ----------
# #  | pane 0 |
# #  ----------
# #  | pane 1 |
# #  ----------
# 5. Create new pane (2) by horizontal split pane 1 that takes 75% of the screen width
# #  ----------------------------
# #  |           pane 0         |
# #  ----------------------------
# #  | pane 1 |     pane 2      |
# #  ----------------------------
# 6. Create new pane (3) by horizontal split pane 2
# #  ----------------------------
# #  |           pane 0         |
# #  ----------------------------
# #  | pane 1 | pane 2 | pane 3 |
# #  -----------------------------
# 7. Create new pane (4) by horizontal split pane 0 that takes 75% of the screen witdh
# #  ----------------------------
# #  | pane 0 |    pane 1       |
# #  ----------------------------
# #  | pane 2 | pane 3 | pane 4 |
# #  -----------------------------
# 8. Create new pane (5) by horizontal split active pane (so 0?)
# #  ----------------------------
# #  | pane 0 | pane 1 | pane 2 |
# #  ----------------------------
# #  | pane 3 | pane 4 | pane 5 |
# #  -----------------------------
#
# Clipboard sharing with OS
# https://github.com/tmux/tmux/wiki/Clipboard
# MacOS terminal user bug not able to copy/past with mouse
# Need to use iterm2 with:
# Pref -> General -> selection -> check "Applications in the terminal may access the clipboard"
# And check tmux "external" set-clipboard is configured:
# tmux show -s set-clipboard
# Need to have mouse support in .tmux.conf for this option too
tmux \
  set-option -g mouse on\; \
  new-session -s $SESSION -n 'w0'\; \
  send-keys 'echo pane ${TMUX_PANE}' C-m \; \
  split-window -t 0 -v\; \
  send-keys 'echo pane ${TMUX_PANE}' C-m \; \
  split-window -t 1 -h -p 75\; \
  send-keys 'echo pane ${TMUX_PANE}' C-m \; \
  split-window -t 2 -h\; \
  send-keys 'echo pane ${TMUX_PANE}' C-m \; \
  split-window -t 0 -h -p 75\; \
  send-keys 'echo pane ${TMUX_PANE}' C-m \; \
  split-window -t 1 -h\; \
  send-keys 'echo pane ${TMUX_PANE}' C-m \; \

# Display pane id for a short time
# C-b q
