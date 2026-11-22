#!/bin/sh
# Record the built-in mics (pcm6) while two 3 s 440 Hz tones play 2 s apart.
ffmpeg -loglevel error -y -f oss -sample_rate 48000 -channels 2 -i /dev/dsp6 -t 13 -ac 1 -f s16le /tmp/cs-rec.raw &
r=$!; sleep 2
for n in 1 2; do
	ffmpeg -loglevel error -f lavfi -i sine=frequency=440:duration=3 -f oss /dev/dsp4
	sleep 2
done
wait $r
ls -la /tmp/cs-rec.raw | awk '{print $5" bytes"}'
