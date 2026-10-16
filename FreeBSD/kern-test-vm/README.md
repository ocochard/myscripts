# kern-test-vm

Boot a kernel under test in a throwaway bhyve guest, run a test program
from rc.local, read the results back, power off.  No network.  Derived
from ../frr-topotest-vm (same console and loader lessons).

    sudo ./mkvm.sh -k /tmp/kobj/kernel:kernel -k /tmp/kobj-base/kernel:kernel.base \
        -t /path/testdir            # testdir/run.sh is what the guest runs
    sudo ./bootvm.sh kernel         # boot one kernel, print /root/results
    sudo ./bootvm.sh kernel.base    # same image, other kernel: an A/B

Kernels build fast with the old-style config build and the host compiler:

    cd sys/amd64/conf && config -d /tmp/kobj GENERIC-NODEBUG
    cd /tmp/kobj && MODULES_OVERRIDE= make -j64

Lessons, on top of frr-topotest-vm's:
- This host's root dataset is 225G, so mkvm.sh copies the base system
  directories by name, not the whole root with --one-file-system.
- autoboot_delay="-1", not "0": with "0" an echoed console byte still
  counted as a keypress and parked the loader at OK.
- Results go to /root/results in the image as well as to the console;
  the console capture lost everything on the first boots.

First used 2026-10-10 for the sendfile(2) fixes of the freebsd-src
`cbmc` branch (sendfile_test A/B).
