// Kleine Kompatibilitätsschicht für HDA-Header-Pfade quer über Distros.
// Einbinden in patch_cs8409.h statt der direkten hda_*.h-Includes.

#pragma once
#include <linux/version.h>

/* __has_include ist in neueren GCC/Clang verfügbar; fallback unten */
#ifndef __has_include
  #define __has_include(x) 0
#endif

/* hda_local.h */
#if __has_include(<sound/pci/hda/hda_local.h>)
  #include <sound/pci/hda/hda_local.h>
#else
  #include "hda_local.h"
#endif

/* hda_codec.h */
#if __has_include(<sound/pci/hda/hda_codec.h>)
  #include <sound/pci/hda/hda_codec.h>
#else
  #include "hda_codec.h"
#endif

/* hda_jack.h */
#if __has_include(<sound/pci/hda/hda_jack.h>)
  #include <sound/pci/hda/hda_jack.h>
#else
  #include "hda_jack.h"
#endif

/* hda_auto_parser.h */
#if __has_include(<sound/pci/hda/hda_auto_parser.h>)
  #include <sound/pci/hda/hda_auto_parser.h>
#else
  #include "hda_auto_parser.h"
#endif

/* hda_bind.h */
#if __has_include(<sound/pci/hda/hda_bind.h>)
  #include <sound/pci/hda/hda_bind.h>
#else
  #include "hda_bind.h"
#endif

/* hda_generic.h */
#if __has_include(<sound/pci/hda/hda_generic.h>)
  #include <sound/pci/hda/hda_generic.h>
#else
  #include "hda_generic.h"
#endif

/* Falls künftig kleine API-Deltas auftauchen, kann man hier
   #define- oder Inline-Kompat-Adapter unterbringen. */
