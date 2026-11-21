/* Test: device_get_property() on the cs35l54 acpi_iicbus child. */
#include <sys/param.h>
#include <sys/kernel.h>
#include <sys/module.h>
#include <sys/bus.h>
#include <contrib/dev/acpica/include/acpi.h>

static int
proptest_modevent(module_t mod, int type, void *arg)
{
	device_t dev;
	const ACPI_OBJECT *obj;
	ssize_t n;
	char buf[8];

	if (type != MOD_LOAD)
		return (type == MOD_UNLOAD ? 0 : EOPNOTSUPP);
	dev = devclass_get_device(devclass_find("cs35l54"), 0);
	if (dev == NULL) {
		printf("proptest: no cs35l540\n");
		return (0);
	}
	printf("proptest: %s parent %s\n", device_get_nameunit(dev),
	    device_get_nameunit(device_get_parent(dev)));
	printf("proptest: has cirrus,dev-index: %d\n",
	    device_has_property(dev, "cirrus,dev-index"));
	n = device_get_property(dev, "cirrus,dev-index", &obj, sizeof(obj),
	    DEVICE_PROP_ANY);
	printf("proptest: get cirrus,dev-index: %zd\n", n);
	if (n == sizeof(obj) && obj->Type == ACPI_TYPE_PACKAGE)
		for (u_int i = 0; i < obj->Package.Count; i++)
			printf("proptest:   [%u] = 0x%jx\n", i,
			    (uintmax_t)obj->Package.Elements[i].Integer.Value);
	printf("proptest: missing property: %zd\n",
	    device_get_property(dev, "no-such-prop", buf, sizeof(buf),
	    DEVICE_PROP_ANY));
	return (0);
}
static moduledata_t proptest_mod = { "proptest", proptest_modevent, NULL };
DECLARE_MODULE(proptest, proptest_mod, SI_SUB_DRIVERS, SI_ORDER_ANY);
