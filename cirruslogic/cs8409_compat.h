/* cs8409_compat.h
 * Zentrale Kompatibilitäts-Includes für HDA/ALSA-Header.
 * Einbinden: nur diese Datei in .c/.h verwenden:
 *   #include "cs8409_compat.h"
 */
#ifndef CS8409_COMPAT_H
#define CS8409_COMPAT_H

#ifndef __has_include
#  define __has_include(x) 0
#endif

/* --- generische Kernel/ALSA-Basisheader (unschädlich, falls ungenutzt) --- */
#include <linux/module.h>
#include <linux/init.h>
#include <linux/delay.h>
#include <linux/slab.h>
#include <linux/mutex.h>
#include <linux/pm.h>
#include <linux/types.h>
#include <sound/core.h>
#include <sound/asound.h>
#include <sound/asoundef.h>

/*
 * Preferred (neuere Kernel in Debian/Ubuntu/Fedora/Arch):
 * - hda_local.h & Co. liegen unter sound/pci/hda/
 * - die API-Header (hda_codec.h, hda_register.h, hda_verbs.h) liegen unter include/sound/
 */
#if __has_include(<sound/pci/hda/hda_local.h>)
  /* Top-Level ALSA/HDA API */
  #include <sound/hda_codec.h>
  #include <sound/hda_register.h>
  #include <sound/hda_verbs.h>
  /* Treiber-interne HDA-Header aus dem HDA-Teilbaum */
  #include <sound/pci/hda/hda_local.h>
  #include <sound/pci/hda/hda_generic.h>
  #include <sound/pci/hda/hda_auto_parser.h>
  #include <sound/pci/hda/hda_jack.h>
  #include <sound/pci/hda/hda_bind.h>

/*
 * Älteres Layout:
 * - alles direkt unter include/sound/ verfügbar
 */
#elif __has_include(<sound/hda_local.h>)
  #include <sound/hda_codec.h>
  #include <sound/hda_register.h>
  #include <sound/hda_verbs.h>
  #include <sound/hda_local.h>
  #include <sound/hda_generic.h>
  #include <sound/hda_auto_parser.h>
  #include <sound/hda_jack.h>
  #include <sound/hda_bind.h>

/*
 * In-tree-Fallback (falls als Teil des Kernelbaums kompiliert und die Dateien
 * relativ im gleichen Verzeichnis liegen)
 */
#elif __has_include("hda_local.h")
  #include "hda_codec.h"
  #include "hda_register.h"
  #include "hda_verbs.h"
  #include "hda_local.h"
  #include "hda_generic.h"
  #include "hda_auto_parser.h"
  #include "hda_jack.h"
  #include "hda_bind.h"

#else
  #error "Kein passender Pfad für HDA-Header gefunden (hda_local.h). Bitte Kernel-Header installieren."
#endif

/* --- sanfte Kompat-Defines (tun nichts, wenn Kernel sie schon mitbringt) --- */
#ifndef HDA_FIXUP_ACT_PRE_PROBE
#define HDA_FIXUP_ACT_PRE_PROBE 0
#endif
#ifndef HDA_FIXUP_ACT_PROBE
#define HDA_FIXUP_ACT_PROBE 1
#endif
#ifndef HDA_FIXUP_ACT_INIT
#define HDA_FIXUP_ACT_INIT 2
#endif
#ifndef HDA_FIXUP_ACT_BUILD
#define HDA_FIXUP_ACT_BUILD 3
#endif

#ifndef codec_err
#define codec_err(c, fmt, ...)  dev_err((c)->dev, fmt, ##__VA_ARGS__)
#endif
#ifndef codec_warn
#define codec_warn(c, fmt, ...) dev_warn((c)->dev, fmt, ##__VA_ARGS__)
#endif
#ifndef codec_dbg
#define codec_dbg(c, fmt, ...)  dev_dbg((c)->dev, fmt, ##__VA_ARGS__)
#endif
#ifndef codec_info
#define codec_info(c, fmt, ...) dev_info((c)->dev, fmt, ##__VA_ARGS__)
#endif

#endif /* CS8409_COMPAT_H */
