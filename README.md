# 🖥️ iMac Linux WiFi + Audio 
Dieses Repository stellt ein **Installationsskript** bereit, mit dem auf **Intel iMacs** unter **Linux** 

- **WLAN (Broadcom BCM4364)** (b2/b3 Varianten) und
- **Audio (Cirrus Logic CS8409)**

eingerichtet werden kann. 

⚠️ Getestet ausschließlich mit **Debian 13 (trixie)**. Andere Distros/Versionen können funktionieren, sind aber nicht Teil dieses How-Tos.

✅ **Unterstützte Geräte**

**WLAN (BCM4364)**

| Modell | Jahr      | Panel    | Status       | Hinweise                                         |
| ------ | --------- | -------- | ------------ | ------------------------------------------------ |
| iMac   | Late 2019 | 21.5″ 4K | **Getestet** | b2/b3 automatisch; Firmware per Installer        |
| iMac   | Late 2019 | 24″ 5K   | **Getestet** | b2/b3 automatisch; Firmware per Installer        |
| iMac   | 2017–2020 | diverse  | **Erwartet** | gleiche BCM4364-Familie; bitte Feedback im Issue |

**Audio (CS8409)**

| Modell | Jahr      | Panel    | Status       | Hinweise                                  |
| ------ | --------- | -------- | ------------ | ----------------------------------------- |
| iMac   | Late 2019 | 21.5″ 4K | **Getestet** | CS8409 via DKMS                           |
| iMac   | Late 2019 | 24″ 5K   | **Getestet** | CS8409 via DKMS                           |
| iMac   | 2018      | diverse  | **Erwartet** | vermutlich CS8409; Rückmeldung willkommen |


---

🚀 **Installation**

1. Lade das Installationsskript herunter:
```bash
     wget https://raw.githubusercontent.com/frogro/imac-linux-wifi-audio/main/install.sh
```

2. Mach es ausführbar:
```bash
     chmod +x install.sh
```

3. Führe es mit Root-Rechten aus:
```bash
     sudo ./install.sh
```

4. **Neustarten** – danach sollte WLAN + Audio funktionieren. Ggf. noch das interne HDA-Device in den Einstellungen unter Audio auswählen.

🔧 **Deinstallation**

Falls Änderungen rückgängig gemacht werden sollen:

```bash
     wget https://raw.githubusercontent.com/frogro/imac-linux-wifi-audio/main/uninstall.sh
     chmod +x uninstall.sh
     sudo ./uninstall.sh
```

ℹ️ **Hinweise**

**WLAN:**
Das Skript lädt die benötigte BCM4364-Firmware automatisch aus dem Release von reynaldliu/macbook16-1-wifi-bcm4364-binary. Beide Varianten (b2 und b3) werden installiert, der Kernel nutzt die richtige automatisch.

**Audio:**
Das CS8409-Modul wird via DKMS gebaut (Quellen von egorenar/snd-hda-codec-cs8409). Dadurch wird das Modul bei einem Kernel-Updates automatisch neu gebaut. Nutze ```bash sudo dkms status```, um die korrekte Einbindung des CS8409-Moduls zu prüfen. Das Skript aktiviert PipeWire (pipewire-pulse, wireplumber), installiert pavucontrol und weitere Abhängigkeiten (build-essential, dkms, pipewire).

📜 **Rechtliches / Lizenz** 

- **WLAN-Firmware** wird **nicht** verteilt. Das Installationsskript lädt sie aus dem Release von **reynaldliu/macbook16-1-wifi-bcm4364-binary** herunter.
- **CS8409-Quellen** stammen von **egorenar/snd-hda-codec-cs8409** und werden beim Installieren geladen.
- Dieses Repo (Skripte/Packaging) steht unter **MIT-Lizenz** (siehe LICENSE).
- Nutzung auf eigene Verantwortung; keine Garantie.

🚀 **Credits**

BCM4364 Binary Firmware: reynaldliu
CS8409 Driver: egorenar
