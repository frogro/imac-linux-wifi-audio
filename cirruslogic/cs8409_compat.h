/* cs8409_compat.h
 *
 * Zentrale Kompatibilitäts-Includes für HDA/ALSA-Header.
 * Nutzt __has_include (gcc) um die passenden Kernel-Header-Pfade
 * je nach Distribution/Kernellayout zu finden.
 *
 * Einbinden: einfach NUR diese Datei in deinen .c/.h verwenden:
 *   #include "cs8409_compat.h"
 */

#ifndef CS8409_COMPAT_H
#define CS8409_COMPAT_H

/* __has_include ist bei aktuellen gcc/clang verfügbar */
#ifndef __has_include
  #define __has_include(x) 0
#endif

/* Häufigster Fall (Debian/Ubuntu/Fedora/Arch neuere Kernel):
 * Header liegen unter sound/pci/hda/
 */
#if __has_include(<sound/pci/hda/hda_local.h>)
  #include <sound/pci/hda/hda_local.h>
  #include <sound/pci/hda/hda_codec.h>
  #include <sound/pci/hda/hda_jack.h>
  #include <sound/pci/hda/hda_auto_parser.h>
  #include <sound/pci/hda/hda_bind.h>
  #include <sound/pci/hda/hda_generic.h>

/* Manche ältere Bäume nutzten sound/ statt sound/pci/hda/ */
#elif __has_include(<sound/hda_local.h>)
  #include <sound/hda_local.h>
  #include <sound/hda_codec.h>
  #include <sound/hda_jack.h>
  #include <sound/hda_auto_parser.h>
  #include <sound/hda_bind.h>
  #include <sound/hda_generic.h>

/* Fallback: In-Tree-Builds (oder wenn der Treiber im Kernelbaum liegt) */
#elif __has_include("hda_local.h")
  #include "hda_local.h"
  #include "hda_codec.h"
  #include "hda_jack.h"
  #include "hda_auto_parser.h"
  #include "hda_bind.h"
  #include "hda_generic.h"

#else
  #error "Kein passender Pfad für HDA-Header gefunden. Prüfe Kernel-Header-Installation."
#endif

#endif /* CS8409_COMPAT_H */
