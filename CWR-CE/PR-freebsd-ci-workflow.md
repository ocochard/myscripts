# PR draft: add FreeBSD CI workflow

Standalone PR against `ofpisnotdead-com/CWR-CE` that adds
`.github/workflows/ci-freebsd.yml`. Independent of PR #51 (POSIX
portability) — will fail until #51 lands, but harmless to have merged
first: the workflow just goes red until the source builds cleanly on
FreeBSD.

Companion file in this directory: [`ci-freebsd.yml`](./ci-freebsd.yml).
Drop it in the fork at `.github/workflows/ci-freebsd.yml` verbatim to
submit.

## Why this works

Native FreeBSD is not one of GitHub's hosted runner OSes. The de-facto
solution is `vmactions/freebsd-vm`: a JavaScript action that runs on the
free `ubuntu-latest` runner, boots a FreeBSD image inside QEMU, mounts
the checkout into the VM over rsync or NFS, and runs `prepare:` / `run:`
scripts as root and as the workflow user respectively.

- The VM has full internet access, so `pkg install` "just works".
- No self-hosted runner or Anthropic-side infra needed.
- Same author, same action, that upstream Sunshine, ZFS-on-Linux,
  Wireshark, and many other projects use for their FreeBSD CI.

Reference used to build this workflow:
<https://github.com/LizardByte/Sunshine/blob/master/.github/workflows/ci-freebsd.yml>
(more elaborate — matrix over releases, cpack packaging, gtest run under
Xvfb — but the shape is identical).

## Package mapping

Every entry in `pkg install -y` maps 1:1 to a `LIB_DEPENDS` /
`BUILD_DEPENDS` line in `~/freebsd-official/ports/games/CWR-CE/Makefile`
(and, indirectly, in the port's `USES=cmake compiler:c++20-lang gl
localbase pkgconfig`).

| CMake / port `find_package(...)` | FreeBSD pkg name |
|----------------------------------|------------------|
| build tools                      | `cmake ninja pkgconf git bash` |
| `find_package(stb)`              | `stb` |
| `find_package(CLI11)`            | `cli11` |
| `find_package(Catch2)`           | `catch2` |
| `find_package(VulkanHeaders)`    | `vulkan-headers` |
| `find_package(glslang)`          | `glslang` |
| `find_package(cJSON)`            | `libcjson` |
| `find_package(CURL)`             | `curl` |
| `find_package(enkiTS)`           | `enkits` |
| `find_package(fmt)`              | `libfmt` |
| `find_package(Freetype)`         | `freetype2` |
| `find_package(imgui)`            | `imgui` |
| `find_package(mimalloc)`         | `mimalloc` |
| `find_package(Ogg)`              | `libogg` |
| `find_package(OpenAL)`           | `openal-soft` |
| `find_package(Opus)`             | `opus` |
| `find_package(SDL3)`             | `sdl3` |
| `find_package(Vulkan)`           | `vulkan-loader` |
| `find_package(spdlog)`           | `spdlog` |
| `find_package(Vorbis)`           | `libvorbis` |
| `find_package(zstd)`             | `zstd` |

Do NOT install `pulseaudio` or `pipewire`; upstream doesn't rely on them
and adding them just balloons VM startup time (10+ min already for pkg
install).

## The vcpkg override

The two CMake args do the heavy lifting:

```
-DVCPKG_MANIFEST_MODE=OFF
-DCMAKE_DISABLE_FIND_PACKAGE_VCPKG=ON
```

Without these, CMake tries to bootstrap vcpkg inside the VM even though
the tree is on rsync-shared storage — you get a mix of "download failed
because the git submodule is empty" and "vcpkg triplet unknown for
freebsd-clang" errors. Turning both off makes every `find_package(...
CONFIG REQUIRED)` in the tree fall back to `${LOCALBASE}/lib/cmake` —
i.e. the pkg-installed CMake package files — which is exactly what the
FreeBSD port does.

## Known caveats

- **First run of the VM is slow** — expect 6-10 min for VM boot + pkg
  install before the compiler even starts. Subsequent runs pay the same
  cost; there's no fast VM caching path in this action. Total pipeline
  time will land around 25-40 min. That's just the price.
- **`sync: rsync` vs `sync: nfs`** — rsync is more portable and works on
  Ubuntu without extra kernel modules. NFS is a few minutes faster on
  large trees but occasionally flakes. Start with rsync; switch to nfs
  only if it becomes the bottleneck.
- **`copyback: false`** — CWR-CE build outputs are large and there's
  nothing on the Linux side to consume them. Skip the tar-back.
- **`actions/checkout@v5` submodules: recursive** — CWR-CE has no
  submodules today, but the flag is harmless and future-proofs the
  workflow if vcpkg gets vendored again someday.
- **aarch64** — technically works via qemu-user emulation, but adds
  20-30 min per job. Not worth it until someone actually wants aarch64
  binaries.
- **Clang version** — the VM ships whatever clang the FreeBSD release
  ships. 14.3 = clang 19, 14.4 = clang 19, 15.0 = clang 20. All fine
  for C++20. No need to pin `llvm19` explicitly like Sunshine does
  unless a specific bug forces it.

## Interaction with PR #51

- Submit this PR *first* if the maintainer will merge it — the workflow
  goes red immediately, but that's fine: the very next PR (#51) will
  turn it green and prove the fix works.
- Alternatively, hold this PR and land it as part of #51. Same outcome,
  smaller PR count, less noise for the maintainer. Slight preference
  for standalone because the CI author-approval friction only has to
  happen once.

## Extending later

Straightforward additions once the base workflow is stable:

- **Matrix over releases** — add `"14.4"` and `"15.0"` next to `"14.3"`.
- **Run tests** — uncomment the `ctest` line; there's a
  `POSEIDON_BUILD_TESTS` toggle upstream that enables gtest under
  `apps/tests/`.
- **Package artifact** — call `cpack -G FREEBSD` after the build, then
  `actions/upload-artifact@v4` to publish a `.pkg` per release, so
  reviewers can install and try without cloning + building. Sunshine's
  workflow shows this pattern verbatim.
- **Cache pkg tree** — `actions/cache` on `/var/cache/pkg` inside the
  VM. Not trivial (rsync-back only), skip until pkg install time is
  actually painful.
