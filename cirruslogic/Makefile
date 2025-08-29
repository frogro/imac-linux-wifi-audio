KDIR ?= /lib/modules/$(shell uname -r)/build

# Zusätzliche Include-Pfade helfen Tooling & edge-cases
EXTRA_CFLAGS += -I$(KDIR)/sound/pci/hda -I$(KDIR)/include -I$(KDIR)/include/uapi

obj-m := snd-hda-codec-cs8409.o
snd-hda-codec-cs8409-objs := patch_cs8409.o

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
