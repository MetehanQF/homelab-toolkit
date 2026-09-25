#!/usr/bin/env python3
"""check.sh'i calistirir, SADECE Alert Center'in gormedigi sinyalleri bildirir.

Neden secici: genel amacli bir izleyici zaten disk, sicaklik, throttle, RAM,
container ve servis durumunu debounce'lu izliyor ve ayni telefona push ediyor.
Onlari burada tekrar bildirirsem ayni olay icin iki bildirim gider. check.sh'in
TEK sahibi oldugu alan rtw88 WiFi surucusu + bellek parcalanmasi + watchdog +
NFS + ag geciti; bildirim kapsami bu.

Teslimat yolu: HA_ALERT_SCRIPT ile verilen Home Assistant script'i cagriliyor (dedup,
persistent notification, logbook, telefon push, MOVIE modu susturmasi onda).
HA token'i container icinde refresh token'dan uretiliyor - diske kalici token
yazilmiyor.

Durum degisimi yoksa sessiz kalir: OK->WARN, WARN->CRITICAL ve WARN->OK
gecislerinde bildirir, ayni uyari her 15 dakikada tekrar edilmez.
"""
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
CHECK = HERE / 'check.sh'
STATE = HERE / '.notify-state.json'
LOG = HERE / 'notify.log'


def _config():
    """Ortam degiskenleri, sonra yanindaki config.env; kurulum degeri gomulu degil.

    Sablon: config.example.env
    """
    values = {}
    cfg = Path(os.environ.get('HEALTH_MONITOR_CONFIG') or (HERE / 'config.env'))
    try:
        for raw in cfg.read_text(encoding='utf-8').splitlines():
            line = raw.strip()
            if line and not line.startswith('#') and '=' in line:
                k, _, v = line.partition('=')
                values[k.strip()] = v.strip().strip('"\'')
    except OSError:
        pass

    def pick(name, default):
        return (os.environ.get(name) or values.get(name) or default).strip()

    return (
        pick('HA_CONTAINER', 'homeassistant'),
        pick('HA_ALERT_SCRIPT', 'persistent_notification_alert'),
        pick('ALERT_SOURCE_ENTITY', 'sensor.health_monitor'),
        pick('CHECK_WINDOW', '24h'),
    )


CONTAINER, ALERT_SCRIPT, SOURCE, WINDOW = _config()

# (regex, severity) - ilk eslesen kazanir. Listede olmayan UYARI satirlari
# loglanir ama bildirilmez (sahibi Alert Center).
RULES = [
    (r"PING'E YANIT VERMIYOR", 'CRITICAL'),   # ag geciti dustu
    (r'order-3 bir ornekte', 'CRITICAL'),      # rtw88 kilitlenme esigi
    (r'tx report hatasi', 'CRITICAL'),         # duzeltme tutmuyor
    (r'allocation failure', 'CRITICAL'),
    (r'watchdog \d+ kez mudahale', 'WARNING'),
    (r'watchdog\.timer calismiyor', 'WARNING'),
    (r'order-3 medyani dusuk', 'WARNING'),
    (r'swap %\d+ dolu', 'WARNING'),
    (r'NFS rsize=', 'WARNING'),
    (r'adet failed systemd unit', 'WARNING'),
]
RULES = [(re.compile(p), s) for p, s in RULES]


def log(msg):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n"
    with LOG.open('a') as f:
        f.write(line)
    if sys.stdout.isatty():
        sys.stdout.write(line)


def run_check():
    r = subprocess.run(['bash', str(CHECK), WINDOW], capture_output=True, text=True, timeout=180)
    return r.stdout, r.returncode


