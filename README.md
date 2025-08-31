# 🖥️ iMac Linux WiFi + Audio 
Viele **iMacs sowie MacBooks** laufen super flott mit Linux, aber Sound und WLAN funktionieren nach der Installation nicht sofort. Hier findest du eine **Schritt-für-Schritt-Anleitung**, wie du beides aktivierst. 

In diesem **HowTo** geht es ausschließlich um Geräte mit

- **Broadcom BCM4364 WLAN-Chipsatz** (brcmfmac4364b2/b3-pcie) und
- **Cirrus Logic CS8409 Audiodevice** (ALC layout, DKMS-Modul)

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

Eine **mögliche Kompatibilität anderer iMAC- oder MacBook-Modelle** lässt sich über den im Tools-Ordner hinterlegten **Compability-Checker** überprüfen.

---
ℹ️ **Hinweis zur Installation**

Das Installationsskript bietet die gemeinsame oder separate Installation der erforderlichen WLAN-Firmware bzw. Audio-Treiber an.

ℹ️ℹ️ **Hinweis zu Kernel-Updates**

Ab einer bestimmten Kernel-Version kann es sein, dass die benötigten Treiber für WLAN (Broadcom BCM4364) und Audio (CS8409) bereits im Kernel enthalten sind. In diesem Fall funktionieren WLAN und Sound direkt nach einem Update – ohne zusätzliche Schritte.

Sollte nach einem Kernel-Update jedoch kein WLAN oder kein Audio mehr verfügbar sein, dann müssen die hier beschriebenen Treiber/Module erneut installiert werden.

Um diesen Prozess zu vereinfachen, kannst du am Ende des Installationsskripts **optional** einen zusätzlichen Service einrichten, der im Falle eines Kernel-Updates diesen Prozess automatisiert, sofern die benötigten Treiber noch nicht im Kernel verfügbar sind. 

🚀 **Installation**

1. Lade das Installationsskript herunter:
```bash
     wget https://raw.githubusercontent.com/frogro/imac-linux-wifi-audio/main/install.sh
```

2. Mach es ausführbar:
```bash
     sudo chmod +x install.sh
```

3. Führe es mit Root-Rechten aus:
```bash
     sudo ./install.sh
```
4. Starte dein Gerät neu:
```bash
     sudo reboot
```

Sodann kannst du auswählen, WLAN und Audio, nur WLAN oder nur Audio zu installieren.

Das Skript:

- installiert benötigte Pakete (curl, dkms, headers, pipewire, …),
- kopiert die passenden WLAN-Firmware-Einträge nach /lib/firmware/brcm/,
- baut & installiert das Audio-DKMS-Modul,
- schreibt ein Manifest nach /var/lib/imac-linux-wifi-audio/manifest.txt.

4. Reboot

🔧 **Deinstallation**
```bash
1. Lade das Deinstallationsskript herunter und mach es ausführbar:

     wget https://raw.githubusercontent.com/frogro/imac-linux-wifi-audio/main/uninstall.sh
```
2. Mach es ausführbar
```bash
     sudo chmod +x uninstall.sh
```
3.  Auswahl der zu deinstallierenden Komponenten

```bash
     sudo ./uninstall.sh           # entfernt WLAN + Audio + Service
     sudo ./uninstall.sh --wifi    # nur WLAN
     sudo ./uninstall.sh --audio   # nur Audio
     sudo ./uninstall.sh --service # nur Service   
```

📜 Rechtliches & Lizenz

**Broadcom WLAN Firmware (b2/b3):** proprietär, Copyright ©Broadcom
- Bereitstellung in diesem Repository erfolgt **ausschließlich zu Test- und Kompatibilitätszwecken**.
- Quelle: reynaldliu/macbook16-1-wifi-bcm4364-binary.
- Falls rechtlich problematisch, bitte Firmware direkt aus der Originalquelle beziehen.
- siehe auch: FIRMWARE-NOTICE

**Cirrus Logic Treiber:**  GPLv2 (wird aus Linux-Kernel extrahiert)

**Skripte & Dokumentation**: © 2025 frogro, veröffentlicht unter der MIT License, siehe auch LICENSE.

⚠️ Getestet ausschließlich mit Debian 13 (trixie). Andere Linux-Distros/Versionen können funktionieren, jedoch ohne Garantie.
