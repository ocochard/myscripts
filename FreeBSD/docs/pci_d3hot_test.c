/*
 * pci_d3hot_test: attach to the idle AMD Strix Halo USB4 host router
 * (1022:158d function 5), walk it through pci_set_powerstate() requests
 * and print each return value and the state read back.  Checks that a
 * D3hot or D3cold request on a device already in D3 is a no-op, and
 * that an out-of-range state still returns EINVAL.
 */
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/bus.h>
#include <sys/kernel.h>
#include <sys/module.h>
#include <dev/pci/pcivar.h>

static int
d3t_probe(device_t dev)
{
	if (pci_get_vendor(dev) != 0x1022 || pci_get_device(dev) != 0x158d ||
	    pci_get_function(dev) != 5)
		return (ENXIO);
	device_set_desc(dev, "PCI D3 test");
	return (BUS_PROBE_DEFAULT);
}

static void
d3t_set(device_t dev, int state, int expect)
{
	int error;

	error = pci_set_powerstate(dev, state);
	device_printf(dev, "set %d: error %d (expect %d), now %d: %s\n",
	    state, error, expect, pci_get_powerstate(dev),
	    error == expect ? "PASS" : "FAIL");
}

static int
d3t_attach(device_t dev)
{
	device_printf(dev, "initial state %d\n", pci_get_powerstate(dev));
	d3t_set(dev, PCI_POWERSTATE_D3_HOT, 0);
	d3t_set(dev, PCI_POWERSTATE_D3_HOT, 0);
	d3t_set(dev, PCI_POWERSTATE_D3_COLD, 0);
	d3t_set(dev, PCI_POWERSTATE_MAX + 1, EINVAL);
	d3t_set(dev, PCI_POWERSTATE_D0, 0);
	return (ENXIO);		/* do not keep the device */
}

static device_method_t d3t_methods[] = {
	DEVMETHOD(device_probe,		d3t_probe),
	DEVMETHOD(device_attach,	d3t_attach),
	DEVMETHOD_END
};

static driver_t d3t_driver = { "d3t", d3t_methods, 0 };
DRIVER_MODULE(d3t, pci, d3t_driver, NULL, NULL);
