# 1) Umbenannte Feldnamen in neueren Codebasen
s/\blinein_jack_in\b/mic_jack_in/g
s/\blineout_jack_in\b/hp_jack_in/g

# 2) Einige Treiber variieren bei include-Reihenfolge – sicherstellen, dass linux/version.h vorhanden ist
/$include <linux\/module.h>/,/^$/ {
  /linux\/version.h/! s/^#include <linux\/module.h>/#include <linux\/module.h>\n#include <linux\/version.h>/
}

# 3) Alte Helper-Namen, die in Upstream-Kerneln zusammengelegt wurden (harmlos, nur falls vorhanden)
s/\bhda_nid_t\b/u16/g
