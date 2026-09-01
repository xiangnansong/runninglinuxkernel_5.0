# 在宿主机上交叉编译 memhog(静态链接),生成的二进制通过 9p 共享到 VM 的 /mnt
CROSS_COMPILE ?= aarch64-linux-gnu-
CC := $(CROSS_COMPILE)gcc

all: memhog

memhog: memhog.c
	$(CC) -static -O2 -o $@ $<

clean:
	rm -f memhog

.PHONY: all clean
