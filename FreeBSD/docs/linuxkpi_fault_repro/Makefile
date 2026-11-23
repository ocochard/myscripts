KMOD=	lkpi_fault
SRCS=	lkpi_fault.c
SRCS+=	bus_if.h device_if.h pci_if.h vnode_if.h

SYSDIR?=	/usr/src/sys
CFLAGS+=	-I${SYSDIR}/compat/linuxkpi/common/include
CFLAGS+=	-I${SYSDIR}/compat/linuxkpi/dummy/include

.include <bsd.kmod.mk>
