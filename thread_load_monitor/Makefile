obj-m += cpuloading_monitor.o

KDIR := /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

install:
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install

help:
	@echo "Available targets:"
	@echo "  all     - Build the kernel module"
	@echo "  clean   - Clean build files"
	@echo "  install - Install the module"
	@echo ""
	@echo "Usage:"
	@echo "  1. Build:  make"
	@echo "  2. Load:   sudo insmod cpuloading_monitor.ko"
	@echo "  3. Unload: sudo rmmod cpuloading_monitor"
	@echo ""
	@echo "Module parameters:"
	@echo "  sample_interval_ms - Sampling interval in ms (default: 1000)"
	@echo "  monitor_pid        - PID to monitor, -1 for all (default: -1)"
	@echo "  max_records        - Max records to keep (default: 100000)"
	@echo ""
	@echo "Example:"
	@echo "  sudo insmod cpuloading_monitor.ko sample_interval_ms=500 monitor_pid=1234"
