# Build nur für den Unterordner cirruslogic (wird via dkms.conf mit -C aufgerufen)

# DKMS übergibt KVER=${kernelver}; sonst fallback auf laufenden Kernel
KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build

# HDA/ALSA-Header verfügbar machen
EXTRA_CFLAGS += -I$(KDIR)/sound/pci/hda -I$(KDIR)/include -I$(KDIR)/include/uapi

obj-m := snd-hda-codec-cs8409.o
snd-hda-codec-cs8409-objs := patch_cs8409.o

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
