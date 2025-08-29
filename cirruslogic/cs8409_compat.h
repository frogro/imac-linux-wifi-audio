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

/* Gemeinsame ALSA/Kern-Header – harmlos, falls ungenutzt */
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

/* Preferred: neue Kernelpfade */
#if __has_include(<sound/pci/hda/hda_local.h>)
  #include <sound/hda_codec.h>
  #include <sound/hda_register.h>
  #include <sound/hda_verbs.h>
  #include <sound/pci/hda/hda_local.h>
  #include <sound/pci/hda/hda_generic.h>
  #include <sound/pci/hda/hda_auto_parser.h>
  #include <sound/pci/hda/hda_jack.h>
  #include <sound/pci/hda/hda_bind.h>

/* Ältere Layouts */
#elif __has_include(<sound/hda_local.h>)
  #include <sound/hda_codec.h>
  #include <sound/hda_register.h>
  #include <sound/hda_verbs.h>
  #include <sound/hda_local.h>
  #include <sound/hda_generic.h>
  #include <sound/hda_auto_parser.h>
  #include <sound/hda_jack.h>
  #include <sound/hda_bind.h>

/* In-tree Fallback */
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
  #error "Kein passender Pfad für HDA-Header gefunden (hda_local.h). Kernel-Header installieren."
#endif

/* Sanfte Kompat-Makros (schaden nicht, falls bereits definiert) */
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
