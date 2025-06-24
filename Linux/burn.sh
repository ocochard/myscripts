#!/bin/sh
# Download multiple tools to do long run burn test on Ubuntu
# Purpose is to burn the computer (or identifying stability problem)
# - CPU: stress-ng
# - RAM: memtester
# - Disk: fio
# - GPU: gravitymark
set -eu
TMUX_SESSION=burn
# Need to disable all upgrades (Don’t want upgrade while running benches)
# apt and snap
#sudo apt update
#sudo apt -y upgrade
sudo apt install -y stress-ng memtester fio tmux wget
export XAUTHORITY=$(ls /run/user/$(id -u)/.* | grep auth)
export DISPLAY=:0
if [ ! -d ~/GravityMark_1.89_linux/bin ]; then
	if [ ! -f ~/GravityMark_1.89.run ]; then
		wget https://tellusim.com/download/GravityMark_1.89.run
	fi
	chmod +x ~/GravityMark_1.89.run
	~/GravityMark_1.89.run --noexec
fi
# Create tmux with 4 panes?
cpu_cmd="stress-ng --matrix 0 -t 10y"
disk_cmd="fio --filename=~/fio.bench --size=50GB --direct=1 --rw=randrw --bs=4k --ioengine=libaio --iodepth=256 --numjobs=4 --time_based -runtime=365d --group_reporting --name=iops-burn --eta-newline=1"
ram_cmd="sudo memtester 80G"
gpu_cmd="cd ~/GravityMark_1.89_linux/bin; ./GravityMark.x64 -vk -width 1920 -height 1080 -ta 1 -a 200000 -fps 1 -info 1 -sensors 1 -benchmark 1"
if ! tmux -2 -u attach-session -t $TMUX_SESSION:0; then
	tmux new-session -d -s $TMUX_SESSION
	tmux send-keys 'echo pane ${TMUX_PANE}' C-m
	tmux split-window -t 0 -v
	tmux send-keys 'echo pane ${TMUX_PANE}' C-m
	tmux split-window -t 1 -h
	tmux send-keys 'echo pane ${TMUX_PANE}' C-m
	tmux split-window -t 0 -h
	tmux send-keys 'echo pane ${TMUX_PANE}' C-m
fi
tmux send-keys -t 0 "${cpu_cmd}" C-m
tmux send-keys -t 1 "${disk_cmd}" C-m
tmux send-keys -t 2 "${ram_cmd}" C-m
tmux send-keys -t 3 "${gpu_cmd}" C-m
tmux -2 -u attach-session -t $TMUX_SESSION:0
