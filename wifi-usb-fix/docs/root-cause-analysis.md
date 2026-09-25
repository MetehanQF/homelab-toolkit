# TP-Link USB WiFi Kilitlenmesi — Kök Neden ve Çözüm

Tarih: 2026-09-22
Host: `<host>` — Raspberry Pi 5 Model B Rev 1.1, Ubuntu, `6.8.0-1064-raspi`
Cihaz: TP-Link `2357:0138` 802.11ac NIC = Realtek **RTL8822BU**, sürücü `rtw88_8822bu` / `rtw88_usb`, firmware 27.2.0
Arayüz: `<PI5_WIFI_IFACE>`, <PI5_LAN_IP>/24, AP `<DEVICE_MAC>` (SSID "<HOME_SSID>")

## Özet

Adaptör bozuk değil. Güç problemi değil. RF/sinyal problemi değil.
**Sürücünün TX yolu, çekirdekten 32 KB bitişik bellek isterken başarısız oluyor
ve kalıcı olarak kilitleniyor.** `rtw88_usb`'nin kurtarma yolu yoktur — sadece
USB yeniden numaralandırma (sizin fişi çıkarıp takmanız) canlandırıyor.

## Kanıt zinciri

### 1. Doğrudan kernel stack trace — 21 Eylül 18:22:47

```
kworker/u8:7: page allocation failure: order:3,
    mode:0x60820(GFP_ATOMIC|__GFP_COMP|__GFP_MEMALLOC)
Hardware name: Raspberry Pi 5 Model B Rev 1.1 (DT)
Workqueue: rtw88_usb: tx wq rtw_usb_tx_handler [rtw88_usb]
  ...
  __alloc_skb
  __netdev_alloc_skb
  rtw_usb_tx_agg_skb+0xdc/0x288 [rtw88_usb]
  rtw_usb_tx_handler+0x54/0x1238 [rtw88_usb]
```

`rtw_usb_tx_agg_skb()` TX paket birleştirmesi için **order-3 = 32 KB bitişik**
blok istiyor ve bunu **GFP_ATOMIC** ile istiyor. GFP_ATOMIC uyuyamaz ve geri
kazanım (reclaim) yapamaz; yalnızca hazır serbest listelerden alabilir.

Bir saniye sonra, 18:22:48'de başlayıp aralıksız:

```
rtw_8822bu 4-1:1.0: failed to get tx report from firmware   (her 2 saniyede)
```

TX tamponu ayrılamadığı için TX işleyicisi ölüyor, firmware artık TX raporu
döndürmüyor, bağlantı ölüyor.

### 2. O anda bellek gerçekten parçalanmıştı

Aynı dökümden, `Normal` zone serbest blok dağılımı:

```
Normal: 53200*4kB (UME)  8437*8kB (UM)  0*16kB  0*32kB  0*64kB
        0*128kB  0*256kB  0*512kB  0*1024kB  0*2048kB  0*4096kB  = 280296kB
```

280 MB **serbest** bellek var, ama **16 KB ve üzeri tek bir blok yok**. Hepsi
4 KB ve 8 KB parçalara bölünmüş. 32 KB'lık istek matematiksel olarak
karşılanamaz.

Aynı anda `inactive_file: 7960032kB` — yaklaşık **8 GB page cache**.
Geri kazanılabilir bellek ama GFP_ATOMIC ona dokunamaz.

### 3. Çekirdek bunu düzeltmeye çalıştı ve başaramadı

`/proc/vmstat`:

```
compact_stall    15
compact_fail     15
compact_success   0     <-- 15 denemede 0 başarı
```

Bellek birleştirme (compaction) bu makinede **hiç çalışmıyor**.

### 4. Parçalanmayı besleyen koşullar

| Etken | Ölçülen değer | Sorun |
|---|---|---|
| `vm.min_free_kbytes` | 45056 (44 MB) | 12 GB'lık zone için çok küçük; yüksek-order atomik rezerv yok |
| `vm.watermark_scale_factor` | 10 (mümkün en dar) | min→low aralığı sadece ~12 MB; kswapd'nin hiç koşu mesafesi yok |
| `vm.dirty_ratio` | 20 | 16 GB'da ~3.2 GB kirli sayfa birikmesine izin veriyor |
| NFS `rsize`/`wsize` | **524288 (512 KB)** | USB2 WiFi üzerinden absürt büyük; fstab'da belirtilmemiş, sunucudan pazarlıkla gelmiş |
| Yük ortalaması | 5.42 / 7.62 / 8.11 | 4 çekirdekli Pi'de sürekli ~2x aşırı yük |
| USB bus hızı | **480 Mbps** (bus 4 = USB2) | USB3 cihaz, USB2 portta çalışıyor |

