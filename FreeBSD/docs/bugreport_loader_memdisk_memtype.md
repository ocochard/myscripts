# loader.efi ram disk: reclaimed by the kernel, or out of its reach

```
Category:  base
Component: boot
Version:   16.0-CURRENT
Keywords:  regression
```

**Summary.** When `loader.efi` downloads a disk image into RAM (`memdisk=`)
and boots FreeBSD from it, the kernel either silently overwrites that image
while it is the root filesystem, or panics trying to read it.  Which one you
get depends on a single constant in the loader.  Fixing it properly takes two
patches: one in the loader (memory type) and one in the kernel's `md(4)`
driver (how it maps the image).

Both failures are reproduced below, with console output, on real hardware
and in bhyve.

---

## 1. Background, for readers new to the boot path

Skip this section if you know how a FreeBSD UEFI netboot works.

### 1.1 What is being booted

The goal is to boot an unmodified FreeBSD installer image (a memstick `.img`
or a CD `.iso`) **over the network, entirely from RAM**, with no USB stick
and no local disk.  The chain is:

```mermaid
sequenceDiagram
    autonumber
    participant FW as UEFI firmware
    participant IPXE as iPXE
    participant L as loader.efi
    participant K as FreeBSD kernel
    participant MD as md(4) driver

    FW->>IPXE: DHCP + HTTP: fetch ipxe.efi, run it
    IPXE->>L: fetch loader.efi, run it with memdisk=URL
    L->>L: download image, decompress into a RAM buffer
    L->>L: register buffer as a disk, read /boot from it
    L->>K: load kernel, pass hint.md.0.physaddr / hint.md.0.len
    Note over L,K: ExitBootServices(): firmware steps aside,<br/>kernel now owns all memory
    K->>MD: md(4) attaches the buffer as /dev/md0
    MD->>K: md0 becomes the root filesystem
```

Steps 3 to 5 are the new `memdisk=` code in `stand/efi/loader/memdisk.c` and
`decompress.c`.  The image never touches a disk: from step 3 on it lives
only in that RAM buffer, and it must stay intact **for as long as the system
runs**, because it *is* the root filesystem.

### 1.2 Who owns which memory

Two programs manage memory one after the other:

* **Before the kernel starts**, the UEFI firmware owns RAM.  The loader asks
  for memory with `AllocatePages()` and must give each allocation a *memory
  type*, a label such as `EfiLoaderData` or `EfiRuntimeServicesData`.
* **When the kernel starts**, it receives the firmware's *memory map*: a list
  of every physical range and its type.  The kernel decides, type by type,
  which ranges it may reuse.

On amd64 that decision is `add_efi_map_entries()` in
`sys/amd64/amd64/machdep.c:838`:

```c
        case EFI_MD_TYPE_BS_CODE:  /* EfiBootServicesCode   */
        case EFI_MD_TYPE_BS_DATA:  /* EfiBootServicesData   */
                if (EFI_MAP_BOOTTYPE_ALLOWED(p->md_type))
                        continue;  /* machdep.efirt.regs keeps it, default off */
                /* FALLTHROUGH */
        case EFI_MD_TYPE_CODE:     /* EfiLoaderCode         */
        case EFI_MD_TYPE_DATA:     /* EfiLoaderData         */
        case EFI_MD_TYPE_FREE:     /* EfiConventionalMemory */
                /*
                 * We're allowed to use any entry with these types.
                 */
                break;
        default:
                continue;          /* everything else: not ours, skip it */
```

The ranges it keeps form **physmap**, the list of RAM the kernel's page
allocator hands out.  The top of physmap is called **Maxmem**.

### 1.3 How the kernel reads a physical address: the direct map

The kernel runs with virtual memory on, so it cannot just dereference a
physical address.  amd64 (like arm64 and riscv) keeps a **direct map
(DMAP)**: one large region of kernel virtual addresses where virtual address
`0xfffff80000000000 + P` always points to physical address `P`.
`PHYS_TO_DMAP(P)` is just that addition.

The DMAP is not infinite.  It is built at boot in `create_pagetables()`
(`sys/amd64/amd64/pmap.c:1805`) and sized from Maxmem:

```c
        ndmpdp = howmany(ptoa(Maxmem), NBPDP);    /* 1 GB units, minimum 4 */
        dmaplimit = (vm_paddr_t)ndmpdp << PDPSHIFT;
```

So **the DMAP covers physical addresses from 0 up to Maxmem rounded up to
1 GB, and nothing above.**  `PHYS_TO_DMAP()` of an address above `dmaplimit`
gives a virtual address with no page behind it.

### 1.4 How md(4) reaches the image

The loader hands the image to the kernel as two environment hints,
`hint.md.0.physaddr` and `hint.md.0.len` (`md_export_to_kernel()` in
`stand/common/md.c`).  The kernel's md driver turns the physical address
into a pointer at `sys/dev/md/md.c:2134`:

```c
        ptr = pmap_map(NULL, paddr, paddr + len, VM_PROT_READ);
```

and on amd64 `pmap_map()` is a single line (`pmap.c:3940`):

```c
        return (PHYS_TO_DMAP(start));
```

There is no check that the range is actually inside the DMAP.

### 1.5 The two requirements

For the ram disk to work, its memory must be:

1. **Kept**: never handed out by the kernel's allocator, so **outside
   physmap**.
2. **Reachable**: readable through the pointer md got, so **below
   `dmaplimit`** (as long as md uses `pmap_map()`).

Requirement 1 pushes the range out of physmap, and that lowers Maxmem, which
lowers `dmaplimit`.  So the two requirements pull against each other, and
the bug is that the code only ever satisfied one of them at a time:

