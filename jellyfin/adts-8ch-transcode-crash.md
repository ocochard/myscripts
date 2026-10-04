# 7.1 audio + HLS/MPEG-TS transcode crashes ffmpeg (exit 139)

Status: worked around on the client 2026-09-24. Both underlying defects remain
open, and the workaround is per-device.
Dates observed: 2026-09-18, 2026-09-24
Host: nas
Jellyfin server: 10.11.11_1 (FreeBSD pkg)
ffmpeg: 9.0.1 (system ffmpeg, NOT jellyfin-ffmpeg)
Client: Jellyfin Android TV 0.19.10
Device: "Olivier's FireTVStick" (Amazon Fire TV Stick). The app reports itself
as "Jellyfin Android TV"; the hardware is a Fire TV Stick, which matters
because the audio setting that fixes this lives in the Fire TV device settings
as well as in the app.
User: alicia

## Symptom

Playback never starts. Client retries in a loop, roughly every 7 seconds.
No video, no audio: ffmpeg dies before writing a single HLS segment.

## Scope measured on 2026-09-18

| Metric | Count |
|---|---|
| `FFmpeg exited with code 139` | 152 |
| Transcode logs containing the ADTS error | 76 |
| Commands built with `-ac 8` | 76 |
| Distinct items affected | 1 |
| Distinct clients affected | 1 (Android TV 0.19.10 on "Olivier's FireTVStick") |

The only other app active that day was Jellyfin Web 10.11.11, which did not hit
this. The 152 count is roughly double the 76 because each failed transcode logs
both a TranscodeManager error and an ExceptionMiddleware error.

## Affected media

    /NAS/films/Fantastique.SF/Pirates.of.the.Caribbean.The.curse.of.the.Black.Pearl.2003.2160p.mkv

    Video   hevc, Dolby Vision Profile 8.1 (HDR10), 3840x1636, yuv420p10le
    Audio 1 eac3, 48000 Hz, 7.1, 8 channels  (fre, default)
    Audio 2 truehd Atmos, 48000 Hz, 7.1, 8 channels  (eng)

Both audio tracks are 8 channels. The file has no stereo or 5.1 track, so
selecting a different track does not avoid the problem.

## Root cause

ADTS headers carry `channelConfiguration` in a 3-bit field. Legal values are 1
to 7. An 8-channel layout cannot be encoded in that field.

MPEG-TS frames AAC using ADTS. So AAC at 8 channels inside an HLS MPEG-TS
segment is not representable.

Jellyfin built exactly that combination:

    -codec:a:0 aac -ac 8 ... -f hls ... -hls_segment_type mpegts

ffmpeg then failed at header write and segfaulted.

## Evidence

Generated command (log_20260918.log, 19:41:50.484), abridged to the decisive flags:

    ffmpeg ... -map 0:1 -codec:v:0 h264_vaapi ... -codec:a:0 aac -ac 8 -ab 640000
      -f hls -hls_time 3 -hls_segment_type mpegts ...