def classify(stdout):
    """UYARI satirlarini bildirilecek / edilmeyecek diye ayirir."""
    notify, local, levels = [], [], set()
    for line in stdout.splitlines():
        line = line.strip()
        if not line.startswith('UYARI:'):
            continue
        text = line[len('UYARI:'):].strip()
        for pattern, sev in RULES:
            if pattern.search(text):
                notify.append(text)
                levels.add(sev)
                break
        else:
            local.append(text)
    severity = 'CRITICAL' if 'CRITICAL' in levels else ('WARNING' if levels else 'OK')
    return severity, notify, local


def ha_call(severity, message):
    """Yapilandirilan HA script'ini container icinden cagirir (HA_ALERT_SCRIPT)."""
    payload = json.dumps({'source': SOURCE, 'severity': severity, 'message': message})
    code = (
        "import json,os,urllib.request,urllib.parse\n"
        "d=json.load(open('/config/.storage/auth'))['data']\n"
        "o={u['id'] for u in d['users'] if u.get('is_owner') and u.get('is_active')}\n"
        "r=next(r for r in d['refresh_tokens'] if r['user_id'] in o and r.get('client_id') and r.get('token_type')=='normal')\n"
        "q=urllib.parse.urlencode({'grant_type':'refresh_token','refresh_token':r['token'],'client_id':r['client_id']}).encode()\n"
        "t=json.load(urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8123/auth/token',data=q),timeout=15))['access_token']\n"
        "b=os.environ['MT_PAYLOAD'].encode()\n"
        "req=urllib.request.Request('http://127.0.0.1:8123/api/services/script/'+os.environ['MT_SCRIPT'],data=b,\n"
        "    headers={'Authorization':'Bearer '+t,'Content-Type':'application/json'})\n"
        "urllib.request.urlopen(req,timeout=20).read()\n"
        "print('sent')\n"
    )
    r = subprocess.run(
        ['docker', 'exec', '-e', 'MT_PAYLOAD=' + payload, '-e', 'MT_SCRIPT=' + ALERT_SCRIPT,
         CONTAINER, 'python3', '-c', code],
        capture_output=True, text=True, timeout=60,
    )
    if r.returncode != 0:
        tail = (r.stderr or r.stdout).strip().splitlines()
        raise RuntimeError(tail[-1] if tail else 'bilinmeyen hata')
    return r.stdout.strip()


def main():
    dry = '--dry-run' in sys.argv
    try:
        stdout, rc = run_check()
    except Exception as e:
        log(f'HATA check.sh calistirilamadi: {type(e).__name__}: {e}')
        return 2

    severity, notify, local = classify(stdout)
    signature = severity + '|' + '\n'.join(sorted(notify))
    previous = {}
    if STATE.exists():
        try:
            previous = json.loads(STATE.read_text())
        except Exception:
            previous = {}

    summary = f'check.sh rc={rc} severity={severity} bildirilecek={len(notify)} yerel={len(local)}'
    if local:
        log(summary + ' | yerel (Alert Center sahibi): ' + '; '.join(local))
    else:
        log(summary)

    if signature == previous.get('signature'):
        log('degisim yok, bildirim gonderilmedi')
        return 0

    if severity == 'OK':
        if previous.get('severity') in ('WARNING', 'CRITICAL'):
            message = 'WiFi/bellek uyarilari temizlendi, sistem normale dondu.'
        else:
            STATE.write_text(json.dumps({'signature': signature, 'severity': severity, 'at': time.time()}))
            log('ilk calisma, durum OK - bildirim yok')
            return 0
    else:
        message = ' · '.join(notify)
        if len(message) > 350:
            message = message[:347] + '...'

    if dry:
        log(f'DRY-RUN gonderilecekti: severity={severity} message={message}')
        return 0

    try:
        ha_call(severity, message)
        log(f'bildirim gonderildi: {severity} - {message}')
    except Exception as e:
        log(f'HATA bildirim gonderilemedi: {e}')
        return 3

    STATE.write_text(json.dumps({'signature': signature, 'severity': severity, 'at': time.time()}))
    return 0


if __name__ == '__main__':
    sys.exit(main())
