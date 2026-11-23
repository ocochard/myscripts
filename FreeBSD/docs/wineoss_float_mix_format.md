# wineoss: 16-bit shared mode mix format crashes Wwise games

Games using the Wwise audio engine crash under Wine with the OSS sound
driver (wineoss) on FreeBSD, and work with PulseAudio (winepulse). The
cause is the shared mode mix format that wineoss reports: 16-bit PCM,
where Windows always reports 32-bit float.

- Wine merge request: https://gitlab.winehq.org/wine/wine/-/merge_requests/12728
  (commit `051db4482a1` "wineoss.drv: Prefer 32-bit float as the shared
  mode mix format.", branch `wineoss-float-mix-format`)
- Related Wine bug: https://bugs.winehq.org/show_bug.cgi?id=58498
  (Rocket League crashing with OSS on FreeBSD, closed without a root
  cause after a game update stopped the crash)

## Cause

`oss_get_mix_format()` in `dlls/wineoss.drv/oss.c` builds the mix format
from `SNDCTL_ENGINEINFO`:

- On FreeBSD, ENGINEINFO only lists the format of the virtual channel,
  `s16le` by default (`dev.pcm.N.play.vchanformat: s16le:2.0`). It leaves
  out the formats the driver converts from, which `SNDCTL_DSP_GETFMTS`
  reports, float included.
- It checks `AFMT_S16_LE` before `AFMT_FLOAT`.

Wwise writes float samples into the buffer whatever format it opened the
stream with. With a 16-bit stream it writes twice the buffer size and
overruns it: a write access violation in `memcpy` right after
`IAudioRenderClient::GetBuffer()`.

ENGINEINFO also reports no input formats, so capture devices have no mix
format at all (`GetMixFormat()` returns `E_FAIL`).

The fix also queries `SNDCTL_DSP_GETFMTS` and prefers 32-bit float. It is
carried in the poudriere ports tree on bigone as
`files/patch-dlls_wineoss.drv_oss.c` for `emulators/wine`, `wine-devel` and
`wine-proton` (not committed upstream).

Workaround without the patch: switch the virtual channel to float, e.g.
`sysctl dev.pcm.3.play.vchanformat=f32le:2.0`; wineoss then reports float.

## Test 1: Wine's conformance test

`mmdevapi_test.exe render` from Wine's daily `winetest64.exe`, on ser6
(default unit 3, `s16le:2.0`), stock wine-proton 11.0.2_1 (official
package) against the patched 11.0.2_2:

| | stock | patched |
|---|---|---|
| playback mix format | `bits: 16`, `Alg: PCM` | `bits: 32`, `Alg: FLOAT` |
| `render.c:250` in `test_audioclient()` (expects float) | `Test failed: got format {00000001-...}` (PCM) | passes |
| capture, `render.c:2010-2018` | `GetMixFormat failed: 80004005`, then Initialize and GetService fail | passes |

Wine's CI runs on Linux with winepulse, where `render.c:250` passes, so
wineoss never runs this test there.

## Test 2: a public Wwise game

[Unreal Engine 5/Wwise Demo](https://pipedreamdx.itch.io/unrealwwisedemo)
(free on itch.io, `Justin Gilbert UE5-Wwise Demo.zip`, 845 MB). Wwise is
linked into the game executable,
`ModularVictorianHouse-Win64-Shipping.exe`.

Setup, on the framework (FreeBSD 16.0-CURRENT, Strix Halo):

- Run through Moonshine, from two temporary `[[application]]` entries in
  `moonshine.toml` that launch the demo with
  [../wine-game.sh](../wine-game.sh), with
  `WINEDEBUG=+mmdevapi,+oss,+seh`. The client was moonlight-embedded on
  ser6 with `-platform fake` (ser6 had no X session; the host still runs
  the game).
- Same prefix and same Wine tree (wine-proton 11.0.2_6) for both runs. The
  stock run used a copy of the tree, selected with `WINEDIR`, whose
  `lib/wine/x86_64-unix/wineoss.so` came from the official
  `wine-proton-11.0.2_1` package.
- Default sound settings (`s16le` virtual channel).

Results (2026-11-23):

| | stock wineoss | patched wineoss |
|---|---|---|
| stream format Wwise opened | `wBitsPerSample: 16`, PCM | `wBitsPerSample: 32`, IEEE float |
| access violations | 1 | 0 |
| result | the game exited 63 s after launch | still running after 150 s, with sound (30417 buffers released) |

The stock crash:

```
02ac:trace:mmdevapi:render_GetBuffer (0000000052C6CAB0)->(512, 000000005AA5FC30)
02ac:trace:seh:dispatch_exception code=c0000005 (EXCEPTION_ACCESS_VIOLATION) flags=0 addr=00006FFFFD3622FE
02ac:trace:seh:dispatch_exception  info[0]=0000000000000001
02ac:trace:seh:dispatch_exception  info[1]=000000003B7D2000
02ac:warn:seh:virtual_unwind backtrace: 00006FFFFD3622FE: L"VCRUNTIME140.dll" + 00000000000122FE.
02ac:warn:seh:virtual_unwind backtrace: 0000000144F233B3: L"ModularVictorianHouse-Win64-Shipping.exe" + 0000000004F233B3.
```

`info[0]=1` is a write. Another Unreal Engine 5 game using Wwise crashed
the same way, in the same place, before the patch.

Both runs used wine-proton 11.0.2, not an upstream master build; upstream
11.0 and wine-devel 11.22 have the same `oss_get_mix_format()`.