```mermaid
flowchart TD
    A[loader allocates the ram disk buffer] --> B{memory type?}
    B -->|EfiLoaderData<br/>current main| C[kernel adds it to physmap]
    C --> D[allocator hands its pages out]
    D --> E[root filesystem overwritten<br/>while running:<br/>SILENT CORRUPTION]
    B -->|EfiReservedMemoryType<br/>loader patch| F[kernel skips it:<br/>pages are kept]
    F --> G{buffer below dmaplimit?}
    G -->|yes| H[md reads it through the DMAP:<br/>boots fine]
    G -->|no| I[pmap_map returns an unmapped address:<br/>PANIC in mdstart_preload]
    I -.->|md.c patch:<br/>pmap_mapdev_attr| H
```

---

## 2. Bug 1: `EfiLoaderData` lets the kernel overwrite the root filesystem

### How to repeat

Netboot `loader.efi` with `memdisk=` pointing at a memstick image, on
hardware whose firmware has no `EFI_RAM_DISK_PROTOCOL`, so the md fallback is
taken (measured on a Supermicro A1SRi-2758F, AMI rev 5.09, EFI 2.31):

```
chain --replace loader.x64.efi \
    memdisk=.../FreeBSD-15.1-RELEASE-amd64-mini-memstick.img.xz
```

The system boots to userland, then decays.  Commands fail with errors that
look like a corrupt image rather than a memory problem:

```
ld-elf.so.1: /lib/libbsdxml.so.4: invalid file format
$ file /lib/libbsdxml.so.4
/lib/libbsdxml.so.4: data
```

The ram disk is being rewritten underneath the running system.  Three
consecutive reads of the same device return three different checksums:

```
# md5 /dev/md0
MD5 (/dev/md0) = 6e1b0bbd...
# md5 /dev/md0
MD5 (/dev/md0) = aa24358b...
# md5 /dev/md0
MD5 (/dev/md0) = 01377d56...
```

None match the image that was served (`cb891aba774ceb4ccde092d965a10af8`).
The download itself is fine: the byte count on the console matches the
source image exactly, and `libc.so.7` stays valid only because it was paged
in and cached before its backing pages were recycled.

**It is not specific to that hardware.**  Firmware that *does* have
`EFI_RAM_DISK_PROTOCOL` (edk2 in qemu and bhyve) registers the buffer as a
`VirtualDisk` instead of using the md fallback, but the kernel still gets
the same hint: `efiblk_memdisk_preload()` in `stand/efi/libefi/efipart.c`
calls `md_export_to_kernel()` for every `VirtualDisk`.  So both paths end at
the same `md.c` line with the same memory.  Measured under bhyve (8 GB guest)
with the 15.1 `disc1.iso.xz` and a `loader.efi` that still allocates
`EfiLoaderData`: the last physmap chunk, `0x0000000100001000 -
0x000000023374bfff`, runs straight across the ram disk at `0x16a9eb000`;
there is no panic, and userland starts failing at once:

```
pid 667 (awk), jid 0, uid 0: exited on signal 11 (no core dump - other error)
pid 670 (awk), jid 0, uid 0: exited on signal 11 (no core dump - other error)
pid 703 (xargs), jid 0, uid 0: exited on signal 11 (no core dump - other error)
```

(`md5 /dev/md0` was not taken on that run.)

### Cause

`stand/efi/loader/decompress.c` allocates the image as `EfiLoaderData`.
That type becomes `EFI_MD_TYPE_DATA` in the memory map, which
`add_efi_map_entries()` (section 1.2) puts in physmap.  The allocator hands
those pages to whatever asks next, while md keeps serving the same physical
range as `/dev/md0`.

