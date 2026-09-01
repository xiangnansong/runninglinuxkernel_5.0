BASEINCLUDE ?= /lib/modules/$(shell uname -r)/build

CONFIG_MODULE_SIG := n

obj-m := pci_scan.o

all:
	$(MAKE) -C $(BASEINCLUDE) M=$(PWD) modules

clean:
	$(MAKE) -C $(BASEINCLUDE) M=$(PWD) clean
	rm -f *.ko
