# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a customized Linux 5.0 kernel for the "Running Linux Kernel" (奔跑吧Linux内核) book series. It's an educational platform designed for learning Linux kernel internals with ARM64 architecture support, QEMU virtualization, and comprehensive debugging tools.

Key features:
- Compiled with GCC -O0 optimization for easier debugging (prevents `<optimized out>` in GDB)
- ARM64 (aarch64) architecture focus with QEMU support
- Debian-based root filesystem for rich tooling (kdump, crash, systemtap)
- GDB single-step debugging support
- ftrace and kernel boot tracing tools
- Livepatch support for ARM64
- Host-VM file sharing via 9P filesystem

## Build System

### Environment Setup

The kernel uses cross-compilation for ARM64:
```bash
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
```

### Core Build Commands

**Configure kernel:**
```bash
./run_debian_arm64.sh menuconfig
```

**Build kernel (first time or after config changes):**
```bash
./run_debian_arm64.sh build_kernel
```
This compiles the kernel using `debian_defconfig` and creates `arch/arm64/boot/Image`.

**Build root filesystem (requires sudo):**
```bash
sudo ./run_debian_arm64.sh build_rootfs
```
Creates a 2GB ext4 image at `rootfs_debian_arm64.ext4`.

**Update root filesystem after kernel changes (requires sudo):**
```bash
sudo ./run_debian_arm64.sh update_rootfs
```
Updates kernel modules and headers in the existing rootfs without rebuilding from scratch.

**Run the system:**
```bash
./run_debian_arm64.sh run
```
Launches QEMU with the compiled kernel. Login: `benshushu` / Password: `123`

**Run with GDB debugging:**
```bash
./run_debian_arm64.sh run debug
```
Starts QEMU with `-s -S` flags, waiting for GDB connection on port 1234.

### Alternative Architectures

The project also supports RISC-V and x86_64:
- `./run_debian_riscv.sh` - RISC-V architecture
- `./run_debian_x86_64.sh` - x86_64 architecture

### BusyBox Environment

For lightweight experiments (faster boot, minimal userspace), a BusyBox-based
rootfs is available via `./run_busybox.sh`:

```bash
./run_busybox.sh arm64          # BusyBox on ARM64 virt (default)
./run_busybox.sh arm64 debug    # enable GDB stub (-s -S) on :1234
./run_busybox.sh arm64_pci      # ARM64 with PCIe devices (edu + NVMe) for pci_lab
./run_busybox.sh x86_64         # BusyBox on x86_64
./run_busybox.sh arm32          # BusyBox on ARM vexpress-a9
```

The `arm64_pci` mode additionally attaches:
- QEMU `edu` device — teaching PCI device (`vendor:device = 1234:11e8`) exposing
  an MMIO BAR0 with identification / liveness / factorial / IRQ / DMA registers
- QEMU `nvme` device — a real PCIe NVMe controller behind a `pcie-root-port`
  (backed by `nvme_disk.img`, auto-created on first run)

The BusyBox rootfs is very minimal (no gcc/make); cross-compile kernel modules
on the host and share them into the VM over 9P (see the PCIe lab below).

### Manual Kernel Build

If you need to build manually:
```bash
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
make debian_defconfig
make -j$(nproc)
```

## Kernel Module Development

### Lab Structure

