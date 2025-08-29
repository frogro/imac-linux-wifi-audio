/* cs8409_compat.h
 *
 * Sorgt dafür, dass HDA/ALSA-Header auf verschiedenen Distros/Kernels
 * gefunden werden (Debian/Ubuntu/Arch/Fedora etc.).
 * Idee: Zuerst Kernel-Tree-Pfade versuchen (<sound/pci/hda/...>), dann
 * lokale Kopien im Treiberbaum ("hda_local.h", ...).
 */

#ifndef CS8409_COMPAT_H
#define CS8409_COMPAT_H

/* Für __has_include bei GCC/Clang */
#ifndef __has_include
  #define __has_include(x) 0
#endif

/* Hilfsmakro: probiert bis zu 4 Pfade der Reihe nach. */
#define TRY_INCLUDE4(H1,H2,H3,H4) \
  _Pragma("GCC diagnostic push") \
  _Pragma("GCC diagnostic ignored \"-Wpragma\"") \
  _Pragma("GCC diagnostic ignored \"-Wunknown-pragmas\"") \
  /* 1 */ \
  #if __has_include(H1) \
    #include H1 \
  /* 2 */ \
  #elif __has_include(H2) \
    #include H2 \
  /* 3 */ \
  #elif __has_include(H3) \
    #include H3 \
  /* 4 */ \
  #elif __has_include(H4) \
    #include H4 \
  /* nix gefunden */ \
  #else \
    _Pragma("GCC error \"Header not found: " #H1 " / " #H2 " / " #H3 " / " #H4 "\"") \
  #endif \
  _Pragma("GCC diagnostic pop")

/* Manche Distros shiften zwischen sound/pci/hda und sound/hda ab und zu herum. */
#define INC_HDA_LOCAL()       TRY_INCLUDE4(<sound/pci/hda/hda_local.h>,       "hda_local.h",       <sound/hda/hda_local.h>,       "include/sound/pci/hda/hda_local.h")
#define INC_HDA_CODEC()       TRY_INCLUDE4(<sound/pci/hda/hda_codec.h>,       "hda_codec.h",       <sound/hda/hda_codec.h>,       "include/sound/pci/hda/hda_codec.h")
#define INC_HDA_JACK()        TRY_INCLUDE4(<sound/pci/hda/hda_jack.h>,        "hda_jack.h",        <sound/hda/hda_jack.h>,        "include/sound/pci/hda/hda_jack.h")
#define INC_HDA_AUTO()        TRY_INCLUDE4(<sound/pci/hda/hda_auto_parser.h>, "hda_auto_parser.h", <sound/hda/hda_auto_parser.h>, "include/sound/pci/hda/hda_auto_parser.h")
#define INC_HDA_BIND()        TRY_INCLUDE4(<sound/pci/hda/hda_bind.h>,        "hda_bind.h",        <sound/hda/hda_bind.h>,        "include/sound/pci/hda/hda_bind.h")
#define INC_HDA_GENERIC()     TRY_INCLUDE4(<sound/pci/hda/hda_generic.h>,     "hda_generic.h",     <sound/hda/hda_generic.h>,     "include/sound/pci/hda/hda_generic.h")

/* Übliche Linux/ALSA Kernelsachen zuerst – diese sind stabil. */
#include <linux/module.h>
#include <linux/init.h>
#include <linux/delay.h>
#include <linux/slab.h>
#include <linux/errno.h>
#include <linux/types.h>
#include <linux/version.h>

#include <sound/core.h>
#include <sound/asound.h>
#include <sound/control.h>
#include <sound/tlv.h>
#include <sound/pcm.h>
#include <sound/pcm_params.h>
#include <sound/initval.h>
#include <sound/hda_register.h>

/* Jetzt die wechselhaften HDA-Header portabel einziehen */
INC_HDA_LOCAL()
INC_HDA_CODEC()
INC_HDA_JACK()
INC_HDA_AUTO()
INC_HDA_BIND()
INC_HDA_GENERIC()

#endif /* CS8409_COMPAT_H */
