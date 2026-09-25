# Geri Alma — wifi-usb-fix

Yedek dizini kurulumda ekrana yazılır, ayrıca:
`cat /tmp/wifi-usb-fix-last-backup`
Biçim: `$TOOLKIT_BACKUP_DIR/<STAMP>-wifi-usb-fix/`

## Hepsini geri al

```bash
BK=$(cat /tmp/wifi-usb-fix-last-backup)

# 1. sysctl ayarlarını kaldır
sudo rm -f /etc/sysctl.d/99-wifi-usb-mem-stability.conf
# çalışan değerleri elle eski haline döndür (yeniden başlatma gerekmez)
sudo sysctl -w vm.min_free_kbytes=45056 \
              vm.watermark_scale_factor=10 \
              vm.compaction_proactiveness=20 \
              vm.dirty_bytes=0 \
              vm.dirty_background_bytes=0
sudo sysctl -w vm.dirty_ratio=20 vm.dirty_background_ratio=10

# 2. otomatik kurtarmayı kapat ve kaldır
sudo systemctl disable --now wifi-usb-watchdog.timer
sudo rm -f /etc/systemd/system/wifi-usb-watchdog.{service,timer} \
           /usr/local/bin/wifi-usb-watchdog.sh
sudo systemctl daemon-reload

# 3. fstab'ı geri yükle
sudo cp -a "$BK/fstab.orig" /etc/fstab
sudo findmnt --verify
```

`vm.dirty_bytes=0` yazmak `dirty_ratio`'yu yeniden etkinleştirir; bu yüzden
ikinci `sysctl -w` satırı ile eski oranlar açıkça geri yazılıyor.

## Sadece otomatik kurtarmayı durdur (ayarlar kalsın)

```bash
sudo systemctl disable --now wifi-usb-watchdog.timer
```

## Sadece bir sonraki resete izin verme (geçici sessize alma)

```bash
sudo systemctl stop wifi-usb-watchdog.timer
# tekrar aç:
sudo systemctl start wifi-usb-watchdog.timer
```

## Doğrulama komutları

```bash
sysctl vm.min_free_kbytes vm.watermark_scale_factor vm.dirty_bytes
systemctl status wifi-usb-watchdog.timer
journalctl -t wifi-usb-watchdog --no-pager | tail -n 20
findmnt -t nfs4 -o TARGET,OPTIONS
```

## Dokunulmayanlar

Frigate, Home Assistant, Mosquitto, Nextcloud, Docker, NetworkManager
profilleri, netplan dosyaları, `/etc/modprobe.d/` ve kamera yapılandırması
bu kurulumda **hiç değiştirilmedi**.