Experimental code is organized under `kmodules/`:
- `rlk_lab/rlk_basic/` - Basic experiments (入门篇 - Beginner's Guide)
- `rlk_lab/rlk_senior/` - Advanced experiments (卷1和卷2 - Volumes 1 & 2)
- `pci_lab/` - Progressive PCI/PCIe driver labs (see below)

### Building Kernel Modules

**On the host (cross-compile):**
```bash
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
cd samples/livepatch/
make CONFIG_SAMPLE_LIVEPATCH=m -C ../../ M=$(pwd) modules
```

**Inside QEMU VM:**
```bash
# First install build tools
apt install build-essential

# Build module
cd /mnt/your_module/
make

# Load module
insmod your_module.ko
```

The Makefile in modules should use:
```makefile
BASEINCLUDE ?= /lib/modules/$(shell uname -r)/build
```

### File Sharing Between Host and VM

The `kmodules/` directory is automatically shared with the VM at `/mnt/`:
```bash
# On host
cp my_module.c kmodules/

# In QEMU VM
ls /mnt/
cd /mnt/
```

This uses 9P filesystem (NET_9P) for seamless file sharing.

## Debugging

### GDB Debugging

**Terminal 1 - Start QEMU in debug mode:**
```bash
./run_debian_arm64.sh run debug
```

**Terminal 2 - Connect GDB:**
```bash
cd /home/doula/project/runninglinuxkernel_5.0
aarch64-linux-gnu-gdb vmlinux
(gdb) target remote :1234
(gdb) break start_kernel
(gdb) continue
(gdb) backtrace
(gdb) step
```

The kernel is compiled with -O0, so GDB stepping works properly without jumping around or showing `<optimized out>`.

### Kernel Boot Tracing

The project includes custom tools for tracing kernel boot process using ftrace.

**Quick start:**
```bash
./quick_start.sh
# In QEMU console:
/trace_boot_init.sh
# View results:
cat /tmp/boot_trace_full.txt | less
```

**Manual tracing workflow:**
```bash
# 1. Setup environment
./trace_kernel_boot.sh setup

# 2. Start QEMU with ftrace enabled
./trace_kernel_boot.sh ftrace

# 3. Inside QEMU, run the trace script
/trace_boot_init.sh

# 4. View results
cat /tmp/boot_trace_key_functions.txt
cat /tmp/boot_trace_stat.txt
```

**Trace specific functions:**
```bash
./trace_kernel_boot.sh ftrace function_graph "start_kernel,kernel_init"
```

**Increase trace buffer:**
```bash
./trace_kernel_boot.sh ftrace function_graph "" 20M
```

See `TRACE_KERNEL_BOOT_README.md` for detailed documentation.

### Livepatch Support

ARM64 livepatch is supported for hot-patching running kernel:

```bash
# Build livepatch module
cd samples/livepatch/
make CONFIG_SAMPLE_LIVEPATCH=m -C ../../ M=$(pwd) modules

# Copy to shared directory
cp *.ko ../../kmodules/

# In QEMU, load the patch
insmod /mnt/livepatch_sample.ko

# Verify patch is active
cat /proc/cmdline  # Should show patched output

# Disable patch
echo 0 > /sys/kernel/livepatch/livepatch_sample/enabled
```

## Architecture

### Key Boot Flow

```
primary_entry (arch/arm64/kernel/head.S)
  └─ __primary_switched
      └─ start_kernel (init/main.c)
          ├─ setup_arch()          # Architecture-specific setup
          │   ├─ setup_machine_fdt()
          │   ├─ paging_init()
          │   └─ bootmem_init()
          ├─ mm_init()             # Memory management
          │   ├─ mem_init()
          │   ├─ kmem_cache_init()
          │   └─ vmalloc_init()
          ├─ sched_init()          # Scheduler
          ├─ init_IRQ()            # Interrupts
          ├─ time_init()           # Timers
          ├─ console_init()        # Console
          └─ rest_init()
              └─ kernel_thread(kernel_init)
                  └─ kernel_init()
                      └─ kernel_init_freeable()
                          ├─ do_basic_setup()
                          │   └─ do_initcalls()
                          └─ run_init_process()
```

### Directory Structure

- `arch/arm64/` - ARM64 architecture-specific code
- `kernel/` - Core kernel subsystems (scheduler, locking, etc.)
- `mm/` - Memory management
- `fs/` - Filesystems
- `drivers/` - Device drivers
- `net/` - Network stack
- `kmodules/rlk_lab/` - Book experiments and examples
- `boot-wrapper-aarch64/` - ARM64 boot wrapper
- `_install_arm64/` - Installed kernel modules and files

### Important Configuration

The kernel uses `arch/arm64/configs/debian_defconfig` as the base configuration.

Key enabled features:
- `CONFIG_FTRACE=y` - Function tracing
- `CONFIG_FUNCTION_TRACER=y`
- `CONFIG_FUNCTION_GRAPH_TRACER=y`
- `CONFIG_DYNAMIC_FTRACE=y`
- `CONFIG_STACKTRACE=y`
- `CONFIG_KPROBES=y`
- `CONFIG_LIVEPATCH=y` - Kernel live patching

## QEMU Operations

### Running the System

Default QEMU configuration:
- 4 vCPUs (`-smp 4`)
- VirtIO network (NAT, IP: 10.0.2.15)
- VirtIO block device for rootfs
- Serial console

### Inside QEMU

**Exit QEMU:**
- Press `Ctrl+A` then `X`
- Or type `poweroff`

**Network access:**
```bash
ifconfig  # Check network (enp0s1: 10.0.2.15)
apt update
apt install <package>
```

**Update system time if needed:**
```bash
date -s 2026-03-21
```

### Shared Filesystem

The `/mnt` directory in QEMU is shared with `kmodules/` on the host:
```bash
# In QEMU
cd /mnt
ls  # Shows contents of host's kmodules/ directory
```

## Common Tasks

### After Modifying Kernel Code

```bash
./run_debian_arm64.sh build_kernel
sudo ./run_debian_arm64.sh update_rootfs
./run_debian_arm64.sh run
```

### After Modifying Kernel Config

```bash
./run_debian_arm64.sh menuconfig  # Make changes
./run_debian_arm64.sh build_kernel
sudo ./run_debian_arm64.sh update_rootfs
./run_debian_arm64.sh run
```

### Developing a New Kernel Module

```bash
# 1. Create module in kmodules/
mkdir kmodules/my_module
cd kmodules/my_module
# Create .c file and Makefile

# 2. Start QEMU
./run_debian_arm64.sh run

# 3. In QEMU, build and test
cd /mnt/my_module
make
insmod my_module.ko
dmesg | tail
rmmod my_module
```

### Debugging a Kernel Panic

```bash
# 1. Enable crashkernel (already configured)
# 2. Trigger panic or wait for crash
# 3. System will save vmcore
# 4. Use crash tool to analyze
apt install crash kexec-tools
crash /usr/lib/debug/boot/vmlinux-5.0.0+ /var/crash/vmcore
```

## Important Notes

### Compilation Optimization

This kernel is compiled with `-O0` (no optimization) to facilitate debugging. This means:
- GDB works properly without jumping around
- Variables can be inspected (no `<optimized out>`)
- Performance is significantly reduced
- Binary size is larger

**Do not use this kernel for production or performance testing.**

### Root Filesystem

The Debian rootfs is large (2GB) and contains:
- Full Debian userspace
- Development tools (gcc, make, etc.)
- Debugging tools (gdb, crash, systemtap)
- Network utilities

Building rootfs requires sudo because it needs to:
- Create loop devices
- Mount filesystems
- Install kernel modules

### Disk Space Requirements

Ensure at least 10GB free space:
- Kernel source: ~1GB
- Build artifacts: ~2GB
- Root filesystem: 2GB
- Temporary files: ~2GB

## Troubleshooting

### Build fails with missing cross-compiler

```bash
sudo apt install gcc-aarch64-linux-gnu
```

### QEMU won't start

Check that kernel image exists:
```bash
ls -lh arch/arm64/boot/Image
```

If missing, rebuild:
```bash
./run_debian_arm64.sh build_kernel
```

### GDB can't connect

Ensure QEMU is started in debug mode:
```bash
./run_debian_arm64.sh run debug
```

Check GDB is the ARM64 version:
```bash
which aarch64-linux-gnu-gdb
```

### apt update fails in QEMU

Update system time:
```bash
date -s 2026-03-21
```

Fix GPG keys if needed:
```bash
apt-key adv --keyserver pgp.mit.edu --recv-keys <KEY_ID>
```

### Trace data is empty

Verify ftrace is enabled:
```bash
grep CONFIG_FTRACE .config
```

Manually enable tracing in QEMU:
```bash
mount -t tracefs none /sys/kernel/tracing
echo function_graph > /sys/kernel/tracing/current_tracer
echo 1 > /sys/kernel/tracing/tracing_on
```

### Module won't load

Check kernel version match:
```bash
uname -r
modinfo your_module.ko
```

Ensure module was built against correct kernel headers.
