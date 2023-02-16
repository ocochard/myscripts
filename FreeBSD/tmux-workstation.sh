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
# 4. Create new pane (1) by vertical split pane 0
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
tmux \
  new-session -s $SESSION -n 'w0'\; \
  send-keys 'echo pane 0' C-m \; \
  split-window -t 0 -v\; \
  send-keys 'echo pane 1' C-m \; \
  split-window -t 1 -h -p 75\; \
  send-keys 'echo pane 2' C-m \; \
  split-window -t 2 -h\; \
  send-keys 'echo pane 3' C-m \; \
  split-window -t 0 -h -p 75\; \
  send-keys 'echo pane 4' C-m \; \
  split-window -t 1 -h\; \
  send-keys 'echo pane 5' C-m \;

# Display pane id for a short time
# C-b q
