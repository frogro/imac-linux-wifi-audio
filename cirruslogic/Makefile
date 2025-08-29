# Modulname
obj-m += snd-hda-codec-cs8409.o
snd-hda-codec-cs8409-y := patch_cs8409.o

# Kernel-Buildverzeichnis (von DKMS via KVER reingereicht, sonst uname -r)
KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build
PWD  := $(shell pwd)

# Includepfade:
# - eigenes Verzeichnis (für die patch_cirrus_*.h)
# - Header aus dem HDA-Bereich der Kernel-Sourcen
ccflags-y += -I$(PWD) -I$(KDIR)/sound/pci/hda

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
