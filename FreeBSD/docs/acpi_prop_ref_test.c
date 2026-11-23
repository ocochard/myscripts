/*
 * acpi_prop_ref_test: on load, ask acpi_ad_get_property() for a _DSD
 * property whose value is a bare reference to \_SB_, from a synthetic
 * _DSD package, with DEVICE_PROP_ANY and DEVICE_PROP_HANDLE.  The
 * returned value must be the handle of \_SB_ itself.
 */
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/bus.h>
#include <sys/kernel.h>
#include <sys/module.h>

#include <contrib/dev/acpica/include/acpi.h>
#include <dev/acpica/acpivar.h>

static int
refprop_test(void)
{
	static char name[] = "test-ref";
	ACPI_OBJECT elems[2], pair, top, hpkg, hpair[2], hpairpkg, top2;
	ACPI_OBJECT tops[2];
	struct acpi_device ad;
	ACPI_HANDLE sb, h;
	ssize_t len;

	if (ACPI_FAILURE(AcpiGetHandle(NULL, "\\_SB_", &sb))) {
		printf("refprop: no \\_SB_\n");
		return (0);
	}
	bzero(elems, sizeof(elems));
	elems[0].String.Type = ACPI_TYPE_STRING;
	elems[0].String.Length = strlen(name);
	elems[0].String.Pointer = name;
	elems[1].Reference.Type = ACPI_TYPE_LOCAL_REFERENCE;
	elems[1].Reference.ActualType = ACPI_TYPE_DEVICE;
	elems[1].Reference.Handle = sb;
	pair.Package.Type = ACPI_TYPE_PACKAGE;
	pair.Package.Count = 2;
	pair.Package.Elements = elems;

	/* Same property as a one-element package, as DEVICE_PROP_HANDLE wants. */
	bzero(hpair, sizeof(hpair));
	hpkg.Package.Type = ACPI_TYPE_PACKAGE;
	hpkg.Package.Count = 1;
	hpkg.Package.Elements = &elems[1];
	hpair[0] = elems[0];
	hpair[1] = hpkg;
	hpairpkg.Package.Type = ACPI_TYPE_PACKAGE;
	hpairpkg.Package.Count = 2;
	hpairpkg.Package.Elements = hpair;

	tops[0] = pair;
	top.Package.Type = ACPI_TYPE_PACKAGE;
	top.Package.Count = 1;
	top.Package.Elements = tops;
	tops[1] = hpairpkg;
	top2.Package.Type = ACPI_TYPE_PACKAGE;
	top2.Package.Count = 1;
	top2.Package.Elements = &tops[1];

	bzero(&ad, sizeof(ad));
	ad.ad_handle = sb;
	ad.dsd.Pointer = &top;		/* non-NULL: no _DSD evaluation */
	ad.dsd_pkg = &top;
	h = NULL;
	len = acpi_ad_get_property(&ad, name, &h, sizeof(h), DEVICE_PROP_ANY);
	printf("refprop ANY: len %zd, handle %p, \\_SB_ %p: %s\n", len, h, sb,
	    len == sizeof(h) && h == sb ? "PASS" : "FAIL");

	ad.dsd.Pointer = &top2;
	ad.dsd_pkg = &top2;
	h = NULL;
	len = acpi_ad_get_property(&ad, name, &h, sizeof(h),
	    DEVICE_PROP_HANDLE);
	printf("refprop HANDLE: len %zd, handle %p, \\_SB_ %p: %s\n", len, h,
	    sb, len == sizeof(h) && h == sb ? "PASS" : "FAIL");
	return (0);
}

static int
refprop_modevent(module_t mod __unused, int type, void *data __unused)
{
	switch (type) {
	case MOD_LOAD:
		return (refprop_test());
	case MOD_UNLOAD:
		return (0);
	default:
		return (EOPNOTSUPP);
	}
}

static moduledata_t refprop_mod = { "acpi_prop_ref_test", refprop_modevent,
    NULL };
DECLARE_MODULE(acpi_prop_ref_test, refprop_mod, SI_SUB_LAST, SI_ORDER_ANY);
MODULE_DEPEND(acpi_prop_ref_test, acpi, 1, 1, 1);
