# 🖥️ iMac Linux WiFi + Audio 
Dieses Repository stellt ein **Installationsskript** bereit, mit dem auf **Intel iMacs (T2 Generation)** unter **Linux** 

- **WLAN (Broadcom BCM4364)** (`brcmfmac4364b2/b3-pcie`) und
- **Audio (Cirrus Logic CS8409)** (ALC layout, DKMS-Modul)

eingerichtet werden kann. 

⚠️ Getestet ausschließlich mit **Debian 13 (trixie)**. Andere Linux-Distros/Versionen können funktionieren, sind aber nicht Teil dieses How-Tos.

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
Sodann kannst du auswählen, WLAN und Audio, nur WLAN oder nur Audio zu installieren.

Das Skript:

- installiert benötigte Pakete (curl, dkms, headers, pipewire, …),
- kopiert die passenden WLAN-Firmware-Einträge nach /lib/firmware/brcm/,
- baut & installiert das Audio-DKMS-Modul,
- schreibt ein Manifest nach /var/lib/imac-linux-wifi-audio/manifest.txt.

4. Reboot

🔧 **Deinstallation**

Lade das Deinstallationsskript herunter:

```bash
     wget https://raw.githubusercontent.com/frogro/imac-linux-wifi-audio/main/uninstall.sh
```

Du kannst wählen, welche Komponenten entfernt werden sollen:

```bash
     sudo ./uninstall.sh           # entfernt WLAN + Audio
     sudo ./uninstall.sh --wifi    # nur WLAN-Dateien
     sudo ./uninstall.sh --audio   # nur DKMS-Audio   
```

ℹ️ **Hinweise**

**WLAN:**
Die benötigte BCM4364-Firmware stammt aus dem Github-Release <a href="https://github.com/reynaldliu/macbook16-1-wifi-bcm4364-binary" target="_blank">macbook16-1-wifi-bcm4364-binary</a> von ReynaldLiu. Beide Varianten (b2 und b3) werden installiert, der Kernel nutzt die richtige automatisch.

**Audio:**
Das CS8409-Modul stammt aus dem GitHub-Release <a href="https://github.com/egorenar/snd-hda-codec-cs8409" target="_blank">snd-hda-codec-cs8409</a> von Alexander Egorenkov. Es wird via DKMS gebaut. Dadurch wird das Modul bei einem Kernel-Update automatisch neu gebaut. Nutze ```bash sudo dkms status```, um die korrekte Einbindung des CS8409-Moduls zu prüfen. Das Skript aktiviert PipeWire (pipewire-pulse, wireplumber), installiert pavucontrol und weitere Abhängigkeiten (build-essential, dkms, pipewire).

ℹ️ **Troubelshooting**
- **DKMS-Build schlägt fehl:** Log prüfen

```bash
     sudo tail -n +1 /var/lib/dkms/snd-hda-codec-cs8409/1.0/build/make.log
```
- **WLAN lädt nicht:**
     Kernel & Headers passend (```bash uname -r, apt install linux-headers-$(uname -r)```)?
     dmesg | grep brcmfmac
  
- **kein Audio**: Ausgabegerät in den Einstellungen > Audio festgelegt?

📜 **Lizenz**

- **Skripte, DKMS Setup & Doku:** MIT License
- **Audio-Treiber (CS8409):** GPLv2 (basierend auf [egorenar/snd-hda-codec-cs8409](https://github.com/egorenar/snd-hda-codec-cs8409))
- **WLAN-Firmware:** proprietär (Broadcom/Apple), siehe [FIRMWARE-NOTICE](./FIRMWARE-NOTICE) (basierend auf [reynaldliu/macbook16-1-wifi-bcm4364-binary](https://github.com/reynaldliu/macbook16-1-wifi-bcm4364-binary))

🚀 **Credits**

BCM4364 Binary Firmware: reynaldliu, CS8409 Driver: egorenar
