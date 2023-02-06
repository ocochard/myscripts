#!/bin/sh
SESSION=$USER

# -2 Force 256 color mode
# -u Force UTF-8
tmux -2 -u attach-session -t $SESSION ||
tmux \
  new-session -s $SESSION -n 'w0'\; \
  send-keys 'ssh dev' C-m \; \
  split-window -t 0 -v\; \
  send-keys 'ssh lame4' C-m \; \
  split-window -t 1 -h -p 75\; \
  send-keys 'ssh bigone' C-m \; \
  split-window -t 2 -h\; \
  send-keys 'ssh netboot-f' C-m \; \
  split-window -t 0 -h -p 75\; \
  send-keys 'ssh autobuilder' C-m \; \
  split-window -h\; \
  send-keys 'echo p5' C-m \;
