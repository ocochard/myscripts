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
sudo apt install -y stress-ng memtester fio tmux wget monit
export XAUTHORITY=$(ls /run/user/$(id -u)/.* | grep auth)
export DISPLAY=:0

if [ ! -d ~/GravityMark_1.89_linux/bin ]; then
	if [ ! -f ~/GravityMark_1.89.run ]; then
		wget https://tellusim.com/download/GravityMark_1.89.run
	fi
	chmod +x ~/GravityMark_1.89.run
	~/GravityMark_1.89.run --noexec
fi

# Create/install small scripts
mkdir -p ${HOME}/bin
if [ ! -f  ${HOME}/bin/check_kernel_errors ]; then
	cat > ${HOME}/bin/check_kernel_errors <<EOF
#!/bin/sh

# Check for "ERROR" in the kernel journal in the last hour (adjust time as needed)
if journalctl -k | grep -q '*ERROR'; then
    echo "Error detected"
    exit 1
else
    exit 0
fi
EOF
fi

if [ ! -f /etc/monit/conf.d/burn ]; then
	cat > /etc/monit/conf.d/burn <<EOF
check process memtester matching "memtester"
  if not exist then exec "${HOME}/bin/telegram sendMessage '${HOSTNAME} memtester crashed'"
check process stress-ng matching "stress-ng"
  if not exist then exec "${HOME}/bin/telegram sendMessage '${HOSTNAME} stress-ng crashed'"
check process GravityMark matching GravityMark.x64
  if not exist then exec "${HOME}/bin/telegram sendMessage '${HOSTNAME} GravityMark crashed'"
check process fio matching "fio"
  if not exist then exec "${HOME}/bin/telegram sendMessage '${HOSTNAME} fio crashed'"
check program check_kernel_errors with path "${HOME}/bin/check_kernel_errors"
    every 5 cycles
    if status != 0 then alert
EOF
fi

if [ ! -f ${HOME}/bin/telegram ]; then
	wget https://raw.githubusercontent.com/ocochard/myscripts/refs/heads/master/tools/telegram.sh
	mv telegram.sh ${HOME}/bin/telegram
	chmod +x ${HOME}/bin/telegram
	echo "Monit will send messages to your telegram account, but you need to read instructions in ${HOME}/bin/telegram to configure it first"
fi
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
	# XXX: tmux detach
fi
tmux send-keys -t 0 "${cpu_cmd}" C-m
tmux send-keys -t 1 "${disk_cmd}" C-m
tmux send-keys -t 2 "${ram_cmd}" C-m
tmux send-keys -t 3 "${gpu_cmd}" C-m
sudo monit reload
tmux -2 -u attach-session -t $TMUX_SESSION:0
