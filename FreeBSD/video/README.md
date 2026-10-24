# vtblank

Paint the FreeBSD console framebuffer black from the command line.

## Why

Under `vt(4)` there is no working screen saver:

- `vidcontrol -t N` sends `CONS_BLANKTIME`, which is a stub in the kernel:

  ```c
  /* sys/dev/vt/vt_core.c */
  case CONS_BLANKTIME:
          /* XXX */
          return (0);
  ```

- The `*_saver.ko` modules shipped in `/boot/kernel` (`blank_saver`,
  `green_saver`, `dpms_saver`, ...) are `syscons(4)` savers. They do not
  attach to `vt`, so loading them changes nothing.
- The keyboard "toggle screen saver" action (`SPCLKEY | SPSC`) is a `/* TODO */`
  in `vt_core.c` as well.

The one blanking path `vt` does implement is the `FBIO_BLANK` ioctl:

```c
/* sys/dev/vt/hw/fb/vt_fb.c */
case FBIO_BLANK:        /* blank display */
        if (vd->vd_driver->vd_blank == NULL)
                return (ENODEV);
        vd->vd_driver->vd_blank(vd, TC_BLACK);
        break;
```

No tool in base issues it. `vtblank` does.

## Build and use

```sh
make
sudo ./vtblank                       # blank the console
sudo ./vtblank -f /dev/ttyv0         # act on a specific tty
```

The console devices are mode `0600 root:wheel` unless `login(1)` has handed one
to you, so this normally needs root.

## What it does not do

- **No monitor power-off.** `vt_fb_blank()` fills the framebuffer with black
  pixels; it does not signal DPMS, so the backlight/monitor stays on. `vt`
  exposes no DPMS control at all. The only way to actually power the panel down
  from a bare console is to suspend the machine (`acpiconf -s 3`).
- **No unblank.** The mode argument (`on`, `blank`, `standby`, `suspend`,
  i.e. `V_DISPLAY_*` from `<sys/fbio.h>`) is accepted for completeness but
  ignored by `vt`, which always paints black. The screen comes back on the next
  repaint: any console output, or a vty switch (`vidcontrol -s 1`).

## Alternative without any C

For a black screen that survives console output, set black-on-black text
instead:

```sh
vidcontrol black black && clear      # also: vidcontrol -b black  for the border
vidcontrol white black && clear      # restore
```

That is just `printf '\033[=0F\033[=0G'`, so it works from any script.