Introduced by `85fb40bad584` ("loader.efi: Use EfiLoaderData memory type for
ram disks", 2026-09-24).  That commit moved *away* from
`EfiReservedMemoryType` to fix a page fault, which is bug 2 below: the old
type failed loudly when out of reach, the new one fails silently.  Silent
corruption of the root filesystem is the worse of the two.

### Fix (loader): `loader_memdisk_memtype.patch`

Allocate the buffer as `EfiReservedMemoryType`.  It is not in the list in
section 1.2, so the kernel skips it and never reuses those pages
(requirement 1).  This fixes the corruption.  It does **not** guarantee
requirement 2: that needs the md.c fix from section 3.  Measured
2026-10-25, results in section 4.

The same type serves both paths.  ACPI requires it for a buffer registered
with `EFI_RAM_DISK_PROTOCOL`.  For the md fallback, UEFI forbids loaders to
allocate it, but the alternative UEFI allows, an OS loader type, hangs real
firmware (see "Is `EfiReservedMemoryType` the right type?" below).

This is the type the fallback used before `85fb40bad584`.  That commit left
Reserved because "the md driver fails", and that failure is bug 2: with a
stock kernel, Reserved panics in `mdstart_preload` when the buffer crosses
`dmaplimit`.  The md.c patch removes it.  `pmap_mapdev_attr()` never looks
at the EFI type, only at the physical address: inside the DMAP it returns
the DMAP address, otherwise it maps the range with `kva_alloc()`
(`pmap.c:9458`).

### Why not `EfiRuntimeServicesData`

The first version of this patch used `EfiRuntimeServicesData`.  The kernel
skips it too, and it fixes the corruption the same way (section 4, Supermicro
row).  But edk2 marks every `EfiRuntimeServicesData` range
`EFI_MEMORY_RUNTIME` and never a Reserved one (`mMemoryTypeStatistics` in
`MdeModulePkg/Core/Dxe/Mem/Page.c`: `Runtime` is `TRUE` for RT_DATA, `FALSE`
for Reserved).  `efi_create_1t1_map()` (`sys/amd64/amd64/efirt_machdep.c:218`)
maps every `EFI_MEMORY_RUNTIME` descriptor into the EFI runtime page table
and registers it with `vm_phys_fictitious_reg_range()`.  `sysctl
machdep.efi_map` in the guest shows the result: with RT_DATA the whole
decompression buffer is a runtime region, with Reserved it is not one.

```
RT_DATA:  RuntimeServicesData 00016a8e0000 00016a8e0000 000d5720 UC WC WT WB RUNTIME
Reserved: (no RUNTIME entry for 0x16a8e0000)
```

That is 875296 pages (3.6 GB) of ram disk that the kernel maps for firmware
runtime calls.  The cost in page tables was not measured.  RT_DATA also
nominally means memory the firmware needs at runtime, so a ram disk abuses
the type.

Limit: Reserved was tested only on amd64 under bhyve's edk2.  The
Supermicro md fallback run predates the switch and used RT_DATA.  arm64 and
riscv build physmap and the DMAP their own way, and other firmware may set
attributes differently.

### Is `EfiReservedMemoryType` the right type?  Specs and prior art

**UEFI says `EfiLoaderData` belongs to the OS.**  UEFI 2.9A, section 7.2.1,
Table 7.6 "Memory Type Usage after ExitBootServices()":

> EfiLoaderData: The Loader and/or OS may use this memory as they see fit.
>
> EfiReservedMemoryType: Not usable.

So the kernel adding `EfiLoaderData` to physmap is correct.  Any loader that
hands an `EfiLoaderData` buffer to the OS needs the OS to reserve it some
other way.  FreeBSD has no such mechanism for the ram disk: the only reader
of `hint.md.N.physaddr` in `sys/` is `md.c:2130`, and nothing in the
physmap setup excludes that range.  So the claim in `85fb40bad584`, "The
kernel handles the former properly and won't reallocate it", does not hold
for the ram disk.  Section 2 measures the result.

**ACPI requires Reserved for a virtual disk.**  ACPI 6.4, section 5.2.25.2
(NFIT, SPA Range Structure):

> System physical address ranges described as Virtual CD or Virtual Disk
> shall be described as AddressRangeReserved in E820, and EFI Reserved
> Memory Type in the UEFI GetMemoryMap.

On the `VirtualDisk` path the loader registers the buffer with
`EFI_RAM_DISK_PROTOCOL` (`memdisk.c:332`) as exactly such a virtual disk.

**edk2 does the same for its own RAM disks.**

* HTTP boot of an ISO: `BmExpandLoadFile()` in
  `MdeModulePkg/Library/UefiBootManagerLib/BmBoot.c` allocates the buffer
  with `AllocateAlignedReservedPages()`.  Commit `026ede493c` (2016):
  "Use reserved memory to hold the buffer for the RAM disk to follow the
  ACPI spec requirement."
* `RamDiskPublishNfit()` in `RamDiskDxe/RamDiskProtocol.c` publishes the
  NFIT entry only when the buffer is `EfiReservedMemoryType`; otherwise it
  returns `EFI_NOT_FOUND` silently.  `RamDiskRegister()` calls it for every
  registration.  So the ACPI RAM disk that `85fb40bad584` says "we don't
  do" is a consequence of the memory type, not of a separate call: with
  `EfiLoaderData` edk2 publishes nothing, with Reserved it publishes an NFIT
  volatile virtual disk.

**Linux makes the same split.**  The x86 EFI stub builds e820 in
`setup_e820()` (`drivers/firmware/efi/libstub/x86-stub.c`):
`EFI_RESERVED_TYPE` and `EFI_RUNTIME_SERVICES_DATA` become
`E820_TYPE_RESERVED`, `EFI_LOADER_DATA` becomes `E820_TYPE_RAM`.  Linux
consumes a firmware RAM disk (edk2 HTTP boot of an ISO) through that NFIT
entry, as `/dev/pmemN` (`nfit_spa_is_virtual()` in
`drivers/acpi/nfit/core.c`, added in 2016 by "acpi, nfit: treat virtual
ramdisk SPA as pmem region").  That only works because the range is
Reserved.

**GRUB uses `EfiLoaderData`, but only with an explicit reservation.**  GRUB
allocates the Linux initrd as `GRUB_EFI_LOADER_DATA`
(`allocate_initrd_mem()` in `grub-core/loader/efi/linux.c`).  It is safe
because Linux reserves the range itself, from `boot_params`, before the page
allocator starts (`early_reserve_initrd()` in `arch/x86/kernel/setup.c`
calls `memblock_reserve_kern()`).  The initrd is also short-lived: Linux
unpacks it and frees it.  A FreeBSD md root lives as long as the system.

**The objection: UEFI forbids loaders to allocate Reserved.**  UEFI 2.9A,
section 7.2.1, `AllocatePages()`:

> UEFI Applications, UEFI Drivers, and UEFI OS Loaders must not allocate
> memory of types EfiReservedMemoryType, EfiMemoryMappedIO, and
> EfiUnacceptedMemoryType.

`loader.efi` is a UEFI OS loader.  Firmware does not enforce the rule: edk2
`CoreInternalAllocatePages()` (`MdeModulePkg/Core/Dxe/Mem/Page.c`) rejects
only out-of-range types, `EfiConventionalMemory`, `EfiPersistentMemory` and
`EfiUnacceptedMemoryType`.  On the `VirtualDisk` path the ACPI rule above is
the more specific one, and edk2 itself follows it.  On the md fallback path
no virtual disk is registered, so only the UEFI rule applies.

The choices for the md fallback are:

| Choice | Spec | Kernel side | Cost |
|---|---|---|---|
| OS loader type `0x80000000` | allowed: "reserved for use by UEFI OS loaders" | skipped by amd64 `add_efi_map_entries()` (`default: continue`), by `subr_efi_map.c` on arm64/riscv (`default: break`), and by Linux `setup_e820()` (`default: continue`) | **hangs `GetMemoryMap()` on a ThinkPad T420** (below) |
| `EfiLoaderData` + kernel reservation (GRUB/Linux model) | clean for the loader | each architecture must exclude `hint.md.N.physaddr` from physmap early; arm64/riscv can use `physmem_exclude_region(..., EXFLAG_NOALLOC)`, which keeps the range in the DMAP | a new loader with an old kernel still corrupts silently |
| `EfiReservedMemoryType` (this patch) | breaks the UEFI loader rule on the fallback path | skipped everywhere, as above | none beyond the md.c fix |

**The OS loader type hangs real firmware.**  A loader that gave the md
fallback buffer type `0x80000000` was tried on 2026-11-08 and works in
bhyve (section 4).  On a Lenovo ThinkPad T420 (2011 firmware, no
`EFI_RAM_DISK_PROTOCOL`, so the md fallback), it hangs the boot after the
last loader message, `staging 0xcaa00000`.  That message is printed by
`bi_load()` (`stand/efi/loader/bootinfo.c:219`) just before it calls
`GetMemoryMap()` and `ExitBootServices()`.  The loader's `memmap` command,
which only calls `GetMemoryMap()` and prints the map, hangs too.  The
loader names unknown types `"Unknown"` (`efi_memory_type()`), so the hang
is in the firmware.  A Dell Latitude E5530 (2012, Dell firmware)
hangs at the same point with the same loader (`staging 0xc6000000`), so
this is not one vendor's bug.  With Reserved, the E5530 boots and the ram disk
survives a RAM fill.  The previous loader, with Reserved on both paths, boots the T420, and
its `memmap` prints the map, with the ram disk as an ordinary entry
(0x28766 pages = 678842880 bytes, the uncompressed mini-memstick):

```
               Reserved 0000893c3000 000000000000 00028766 UC WC WT WB
```
  It was built from a main of 2026-10-20 or
earlier; the only `stand/` commit since then touches the BIOS loader
(`stand/i386/libi386/vbe.c`), so the memory type is the only change that
reaches `loader.efi`.  The md fallback exists for exactly this kind of firmware:
anything older than UEFI 2.6 lacks the RAM disk protocol.  So the
spec-allowed type fails where the fallback is needed, and Reserved, which
edk2 itself uses for ram disks, is the practical choice.

On arm64 and riscv, `subr_efi_map.c` says "Entry types not explicitly listed
here are ignored and not mapped", so Reserved or an OS loader type is never
in the DMAP there.  The md.c fix is then required on every boot, not only
when the buffer is at the top of RAM.

**Measured on real firmware:** a Lenovo X1 Carbon booted on the
`VirtualDisk` path with the Reserved buffer (2026-11-08) has one NFIT.
`acpidump -dt` shows a SPA range with the volatile virtual disk GUID
`77AB535A-45FC-624B-5560-F7B281D1F96E` at the address in
`hint.md.0.physaddr`.  So with Reserved, the firmware publishes the
FreeBSD-registered ram disk to the OS, which contradicts "registered the
device as an ACPI RAM disk, which we don't do" in `85fb40bad584`.  With
`EfiLoaderData`, edk2 publishes nothing (`RamDiskPublishNfit()` above).
`nvdimm(4)` was not loaded, and md0 was the only device over that memory.
Not measured: what `nvdimm(4)` does with the entry when loaded.
`nvdimm(4)` is a module, not in GENERIC, and knows the virtual disk GUIDs
(`nvdimm_spa.c:108`).  If loaded, it would attach a second device over the
same memory as md0.

---

## 3. Bug 2: a kept buffer above `dmaplimit` panics in `mdstart_preload`

Once the buffer is `EfiReservedMemoryType` (the bug 1 fix, and the type
before `85fb40bad584`), it is outside physmap and no longer counts toward
Maxmem.  If the firmware
places it at the **top** of RAM, Maxmem stops where the buffer starts, the
DMAP ends shortly after, and part of the buffer is outside the DMAP.  md's
pointer into that part is not mapped.

### How to repeat

Measured 2026-10-19: bhyve guest, 8 GB, 2 vCPUs, UEFI HTTP boot, the loader
with the first version of `loader_memdisk_memtype.patch`
(`EfiRuntimeServicesData`, no tail trim); the `EfiReservedMemoryType` loader
panics with the same memory map and fault address (section 4), image
`FreeBSD-15.1-RELEASE-amd64-disc1.iso.xz` (894980880 bytes compressed,
1352255488 uncompressed), kernel 15.1-RELEASE GENERIC, `boot_verbose=YES`:

```
Downloaded 894980880 bytes, actual size 1352255488 -- registering ramdisk
Installed RAM disk as VirtualDisk(0x16A9EB000,0x1BB3877FF,0)
...
real memory  = 8589934592 (8192 MB)
Physical memory chunk(s):
...
0x0000000100000000 - 0x000000016a9d0fff, 1788678144 bytes (436689 pages)
avail memory = 4810575872 (4587 MB)
...
md0: Preloaded image <preload0 0x000000016a9eb000> 1352255488 bytes at 0xfffff8016a9eb000
Fatal trap 12: page fault while in kernel mode
cpuid = 1; apic id = 01
fault virtual address   = 0xfffff801bb387600
fault code              = supervisor read data, page not present
current process         = 3 (md0)
panic: page fault
#4 0xffffffff8106e568 at calltrap+0x8
#5 0xffffffff806e5819 at mdstart_preload+0x49
#6 0xffffffff806e5d72 at md_kthread+0x232
```

### Reading the numbers

```mermaid
flowchart LR
    subgraph RAM["guest physical addresses above 4 GB"]
        direction LR
        A["0x100000000 - 0x16a9d0fff<br/>physmap: kernel RAM<br/>(last chunk, ends at Maxmem)"]
        B["0x16a9eb000 - 0x17fffffff<br/>ram disk, first 342 MiB<br/>inside the DMAP: readable"]
        C["0x180000000 - 0x1bb3877ff<br/>ram disk, last 947 MiB<br/>outside the DMAP: NOT MAPPED"]
        D["0x1bb387800 - top of RAM<br/>rest of the 3.6 GB buffer<br/>(unused, kept)"]
        A --- B --- C --- D
    end
    L["dmaplimit = 0x180000000<br/>= Maxmem rounded up to 1 GB"] -.-> C
    F["fault: 0x1bb387600<br/>= the image's last sector"] -.-> C
```

* **The last physmap chunk ends at `0x16a9d0fff`**, right below the ram disk
  at `0x16a9eb000`.  The `0x1a000`-byte gap between them is the kernel
  message buffer, carved off the top of physmap.  Nothing in physmap lies
  above the ram disk.
* **Why the buffer is at the top of RAM:** the decompressor cannot know the
  final size in advance, so for gzip, bzip2 and xz (and zstd without a frame
  size) it allocates `max(4 x compressed size, 64 MB)`, about 3.6 GB here,
  and grows it by 1.5x if needed (`grow_buffer()`).  Without
  `loader_memdisk_trim.patch` the unused tail is never freed.  The firmware placed this block at the top of the 8 GB guest.
* **So Maxmem is about 5.67 GB and `dmaplimit` is `0x180000000` (6 GB).**
* **The ram disk spans `0x16a9eb000 - 0x1bb3877ff`:** the first 342 MiB are
  below 6 GB and readable, the remaining 947 MiB are not.
* **The faulting address is `PHYS_TO_DMAP(0x1bb387600)`**, the image's last
  512-byte sector.  GEOM reads it first when it tastes a new disk for
  trailing metadata (GPT backup header, labels), which is why the fault
  happens within a second of `md0` appearing and not later.

The 15.1 mini-memstick (116 MB compressed, a buffer of about 700 MB) boots on
the same VM with the same loader.  Its placement was not recorded, so why it
lands inside the DMAP is not shown here; it is consistent with a smaller
block not straddling a 1 GB boundary above Maxmem.

### Cause

`sys/dev/md/md.c:2134` maps the hint with `pmap_map()`, which on amd64,
arm64 and riscv is a bare `PHYS_TO_DMAP()` with no range check (section
1.4).  It assumes the physical range is inside the DMAP, which is only
guaranteed for memory the kernel owns, i.e. for exactly the memory the ram
disk must *not* be in.

On i386 and arm, `pmap_map()` builds a real mapping but writes through its
first argument, which md passes as `NULL`, so that call is not correct there
either.

### Fix (kernel): map the range wherever it lies

```diff
--- sys/dev/md/md.c
+++ sys/dev/md/md.c
@@ -2131,7 +2131,11 @@ g_md_init(struct g_class *mp __unused)
 		    resource_int_value("md", i, "len", &len) != 0)
 		        break;
-		ptr = pmap_map(NULL, paddr, paddr + len, VM_PROT_READ);
+		/*
+		 * The loader keeps the image out of physmap, so it can lie
+		 * beyond the direct map, where pmap_map() is not valid.
+		 */
+		ptr = pmap_mapdev_attr(paddr, len, VM_MEMATTR_DEFAULT);
 		if (ptr != NULL && len != 0) {
```

`pmap_mapdev_attr()` exists on every architecture md(4) builds for (amd64,
arm, arm64, i386, powerpc, riscv).  On amd64 it returns the DMAP address when
the whole range is inside the DMAP, and otherwise allocates kernel virtual
address space and maps the pages there.  `VM_MEMATTR_DEFAULT` is normal
cached memory, so reads stay fast.  `pmap_large_map()` would also work but
is amd64-only, while md.c is machine-independent.

An alternative is to make the loader allocate below the current Maxmem
(`AllocateMaxAddress`), but the loader cannot know the kernel's final
Maxmem, so that only moves the problem.  Freeing the unused tail of the
decompression buffer is worth doing anyway (2.2 GB here goes back to the
kernel), but on its own it does not stop the firmware placing the buffer at
the top of RAM.

---

## 4. Tested

| Loader | Kernel | Image | Platform | Result |
|---|---|---|---|---|
| `EfiLoaderData` (main) | 15.1 | mini-memstick | Supermicro, md fallback | userland corrupts, `md5 /dev/md0` changes per read |
| `EfiLoaderData` (main) | 15.1 | disc1.iso | bhyve, VirtualDisk | no panic, userland SIGSEGVs |
| `EfiRuntimeServicesData` | 15.1 | mini-memstick | Supermicro, md fallback | multi-user, `md5 /dev/md0` stable and equal to the served image |
| `EfiRuntimeServicesData` | 15.1 | mini-memstick | qemu and bhyve, VirtualDisk | installer prompt, no panic |
| `EfiRuntimeServicesData` | 15.1 | disc1.iso | bhyve, VirtualDisk | **panic in `mdstart_preload`** (section 3) |
| `EfiRuntimeServicesData` | 15.1 + md.c patch | disc1.iso | bhyve, VirtualDisk | **installer prompt, no panic; image intact except the backup GPT edk2 writes** (below) |
| `EfiReservedMemoryType` | stock 15.1 | disc1.iso | bhyve, VirtualDisk | **panic in `mdstart_preload`**, same fault address as RT_DATA (below) |
| `EfiReservedMemoryType` + tail trim | stock 15.1 | disc1.iso | bhyve, VirtualDisk | **single-user shell, no panic, image intact under memory pressure, +2046 MB usable** (below) |
| `EfiReservedMemoryType` | 15.1 + md.c patch | disc1.iso | bhyve, VirtualDisk | **installer prompt, no panic, image intact except the backup GPT** (below) |
| `EfiReservedMemoryType` | stock 15.1 | mini-memstick | bhyve, VirtualDisk | **single-user shell, `md5 /dev/md0` equal to the served image before and after filling RAM** (below) |
| `EfiReservedMemoryType` + tail trim | 15.1 + md.c patch | mini-memstick | bhyve, VirtualDisk | **single-user shell, ram disk inside the DMAP, `md5 /dev/md0` equal to the served image before and after filling RAM** (below) |
| OS loader type `0x80000000`, md fallback forced | stock 15.1 | mini-memstick | bhyve, md fallback | **single-user shell, `md5 /dev/md0` equal to the served image before and after filling RAM** (below) |
| `EfiReservedMemoryType` | stock 15.1 | mini-memstick | Lenovo X1 Carbon, VirtualDisk | boots, `md5 /dev/md0` equal to the served image (RAM fill not reported); firmware publishes an NFIT virtual disk SPA at the ram disk address |
| `EfiLoaderData`, md fallback forced (negative control) | stock 15.1 | mini-memstick | bhyve, md fallback | **`dd` SIGSEGV, `md5 /dev/md0` changes, `poweroff: Exec format error`** (below) |
| OS loader type `0x80000000` | stock 15.1 | mini-memstick | Lenovo T420, md fallback | **hangs after `staging 0xcaa00000`; `memmap` at the loader prompt hangs** (section 2) |
| OS loader type `0x80000000` | stock 15.1 | mini-memstick | Dell Latitude E5530 (2012) | **hangs after `staging 0xc6000000`, like the T420** (2026-11-08) |
| `EfiReservedMemoryType` (this patch) | stock 15.1 | mini-memstick | Dell Latitude E5530 (2012) | **boots; ram disk range `Reserved`; `md5 /dev/md0` unchanged after filling RAM** (2026-11-08) |
| `EfiReservedMemoryType` (this patch) | stock 15.1 | mini-memstick | Lenovo T420, md fallback | **boots (verbose); ram disk range `Reserved`; `memmap` prints the map** |
| `EfiReservedMemoryType` (this patch) | stock 15.1 | mini-memstick | Supermicro A1SRi-2758F (16 GB), md fallback | **ram disk range `Reserved 0000310ce000 ... 00028766`; `md5 /dev/md0` equal to the served image before and after writing 14000 MB to tmpfs** (2026-11-08) |

With the md.c patch, same VM, same loader, same image rebuilt around the
patched kernel (895026656 bytes compressed, so the decompression buffer is the
same size and lands in the same place):

```
Downloaded 895026656 bytes, actual size 1352554496 -- registering ramdisk
Installed RAM disk as VirtualDisk(0x16A9BE000,0x1BB3A37FF,0)
FreeBSD 15.1-RELEASE #0 n283562-96841ea08dcf-dirty
...
0x0000000100000000 - 0x000000016a9a3fff, 1788493824 bytes (436644 pages)
...
md0: Preloaded image <preload0 0x000000016a9be000> 1352554496 bytes at 0xfffffe006e000000
Trying to mount root from cd9660:/dev/iso9660/15_1_RELEASE_AMD64_CD [ro]...
Welcome to FreeBSD!
Console type [vt100]:
```

The ram disk again starts right above the last physmap chunk and crosses
`dmaplimit` (`0x180000000`), so this is the failing configuration.  md0 is now
at `0xfffffe006e000000`, a kernel virtual address from `pmap_mapdev_attr()`,
instead of the unmapped DMAP address `0xfffff8016a9eb000` of the panic run.
Root mounts and the installer starts; the console log has no fault, panic or
SIGSEGV.

Integrity, checked from a root shell in the same guest:

```
root@:~ # md5 /dev/md0; md5 /dev/md0
MD5 (/dev/md0) = af10376626811775913f6f30e98a7f59
MD5 (/dev/md0) = af10376626811775913f6f30e98a7f59
```

Stable across reads, but not equal to the served image
(`9515bb08d9518dca2a775b97ef8a1830`).  Comparing 64 MiB chunks and then
single sectors against the host copy, every sector is identical except
two: LBA 2641675 (T-33) and LBA 2641707 (T-1, the last one).  Those are
where a backup GPT lives.  The published disc1 ISO has a primary GPT whose
`AlternateLBA` is 2641707, but that sector is all zeros: the ISO ships
without a backup GPT.  In the guest it holds a valid backup header, and
T-33 holds the first backup partition entry (freebsd-boot).

That write happens before the kernel starts, and it is the firmware's: edk2
`PartitionDxe` (`MdeModulePkg/Universal/Disk/PartitionDxe/Gpt.c`), on
finding a valid primary and an invalid backup, rebuilds the backup ("Restore
backup partition table by the primary"), and the `VirtualDisk` it is
probing is writable RAM.  The kernel never sees a broken GPT: GEOM logs no
GPT warning and `gpart show md0` reports a healthy table, not `CORRUPT`.

So the ram disk is intact; the whole-device checksum just cannot match the
published ISO under edk2.  With the md fallback (no firmware partition
driver ever probes the buffer) it does match, as on the Supermicro.  This is
not a FreeBSD bug, but it will trip anyone who verifies a `memdisk=` boot
with `md5 /dev/md0`: compare everything except the backup GPT sectors.

Freeing the unused tail of the decompression buffer
(`loader_memdisk_trim.patch`, tutorial in `loader_memdisk_trim.md`) avoids
the panic on its own in this configuration, with the **stock** 15.1 kernel.
Measured 2026-11-08, loader from main `bdcfeac3e1cb` plus patches #1 to #5
of `FreeBSD/iPXE.md` 7(f), so `EfiReservedMemoryType`:

```
Freed 2227666944 unused bytes of the decompression buffer
Downloaded 894980880 bytes, actual size 1352255488 -- registering ramdisk
Installed RAM disk as VirtualDisk(0x16A9EB000,0x1BB3877FF,0)
FreeBSD 15.1-RELEASE releng/15.1-n283562-96841ea08dcf GENERIC amd64
0x0000000100000000 - 0x000000016a9eafff, 1788784640 bytes (436715 pages)   <- was 0x16a9d0fff
0x00000001bb388000 - 0x000000023ffe5fff, 2227560448 bytes (543838 pages)   <- new: the freed tail, now usable RAM
avail memory = 6955855872 (6633 MB)                                         <- was 4587 MB
md0: Preloaded image <preload0 0x000000016a9eb000> 1352255488 bytes at 0xfffff8016a9eb000
Trying to mount root from cd9660:/dev/iso9660/15_1_RELEASE_AMD64_CD [ro]...
Enter full pathname of shell or RETURN for /bin/sh:
# sysctl machdep.efi_map | grep -v -e BootServices -e Conventional
...
               Reserved 00016a9eb000 000000000000 0005099d UC WC WT WB
```

The ram disk did not move and stays Reserved (0x5099d pages, the image
rounded up to a page): edk2 accepts a partial `FreePages()` of a Reserved
allocation. the memory above it is now the kernel's, so
Maxmem and the direct map reach the top of RAM and cover it.  Every sector
of `/dev/md0` matches the published ISO except the two backup-GPT sectors
edk2 writes (LBA 2641091 and 2641123 for this image), and two whole-device
reads agree, also after writing 5500 MB to tmpfs.  This does not replace the md.c patch: an image allocated at
its exact size (uncompressed, or zstd with a frame size) has no tail to free
and can still land at the top of RAM.

`EfiReservedMemoryType` instead of `EfiRuntimeServicesData`, measured
2026-10-25.  Loader: main at `06abe08de45d` with patches #1 to #4 of
`FreeBSD/iPXE.md` 7(f) and `mem_type` set to `EfiReservedMemoryType`, no
tail trim, so the 3.6 GB buffer lands where the panic run put it.  Building
the same tree with `EfiRuntimeServicesData` gives a different checksum
(Reserved `88e0bdc3...`, RT_DATA `bb05ca81...`), so the constant reaches
the binary.

With the stock 15.1 kernel it panics exactly like RT_DATA:

```
Installed RAM disk as VirtualDisk(0x16A9EB000,0x1BB3877FF,0)
FreeBSD 15.1-RELEASE releng/15.1-n283562-96841ea08dcf GENERIC amd64
0x0000000100000000 - 0x000000016a9d0fff, 1788678144 bytes (436689 pages)
md0: Preloaded image <preload0 0x000000016a9eb000> 1352255488 bytes at 0xfffff8016a9eb000
Fatal trap 12: page fault while in kernel mode
fault virtual address	= 0xfffff801bb387600
#5 0xffffffff806e5819 at mdstart_preload+0x49
```

With the md.c patch in the ISO's kernel it boots to the installer, with the
ram disk again crossing `dmaplimit`:

```
Installed RAM disk as VirtualDisk(0x16A8E0000,0x1BB26EFFF,0)
0x0000000100000000 - 0x000000016a8c5fff, 1787584512 bytes (436422 pages)
md0: Preloaded image <preload0 0x000000016a8e0000> 1352200192 bytes at 0xfffffe006e000000
Welcome to FreeBSD!
# md5 /dev/md0; md5 /dev/md0
MD5 (/dev/md0) = 8b42ba1cf043883672a3e59b528dadb3
MD5 (/dev/md0) = 8b42ba1cf043883672a3e59b528dadb3
```

The two reads agree.  The image has 2641016 sectors and its backup GPT
sits at T-33 and T-1, where edk2 writes.  Every other sector matches the
served ISO: in the guest and on the host, `dd` of sectors 0 to 2640982
gives `17c1e701435dd5ac3f52e9a73cd02254`, and of sectors 2640984 to
2641014 gives `51596dda30fc38f0df3556d6f115256d`.

The md.c patch with a ram disk that lies inside the DMAP, the common case,
measured 2026-11-08.  Loader: main at `bdcfeac3e1cb` plus patches #1 to #5
of `FreeBSD/iPXE.md` 7(f).  Kernel: releng/15.1 at `96841ea08dcf` plus
`md_preload_mapdev.patch`, installed in the 15.1 mini-memstick, which was
then recompressed with `xz` (image md5 `02d1f790...`).  bhyve, 8 GB,
`boot_single=YES`:

```
Freed 75010048 unused bytes of the decompression buffer
Downloaded 125641860 bytes, actual size 678842880 -- registering ramdisk
Installed RAM disk as VirtualDisk(0x6D185000,0x958EA1FF,0)
FreeBSD 15.1-RELEASE #0 n283562-96841ea08dcf-dirty: Sun Nov  8 23:34:03 CET 2026
avail memory = 7629225984 (7275 MB)
md0: Preloaded image <preload0 0x000000006d185000> 678842880 bytes at 0xfffff8006d185000
# sysctl machdep.efi_map | grep -v -e BootServices -e Conventional
               Reserved 00006d185000 000000000000 00028766 UC WC WT WB
# md5 /dev/md0; md5 /dev/md0
MD5 (/dev/md0) = 02d1f790585dfdbe216de38a0f9f9ca8
MD5 (/dev/md0) = 02d1f790585dfdbe216de38a0f9f9ca8
# dd if=/dev/zero of=/tmp/fill bs=1m count=7000   (tmpfs)
vm.stats.vm.v_free_count: 54871
# md5 /dev/md0
MD5 (/dev/md0) = 02d1f790585dfdbe216de38a0f9f9ca8
```

`pmap_mapdev_attr()` returned the DMAP address (`0xfffff8006d185000`), so
the patch keeps the direct map when the range is covered.  After the kernel
used all but 214 MB of its memory, the ram disk still matched the image.

A variant of this patch (Reserved for a registered RAM disk, OS loader
type `0x80000000` for md, since dropped because of the T420), measured
2026-11-08.  Loader: main at `0448f4d0a435` with patches #1 to #5
of `FreeBSD/iPXE.md` 7(f).  bhyve's edk2 has `EFI_RAM_DISK_PROTOCOL`, so a
test-only build sets `ram_disk = NULL` after the lookup to force the md
fallback; the negative control also sets the md type back to
`EfiLoaderData`.  Image: the 15.1 mini-memstick (`cb891aba...`
uncompressed), stock 15.1 kernel, 8 GB guest, `boot_single=YES`.  In the
single-user shell: `md5 /dev/md0`, then fill RAM with 7000 MB written to
tmpfs, then `md5 /dev/md0` twice more.

| Loader | Buffer in `sysctl machdep.efi_map` | md5 before fill | md5 after fill (x2) |
|---|---|---|---|
| Reserved, VirtualDisk | `Reserved 0000729e1000 ... 00028766` | `cb891aba...` | `cb891aba...`, `cb891aba...` |
| OS loader type, md fallback forced | `<INVALID> 0000729e1000 ... 00028766` | `cb891aba...` | `cb891aba...`, `cb891aba...` |
| `EfiLoaderData`, md fallback forced | `LoaderData 0000729e1000 ... 00028766` | `cb891aba...` | `c1c08d94...`, `c1c08d94...` |

`<INVALID>` is how the kernel prints a type it has no name for, here
`0x80000000`.  With the OS loader type, physmap has a hole exactly where
the buffer is (`hint.md.0.physaddr` `0x729e1000`, 678842880 bytes):

```
0x0000000000100000 - 0x00000000729e0fff, 1921912832 bytes (469217 pages)
0x000000009b147000 - 0x00000000b3ffffff, 418091008 bytes (102073 pages)
```

The fill left `v_free_count` at 54394 pages (212 MB), so the kernel had
used nearly all the memory it owns, and none of it was the ram disk.  The
negative control proves the fill catches the bug: during the fill, `dd`
died with SIGSEGV (`pid 29 (dd) ... exited on signal 11`), the device
checksum changed, and `poweroff` then failed with `Exec format error`.

Base: main at `f22d65998fe1` (2026-11-01) for all patches; source line
numbers in this report are from that tree.  On releng/15.1 the md.c line
has an extra `(char *)` cast before `pmap_map`.

Patches attached: `loader_memdisk_memtype.patch` (loader),
`md_preload_mapdev.patch` (kernel), `loader_memdisk_trim.patch` (loader,
optional but recommended).

---

## Local notes (not for submission)

* Loader patch: `FreeBSD/docs/loader_memdisk_memtype.patch`
* Investigation: `FreeBSD/iPXE.md`, section 7(f) "The fallback needed four
  fixes"
* 2026-10-19 panic: `FreeBSD/bhyve-uefi-http-poc.sh -N -k -e
  boot_verbose=YES -i <disc1.iso.xz>`, with the default loader (this patch)
  from `people.freebsd.org/~olivier/iPXE/loader.x64.efi`.
* The `EfiLoaderData` bhyve run used `-l /boot/loader.efi` on bigone (built
  2026-10-13 from main, which still has `EfiLoaderData`).  That this binary
  lacks the loader patch is inferred from the source and the symptoms, not
  checked in the binary.
* Reserved test (2026-10-25), build trees deleted 2026-10-26.  To redo it:
  * Loader: worktree of main (`06abe08de45d`), apply patches #1 to #4 of
    `FreeBSD/iPXE.md` 7(f) (add #5 for the hosted build), then
    `make -C stand obj all` with `WITHOUT_CCACHE_BUILD=yes
    WITHOUT_META_MODE=yes` and a fresh `MAKEOBJDIRPREFIX`.  The artifact is
    `stand/efi/loader_lua/loader_lua.efi`.
  * Kernel: worktree of releng/15.1 at `96841ea08dcf` (the ISO's own
    commit) plus `md_preload_mapdev.patch`, `make buildkernel
    KERNCONF=GENERIC WERROR= NO_MODULES=yes`.  Host clang 21 rejects 15.1
    netmap and if_ovpn with `-Werror`.
  * ISO: extract disc1 with `tar`, `chmod 755` the extracted root (tar
    leaves it 700), install the kernel as `boot/kernel/kernel`, rebuild with
    `release/amd64/mkisoimages.sh -b 15_1_RELEASE_AMD64_CD`, `xz` it.
  * Boot: `FreeBSD/bhyve-uefi-http-poc.sh -N -k -l <loader> -e
    boot_verbose=YES -i <iso.xz>`.
* md.c test (passed 2026-10-19): same kernel and ISO recipe as above, in a
  worktree that no longer exists.
* OS loader type test (2026-11-08): worktree and objdirs deleted the same
  day; recreate with a worktree of main plus patches #1 to #5, built as in
  the Reserved test below.  Loaders and console logs kept in
  `~/memdisk-ostype-test/`.  Driver `drive2.py` runs
  `bhyve-uefi-http-poc.sh` (stdio console) under a pty and types the
  checks.  Use it rather than `-N`: with the nmdm console the output stopped
  after `Loading /boot/loader.conf.local` in three runs, one of which ended
  in a guest reset that was never explained.  Under the pty the same loaders
  booted every time.
* Spec quotes (UEFI 2.9A Table 7.6 and the `AllocatePages()` note, ACPI 6.4
  5.2.25.2) come from search excerpts of the uefi.org HTML specs: uefi.org
  returned 403 to the fetcher on 2026-11-08.  Check them word for word
  against the current UEFI/ACPI PDFs, and the table numbers, before
  submitting.  edk2 references: `~/edk2-upstream` at `870493d743`.  Linux
  and GRUB references: master on 2026-11-08 (GRUB via the rhboot mirror).
