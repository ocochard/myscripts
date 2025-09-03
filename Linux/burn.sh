#!/bin/sh
# Download multiple tools to do long run burn test on Ubuntu
# Purpose is to burn the computer (or identifying stability problem)
# - CPU: stress-ng
# - RAM: memtester
# - Disk: fio
# - GPU: gravitymark
# Then install monit with a simple telegram script to send alert
set -eu
TMUX_SESSION=burn
# apt and snap
#sudo apt update
#sudo apt -y upgrade
sudo apt install -y stress-ng memtester fio tmux curl monit linux-crashdump \
	kdump-tools htop lm-sensors
echo "Disabling SNAP updates (we don’t want firefox upgraded while running GravityMark)"
sudo snap refresh --hold
echo "Disabling apt unattend upgrade (we don’t want any drivers, libs upgrade during burn tests"
if [ -f /etc/apt/apt.conf.d/20auto-upgrades ]; then
	(
	echo 'APT::Periodic::Update-Package-Lists "0";'
	echo 'APT::Periodic::Unattended-Upgrade "0";'
	) | sudo tee /etc/apt/apt.conf.d/20auto-upgrade
fi
echo "Disabling unattended-upgrade service"
sudo systemctl disable --now unattended-upgrades

echo "Enabling core dump"
sudo snap set system system.coredump.enable=true

if kdump-config  status | grep ready; then
	echo "System correctly configured to store kernel crash dumps"
else
	echo "WARNING: Need a reboot to enable kernl crash dumps"
fi
echo "You need to configure auto-login and disable all screen lock"

if [ ! -d ~/GravityMark_1.89_linux/bin ]; then
	if [ ! -f ~/GravityMark_1.89.run ]; then
		curl -o ~/GravityMark_1.89.run https://tellusim.com/download/GravityMark_1.89.run
	fi
	chmod +x ~/GravityMark_1.89.run
	(
		cd ~/
		~/GravityMark_1.89.run --noexec
	)
fi

# Create/install small scripts
mkdir -p ${HOME}/bin
if [ ! -f  ${HOME}/bin/check_kernel_errors ]; then
	cat > ${HOME}/bin/check_kernel_errors <<'EOF'
#!/bin/sh

# Check for "ERROR" in the kernel journal in the last hour (adjust time as needed)
if journalctl -k | grep -q '*ERROR'; then
    echo "Error detected"
    exit 1
else
    exit 0
fi
EOF
	chmod +x ${HOME}/bin/check_kernel_errors
fi

if [ ! -f /etc/monit/conf.d/burn ]; then
	cat <<EOF | sudo tee /etc/monit/conf.d/burn
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
	curl -o ${HOME}/bin/telegram https://raw.githubusercontent.com/ocochard/myscripts/refs/heads/master/tools/telegram.sh
	chmod +x ${HOME}/bin/telegram
	echo "Monit will send messages to your telegram account, but you need to read instructions in ${HOME}/bin/telegram to configure it first"
fi
cpu_cmd="stress-ng --matrix 0 -t 10y"
disk_cmd="fio --filename=~/fio.bench --size=50GB --direct=1 --rw=randrw --bs=4k --ioengine=libaio --iodepth=256 --numjobs=4 --time_based -runtime=365d --group_reporting --name=iops-burn --eta-newline=1"
# Estimate 90% of RAM (/proc/meminfo unit in KB)
percent_ram=$(awk '/MemTotal/ {printf "%.0f\n", ($2 * 0.9)}' /proc/meminfo)
ram_cmd="sudo memtester ${percent_ram}K"
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
tmux send-keys -t 3 "export XAUTHORITY=$(ls /run/user/$(id -u)/.* | grep auth)" C-m
tmux send-keys -t 3 "export DISPLAY=:0" C-m
tmux send-keys -t 3 "${gpu_cmd}" C-m
sudo monit reload
tmux -2 -u attach-session -t $TMUX_SESSION:0
