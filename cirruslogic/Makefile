# Simple Kbuild wrapper for DKMS
KDIR ?= /lib/modules/$(shell uname -r)/build

obj-m := snd-hda-codec-cs8409.o
snd-hda-codec-cs8409-objs := patch_cs8409.o

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
