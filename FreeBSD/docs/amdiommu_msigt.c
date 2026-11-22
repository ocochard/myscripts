/*
 * msigt: allocate and release a multiple-message MSI group on an unused
 * device many times: AMD Strix Halo USB4 host router (1022:158d function
 * 5, 16 messages) or Intel Meteor Lake xhci1 (8086:7e7d, 8 messages).
 * Interrupt handlers are set up so the IOMMU remapping entries are
 * programmed; the MSI data of the first message (the IRTE index under
 * interrupt remapping) is printed to check its alignment.
 */
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/bus.h>
#include <sys/kernel.h>
#include <sys/module.h>
#include <sys/rman.h>
#include <machine/bus.h>
#include <machine/resource.h>
#include <dev/pci/pcireg.h>
#include <dev/pci/pcivar.h>

#define	MSIGT_COUNT	16
#define	MSIGT_CYCLES	64

static int
msigt_probe(device_t dev)
{
	if (!(pci_get_vendor(dev) == 0x1022 && pci_get_device(dev) == 0x158d &&
	    pci_get_function(dev) == 5) &&
	    !(pci_get_vendor(dev) == 0x8086 && pci_get_device(dev) == 0x7e7d))
		return (ENXIO);
	device_set_desc(dev, "MSI group test");
	return (BUS_PROBE_DEFAULT);
}

static void
msigt_intr(void *arg)
{
}

static int
msigt_attach(device_t dev)
{
	struct resource *irq[MSIGT_COUNT];
	void *cookie[MSIGT_COUNT];
	int count, cyc, i, ptr, rid, want, ok = 0, bad = 0;
	uint16_t data;

	if (pci_find_cap(dev, PCIY_MSI, &ptr) != 0)
		return (ENXIO);
	for (cyc = 0; cyc < MSIGT_CYCLES; cyc++) {
		want = MIN(MSIGT_COUNT, pci_msi_count(dev));
		count = want;
		if (pci_alloc_msi(dev, &count) != 0 || count != want) {
			device_printf(dev, "cycle %d: pci_alloc_msi failed "
			    "(count %d)\n", cyc, count);
			if (count > 0)
				pci_release_msi(dev);
			break;
		}
		for (i = 0; i < count; i++) {
			rid = i + 1;
			irq[i] = bus_alloc_resource_any(dev, SYS_RES_IRQ, &rid,
			    RF_ACTIVE);
			cookie[i] = NULL;
			if (irq[i] != NULL)
				bus_setup_intr(dev, irq[i], INTR_TYPE_MISC |
				    INTR_MPSAFE, NULL, msigt_intr, NULL,
				    &cookie[i]);
		}
		data = pci_read_config(dev, ptr + PCIR_MSI_DATA_64BIT, 2);
		if (cyc < 3 || cyc == MSIGT_CYCLES - 1)
			device_printf(dev, "cycle %d: %d messages, MSI data "
			    "0x%x (%s on %d)\n", cyc, count, data,
			    data % count == 0 ? "aligned" : "NOT aligned",
			    count);
		if (data % count != 0)
			bad++;
		for (i = 0; i < count; i++) {
			if (cookie[i] != NULL)
				bus_teardown_intr(dev, irq[i], cookie[i]);
			if (irq[i] != NULL)
				bus_release_resource(dev, SYS_RES_IRQ, i + 1,
				    irq[i]);
		}
		pci_release_msi(dev);
		ok++;
	}
	device_printf(dev, "%d/%d cycles of %d messages, %d misaligned\n",
	    ok, MSIGT_CYCLES, MIN(MSIGT_COUNT, pci_msi_count(dev)), bad);
	return (0);
}

static int
msigt_detach(device_t dev)
{
	return (0);
}

static device_method_t msigt_methods[] = {
	DEVMETHOD(device_probe,		msigt_probe),
	DEVMETHOD(device_attach,	msigt_attach),
	DEVMETHOD(device_detach,	msigt_detach),
	DEVMETHOD_END
};
static driver_t msigt_driver = { "msigt", msigt_methods, 0 };
DRIVER_MODULE(msigt, pci, msigt_driver, NULL, NULL);
