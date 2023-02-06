#!/bin/sh
SESSION=$USER

tmux -2 new-session -d -s $SESSION

# Setup a window for tailing log files
tmux new-window -t $SESSION:1
tmux new-window -t $SESSION:2
tmux new-window -t $SESSION:3 -n "R1" "ssh bsdrp1"
tmux new-window -t $SESSION:4 -n "R1" "ssh bsdrp2"
tmux new-window -t $SESSION:5 -n "R1" "ssh bsdrp3"
tmux new-window -t $SESSION:6 -n "HP" "ssh hp"
tmux new-window -t $SESSION:7 -n "SM" "ssh sm"
tmux new-window -t $SESSION:8 -n "netgate" "ssh netgate"
tmux new-window -t $SESSION:9 -n "apu2" "ssh apu2"

# Set default window
tmux select-window -t $SESSION:0

# Attach to session
tmux -2 attach-session -t $SESSION