Transcode log, FFmpeg.Transcode-2026-09-18_19-44-51_daba1792e121bc2146738a91eb51b42c_18bc1ac9.log:

    [adts @ 0x...] channelConfiguration > 7 is not supported in ADTS
    [out#0/hls @ 0x...] Could not write header (incorrect codec parameters ?): Invalid data found when processing input
    [vf#0:0 @ 0x...] Error sending frames to consumers: Invalid data found when processing input
    [vf#0:0 @ 0x...] Task finished with error code: -1094995529 (Invalid data found when processing input)

Server log, 0.25 s later:

    [ERR] MediaBrowser.MediaEncoding.Transcoding.TranscodeManager: FFmpeg exited with code 139
    [ERR] Jellyfin.Api.Middleware.ExceptionMiddleware: Error processing request. URL "GET" "/videos/daba1792-e121-bc21-4673-8a91eb51b42c/hls1/main/0.ts"

Client identification, same session:

    [INF] Emby.Server.Implementations.Session.SessionManager: Playback stopped reported by app
    "Jellyfin Android TV" "0.19.10" playing "Pirates of the Caribbean: The Curse of the Black Pearl"

## Two distinct defects

1. Wrong command built. Something in the chain picked AAC 8ch together with an
   ADTS-framed container. The ADTS limit is fixed and knowable before launching
   ffmpeg, so the channel count should be clamped against the output container.

2. ffmpeg segfaults instead of exiting cleanly. Correct behavior for an
   unrepresentable parameter is a clear error and exit 1. Exit 139 is SIGSEGV,
   meaning the teardown path after the handled "Could not write header" touches
   bad state. This is an ffmpeg bug independent of who built the command.

## Which component owns defect 1: not confirmed

The closest upstream report is on the client, not the server:
jellyfin-androidtv issue 5414, "Media with Dolby Atmos 8 channels does not play
or transcode". It describes an Android TV device profile that advertises a `ts`
container over the `hls` protocol with 8-channel audio. That matches this case.

No matching issue found in jellyfin/jellyfin for the exact ADTS string.

Not verified here:
- whether the Android TV profile is the actual source of `-ac 8` and `mpegts`
  (inferred from the generated command, not read from the profile)
- whether jellyfin-ffmpeg crashes the same way as system ffmpeg 9.0.1
- whether a later Jellyfin or client release already fixes this

To confirm the profile theory, capture the device profile the client sends and
check its `TranscodingProfiles` for container `ts` plus `MaxAudioChannels` 8.

## Not the cause

- User policy. alicia has EnablePlaybackRemuxing, EnableVideoPlaybackTranscoding
  and EnableAudioPlaybackTranscoding all True.
- VAAPI. The video path is fine; `h264_vaapi` mapped without complaint. This
  failure is audio-only and will not change by disabling hardware acceleration.
- Server encoding config. /var/db/jellyfin/config/encoding.xml has no audio
  channel cap, and Jellyfin exposes no server-global setting for one.
  DownMixStereoAlgorithm None and DownMixAudioBoost 2 only apply once a downmix
  is actually requested, and nothing requested one.

## Workarounds

Client side, confirmed working on 2026-09-24: set the device audio output to
stereo. This produced `-ac 2` and playback started immediately. See
"Resolution, 2026-09-24 23:42" below. Done in the Fire TV Stick's own audio
settings, not in the Jellyfin app.

Untested variant: reduce to 5.1 rather than stereo. `-ac 6` is also legal in
ADTS and keeps surround, so it should work and is strictly better if the device
offers it. Nobody has tried it here.

Media side: add a 5.1 or stereo AAC track to the file. Costs one re-encode and
disk space. Weaker than it first looked. The 2026-09-24 occurrence failed on a
file that already had a 5.1 track, because the client still selected the
8-channel one. This only helps if the client can be made to pick the smaller
track, which brings you back to the client-side setting anyway.

Avoid transcoding entirely: the request was capped at 1280 width and 4232 kb/s,
which suggests the app quality setting is not at maximum. If the TV can direct
play HEVC Dolby Vision Profile 8.1, raising the quality setting bypasses the
whole path. Depends on TV capability.

A previous suggestion to switch the HLS segment container to fMP4 via
Dashboard > Playback was retracted. fMP4 would genuinely avoid the ADTS field,
but no such server-side setting was confirmed to exist in 10.11: encoding.xml
holds no HLS container key, and the mpegts choice appears to come from the
client profile. Do not act on that suggestion without verifying the option
exists.

## Unrelated observation

The transcode log also shows, on the Dolby Vision video stream:

    [hevc @ 0x...] Multiple Dolby Vision RPUs found in one AU. Skipping previous.

Not fatal and not connected to this failure. Noted only because this file is an
awkward encode generally.

## Second occurrence, 2026-09-24

Same failure, different film. This one kills the "bad file" theory: the trigger
is the 8-channel track selection, not any property of the Pirates encode.

Same host, same Jellyfin 10.11.11_1, same ffmpeg 9.0.1, same client
(Jellyfin Android TV 0.19.10), same user alicia. Window 22:48:32 to 22:49:49.

| Metric | Count |
|---|---|
| `FFmpeg exited with code 139` | 38 |
| `FFmpeg exited with code 137` | 1 |
| Transcode logs containing the ADTS error | 19 |
| Commands built with `-ac 8` | 19 |

The 19 ADTS logs and 19 `-ac 8` commands are the same set. The 38 is again
double, one TranscodeManager error plus one ExceptionMiddleware error each.

The single exit 137 (SIGKILL, 22:49:20.853) is new relative to 2026-09-18. It
is most likely a transcode killed while the retry storm stacked processes, not
a separate defect. Not investigated.

### Affected media

    /NAS/films/Fantastique.SF/The.lord.of.the.rings.The.fellowship.of.the.ring.2001.2160p.mkv

    Video   hevc, Dolby Vision Profile 8.1 (HDR10), 3840x1608, yuv420p10le
    Audio 1 dts DTS-HD MA, 48000 Hz, 5.1, 6 channels  (fre, default)
    Audio 2 truehd Atmos, 48000 Hz, 7.1, 8 channels  (eng)

### Key difference: a legal track exists here

Unlike the Pirates file, this one carries a 6-channel track. The client still
chose the 8-channel English one; the generated command shows `-map 0:2`, which
is the TrueHD Atmos 7.1 stream, and then `-ac 8`.

So for this film there is a one-click unblock: play the French DTS-HD MA 5.1
track. That yields `-ac 6`, which is legal in ADTS. No config change needed.

This also sharpens the diagnosis. The client requested 8 channels while a
6-channel track sat available in the same file, so whatever picks the audio
track is not consulting the ADTS constraint at selection time either.

### Decisive log lines

Generated command (FFmpeg.Transcode-2026-09-24_22-49-46_4cf6c71eba8fdb5df3534f8e1c9c7c86_11e9fdfd.log), abridged:

    ffmpeg ... -map 0:0 -map 0:2 -codec:v:0 h264_vaapi ... -codec:a:0 aac -ac 8 -ab 128000
      -f hls -hls_time 3 -hls_segment_type mpegts ...

Same log:

    [adts @ 0x2025b9622600] channelConfiguration > 7 is not supported in ADTS
    [out#0/hls @ 0x2025af02a6c0] Could not write header (incorrect codec parameters ?): Invalid data found when processing input

Server log:

    [2026-09-24 22:49:47.004 +02:00] [ERR] MediaBrowser.MediaEncoding.Transcoding.TranscodeManager: FFmpeg exited with code 139

Client, same session:

    [2026-09-24 22:49:44.687 +02:00] [INF] Emby.Server.Implementations.Session.SessionManager: Playback stopped reported by app
    "Jellyfin Android TV" "0.19.10" playing "The Lord of the Rings: The Fellowship of the Ring". Stopped at "0" ms

### What this occurrence changes

- Defect 1 is not file-specific. Two unrelated films, one common factor: an
  8-channel track reached an ADTS-framed output.
- The per-file workaround "add a 5.1 track" is insufficient as a general fix.
  This file already had one and still failed.
- The client-side surround setting remains the only workaround that generalises.

## Resolution, 2026-09-24 23:42

Alicia set the Fire TV Stick to stereo output. Playback then worked on the
first try, on the same film that had been looping since 22:48.

The setting changes what the client advertises, so the server builds `-ac 2`
instead of `-ac 8`. Stereo AAC is representable in ADTS, so the mux header
writes and ffmpeg keeps running.

### Before and after, same film, same device

| | 22:48 to 22:49 | from 23:42 |
|---|---|---|
| Audio flag generated | `-ac 8` | `-ac 2` |
| `FFmpeg exited` lines | 39 | 0 |
| ERR or WRN lines | many | 0 |
| HLS segments written | 0 | 10 and counting |

Zero segments versus segments on disk is the decisive difference. Every earlier
attempt died at header write, before any output existed.

### Evidence

Generated command at 23:42:13.858, abridged:

    ffmpeg ... -map 0:0 -map 0:2 -codec:v:0 h264_vaapi ... -codec:a:0 aac -ac 2 -ab 128000
      -af "volume=2" -f hls -hls_time 3 -hls_segment_type mpegts ...

Segments produced under /var/cache/jellyfin/transcodes/:

    -rw-r--r--  1 jellyfin jellyfin  412660 Sep 24 23:42 343765707bf1e54bd38d2e5fa383e0af9.ts
    -rw-r--r--  1 jellyfin jellyfin  261132 Sep 24 23:42 343765707bf1e54bd38d2e5fa383e0af8.ts
    -rw-r--r--  1 jellyfin jellyfin 3416524 Sep 24 23:42 343765707bf1e54bd38d2e5fa383e0af3.ts

ffmpeg pid 95313 alive and encoding at the time of the check.

### Limits of this fix

It is per-device. Any other client that advertises 8 channels over an
ADTS-framed output hits the same crash. Both defects in "Two distinct defects"
above are untouched: Jellyfin still builds an impossible command when asked,
and ffmpeg still segfaults instead of exiting cleanly.

It also costs surround. Alicia now gets a stereo downmix, with `-af volume=2`
applied, of the English TrueHD Atmos track.

### Loose ends, not investigated

- Track choice. The client still maps 0:2, the English track. The French
  DTS-HD MA 5.1 track is unused. If she expected French audio, that is a
  separate setting from the channel count.
- Video is still transcoded, scaled to 1920 wide from 3840. Whether the Fire TV
  Stick could direct play the HEVC Dolby Vision Profile 8.1 source was never
  tested. If it can, raising the app quality setting skips the whole encode.

## Related: HDR colours on the same client

The same Fire TV Stick also reported washed out colours on this kind of
content. That is a separate, unrelated defect: Jellyfin transcoded HDR without
tone mapping. **Solved 2026-09-25**, server side and client independent, so it
is fixed for this device too. See
[hdr-tonemap-not-applied.md](hdr-tonemap-not-applied.md).

Worth knowing for both problems: at maximum client quality the Fire TV Stick
may direct play this content, which avoids the ADTS crash *and* the colour
problem at once, because nothing is re-encoded. Verified working on a Pixel 7;
not yet tested on the Fire TV Stick.

## Next diagnostic step

Capture the Android TV device profile and inspect its TranscodingProfiles, to
confirm or kill the profile theory in defect 1.
