/* portable, doppelt-sicher */
#if defined(__has_include)
  #if __has_include(<sound/pci/hda/hda_local.h>)
    #include <sound/pci/hda/hda_local.h>
  #elif __has_include("hda_local.h")
    #include "hda_local.h"
  #else
    #error "hda_local.h nicht gefunden – Kernel-Header (sound/pci/hda) fehlen?"
  #endif
#else
  /* sehr alte Compiler: best-effort */
  #include <sound/pci/hda/hda_local.h>
#endif