Kamera kaydı (Frigate) `<PCOLD_LAN_IP>:/srv/camera` NFS mount'una
**bu WiFi bağlantısı üzerinden** sürekli yazıyor. 512 KB'lık NFS blokları
page cache'i şişiriyor ve Normal zone'u parçalıyor; ardından aynı WiFi
sürücüsü 32 KB bitişik blok isteyip başarısız oluyor. Kendi kendini besleyen
bir döngü.

### 5. Olay geçmişi ve korelasyon

| Zaman | Olay |
|---|---|
| 20 Eyl 15:07 | kısa tx-report patlaması (2 satır, kendi kendine düzeldi) |
| **21 Eyl 18:22:47** | order-3 GFP_ATOMIC hatası → 18:22:48–18:24:37 arası **55 tx-report hatası** |
| 21 Eyl 18:23–18:24 | `nfs: server <PCOLD_LAN_IP> not responding` (sonuç) |
| 21 Eyl 18:27:02 | fiziksel çıkarma → `usb write 1 fail, status: -71` |
| 21 Eyl 18:27:45 | yeniden takma, cihaz no 12 |
| **22 Eyl 02:52:01–02:53:07** | **34 tx-report hatası**, 02:52:20'de tekrar NFS timeout |
| 22 Eyl 04:58:36 | fiziksel çıkarma, cihaz no 12 kayboldu |
| 22 Eyl 04:59:02 | yeniden takma → cihaz no 16, firmware 27.2.0 |
| 22 Eyl 04:59:20 | AP ile yeniden ilişkilendi, bağlantı geri geldi |

İki büyük patlama da NFS timeout'ları ile birlikte. Her ikisi de ancak
fiziksel çıkar-tak ile düzeldi.

### 6. Elenen olasılıklar

| Hipotez | Ölçüm | Sonuç |
|---|---|---|
| Güç yetersizliği / brownout | `vcgencmd get_throttled` = **0x0**, `bMaxPower` = 500mA | Elendi |
| USB autosuspend | `power/control` = **on**, `runtime_status` = active | Elendi |
| WiFi powersave | NM aktif bağlantı `powersave: 2 (disable)` | Elendi |
| Sıcaklık | 60.9 °C, throttle yok | Elendi |
| Zayıf sinyal / AP sorunu | 0% paket kaybı, gecikme 2.5–4.2 ms, TX power 35 dBm | Elendi |
| Kablo/port teması | `-71` hatası sadece fiziksel çıkarma anında | Elendi |
| Bozuk adaptör | Çıkar-tak sonrası her seferinde sorunsuz çalışıyor | Elendi |

Not: `brcmfmac: brcmf_set_channel ... fail, reason -52` satırları her 2 dakikada
bir tekrar ediyor ama bunlar **dahili Pi WiFi'si** (`wlan0`, bağlı değil,
NetworkManager tarafından taranıyor) kaynaklı ve kilitlenmelerle korelasyonu
yok — gün boyu sabit oranda oluşuyorlar. Gürültü, neden değil.

`22 Eyl 04:58:12`'deki ikinci ayırma hatası (order-6, `usbhid_probe`) klavye/fare
hub'ının takılmasına ait, ayrı bir olay — aynı parçalanmanın başka bir belirtisi.

## Uygulanan çözüm

`sudo bash wifi-usb-fix/install.sh`

### 1. Yüksek-order atomik rezervi büyüt (kök neden)

`/etc/sysctl.d/99-wifi-usb-mem-stability.conf`:

| Ayar | Eski | Yeni | Amaç |
|---|---|---|---|
| `vm.min_free_kbytes` | 45056 | **262144** | Normal zone min watermark ~57 MB → ~340 MB; 32 KB'lık atomik istekler için rezerv |
| `vm.watermark_scale_factor` | 10 | **200** | kswapd çok daha erken devreye girer, rezerv tükenmez |
| `vm.compaction_proactiveness` | 20 | **40** | Arka planda daha agresif birleştirme |
| `vm.dirty_bytes` | (ratio 20) | **256 MB** | Kirli sayfa birikimini sabitler, page cache şişmesini kırar |
| `vm.dirty_background_bytes` | (ratio 10) | **64 MB** | Yazmayı daha erken başlatır |

### 2. Otomatik kurtarma — fişe bir daha dokunmamak için

