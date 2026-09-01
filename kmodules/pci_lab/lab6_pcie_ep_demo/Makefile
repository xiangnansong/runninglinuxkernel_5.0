BASEINCLUDE ?= /lib/modules/$(shell uname -r)/build

obj-m := pcie_ep_demo.o

all:
	$(MAKE) -C $(BASEINCLUDE) M=$(PWD) modules

clean:
	$(MAKE) -C $(BASEINCLUDE) M=$(PWD) clean
	rm -f *.ko *.o *.mod *.mod.c .*.cmd modules.order Module.symvers
