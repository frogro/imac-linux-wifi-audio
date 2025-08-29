/* cs8409_compat.h – vereinheitlichte Includes für HDA/ALSA Header
 * Funktioniert auf Debian/Ubuntu/Fedora/Arch, Kernel 5.x–6.x
 */
#ifndef CS8409_COMPAT_H
#define CS8409_COMPAT_H

/* Erst normale Linux/Sound-Basis (idR. schon in .c vorhanden) – hier neutral lassen */
/* #include <linux/...>  #include <sound/...>  -> verbleibt in den .c-Dateien */

/* HDA-Header – portable Auflösung */
#if defined(__has_include)
  /* 1) lokaler Header (ältere Out-of-tree Treiber) */
  #if __has_include("hda_local.h")
    #include "hda_local.h"
  /* 2) üblicher Kernel-Pfad */
  #elif __has_include(<sound/pci/hda/hda_local.h>)
    #include <sound/pci/hda/hda_local.h>
  #else
    #error "hda_local.h nicht gefunden – Kernel-Header (linux-headers-$(uname -r)) installieren?"
  #endif

  #if __has_include("hda_codec.h")
    #include "hda_codec.h"
  #elif __has_include(<sound/pci/hda/hda_codec.h>)
    #include <sound/pci/hda/hda_codec.h>
  #endif

  #if __has_include("hda_jack.h")
    #include "hda_jack.h"
  #elif __has_include(<sound/pci/hda/hda_jack.h>)
    #include <sound/pci/hda/hda_jack.h>
  #endif

  #if __has_include("hda_auto_parser.h")
    #include "hda_auto_parser.h"
  #elif __has_include(<sound/pci/hda/hda_auto_parser.h>)
    #include <sound/pci/hda/hda_auto_parser.h>
  #endif

  #if __has_include("hda_generic.h")
    #include "hda_generic.h"
  #elif __has_include(<sound/pci/hda/hda_generic.h>)
    #include <sound/pci/hda/hda_generic.h>
  #endif

  #if __has_include("hda_bind.h")
    #include "hda_bind.h"
  #elif __has_include(<sound/pci/hda/hda_bind.h>)
    #include <sound/pci/hda/hda_bind.h>
  #endif
#else
  /* Fallback ohne __has_include: Standard-Kernelpfad */
  #include <sound/pci/hda/hda_local.h>
  #include <sound/pci/hda/hda_codec.h>
  #include <sound/pci/hda/hda_jack.h>
  #include <sound/pci/hda/hda_auto_parser.h>
  #include <sound/pci/hda/hda_generic.h>
  #include <sound/pci/hda/hda_bind.h>
#endif

#endif /* CS8409_COMPAT_H */