`/usr/local/bin/wifi-usb-watchdog.sh` + `wifi-usb-watchdog.timer` (30 s'de bir):

- Cihazı `2357:0138` ile **dinamik** bulur (portu değiştirseniz de çalışır).
- Arayüzü ve varsayılan geçidi sysfs/route üzerinden çözer.
- Geçide ping atar. **Sağlıklıysa hiçbir şey yapmaz.**
- Ping başarısız **ve** son 3 dakikada `failed to get tx report` log satırı
  varsa → anında müdahale. İmza yoksa 3 ardışık tur (~90 s) bekler.
- Müdahale = `authorized` dosyasına `0` sonra `1` yazmak. Bu, fiziksel
  çıkar-tak'ın sysfs eşdeğeri; USB yeniden numaralandırma tetikler.
- Geri gelene kadar 120 s boyunca izler, sonucu journal'a yazar.
- 5 dakikalık bekleme süresi ile döngüye girmesi engellenir.

İzleme: `journalctl -t wifi-usb-watchdog -f`

### 3. NFS blok boyutunu düşür

`/etc/fstab`, tek satır, sadece seçenekler eklendi:

```
<PCOLD_LAN_IP>:/srv/camera /mnt/camera nfs4 \
  rsize=131072,wsize=131072,rw,hard,noatime,_netdev,nofail,...
```

512 KB → 128 KB. Bir sonraki mount'ta etkili olur.

## Doğrulananlar

- Kök neden, kernel stack trace + aynı andaki buddyinfo dağılımı ile **kanıtlandı** (tahmin değil).
- `compact_success 0` ile birleştirmenin çalışmadığı doğrulandı.
- Tüm alternatif hipotezler ölçümle elendi (yukarıdaki tablo).
- Watchdog tespit mantığı canlı sistemde çalıştırıldı: `USB_PATH=/sys/bus/usb/devices/4-1`,
  `IFACE=<PI5_WIFI_IFACE>`, `GATEWAY=<ROUTER_LAN_IP>`, sağlık OK → doğru şekilde hiçbir şey yapmadı.
- `authorized` dosyasının var ve yazılabilir olduğu doğrulandı.
- fstab `sed`'i gerçek dosyanın kopyası üzerinde test edildi: **tam 1 satır** değişiyor, `findmnt --verify` temiz.
- 5 sysctl anahtarının tümünün bu çekirdekte var olduğu `/proc/sys` üzerinden doğrulandı.
- Her iki script `bash -n` ile sözdizimi kontrolünden geçti.

## Doğrulanmayanlar

- **Reset dalının canlı testi yapılmadı.** Test etmek sunucunun tek ağ
  bağlantısını kasten düşürür (Home Assistant, Frigate, Nextcloud, NFS).
  Mantık doğru ve `authorized` yöntemi standart, ama gerçek kilitlenme
  anındaki davranışı henüz gözlenmedi.
- sysctl değişikliklerinin kilitlenmeyi tamamen bitirip bitirmediği — bunu
  ancak birkaç gün patlama olmaması gösterir. İzlenmeli.

## Kalan öneriler (uygulanmadı)

1. **Ethernet kablosu tak.** `eth0` şu an `carrier=0`, kablo yok. Bu Pi 5 bir
   sunucu — Home Assistant, Frigate, Nextcloud, MQTT, NFS istemcisi hepsi
   USB2 WiFi dongle'ına bağlı. Gigabit ethernet `rtw88_usb`'yi kritik yoldan
   tamamen çıkarır. Yukarıdaki her şey azaltma; **gerçek çözüm bu ve maliyeti
   bir kablo.**
2. **Dongle'ı USB3 porta (mavi) taşı.** Şu an bus 4'te 480 Mbps ile çalışıyor;
   bus 3 ve bus 5 (USB3) tamamen boş. Watchdog portu dinamik bulduğu için
   taşımak hiçbir şeyi bozmaz.
3. **`wlan0`'ı NetworkManager'da kapat.** Bağlı olmayan dahili radyo her
   2 dakikada boşuna taranıp `brcmf_set_channel` hataları üretiyor; CPU ve
   2.4 GHz RF gürültüsü. `nmcli radio wifi` yerine cihaz bazlı:
   `sudo nmcli device set wlan0 managed no`
4. **Yükü incele.** Load average 8 / 4 çekirdek sürekli aşırı yük demek;
   bellek baskısının de kaynağı. Ayrı bir iş.

## Değiştirilmeyenler

Frigate, Home Assistant, Mosquitto, Nextcloud, Docker, NetworkManager
profilleri, netplan dosyaları, `/etc/modprobe.d/`, kamera yapılandırması,
dashboard'lar — hiçbiri bu işte **dokunulmadı**.

Geri alma: `RECOVERY.md`
Yedek: `$TOOLKIT_BACKUP_DIR/<STAMP>-wifi-usb-fix/`
