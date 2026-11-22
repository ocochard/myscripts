#!/bin/sh
# A: tone right after firmware load; B: cold tone, then warm tone 2 s later.
kldunload snd_cs35l54; kldload /tmp/snd_cs35l54-ready.ko
n=0
until dmesg | tail -1 | grep -q 'amplifiers, firmware'; do
	sleep 0.2; n=$((n + 1)); [ $n -lt 150 ] || { echo "no firmware load"; exit 1; }
done
ffmpeg -loglevel error -y -f oss -sample_rate 48000 -channels 2 -i /dev/dsp6 -t 5 -ac 1 -f s16le /tmp/cs-a.raw &
r=$!; sleep 0.5
ffmpeg -loglevel error -f lavfi -i sine=frequency=440:duration=3 -f oss /dev/dsp4
wait $r
sleep 8	# amplifiers hibernate: cold start next
ffmpeg -loglevel error -y -f oss -sample_rate 48000 -channels 2 -i /dev/dsp6 -t 11 -ac 1 -f s16le /tmp/cs-b.raw &
r=$!; sleep 0.5
for n in 1 2; do
	ffmpeg -loglevel error -f lavfi -i sine=frequency=440:duration=3 -f oss /dev/dsp4
	sleep 2
done
wait $r
kldunload snd_cs35l54-ready; kldload /boot/kernel.zbook/snd_cs35l54.ko
