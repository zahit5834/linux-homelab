#!/usr/bin/env bash
# ============================================================
# envanter.sh — Ev sunucusu envanteri (SADECE OKUR)
# Bu betik hiçbir şeyi silmez, durdurmaz veya değiştirmez.
# sudo yalnızca root'un okuyabildiği yerleri görmek için kullanılır.
#
# Çalıştırma:
#   bash ~/envanter/envanter.sh 2>&1 | tee ~/envanter/oncesi-$(date +%F).txt
# ============================================================

bolum()  { printf '\n\n########## %s ##########\n' "$1"; }
alt()    { printf '\n--- %s\n' "$1"; }
var_mi() { command -v "$1" >/dev/null 2>&1; }

# sudo parolasını baştan bir kez sorar; sonraki sudo komutları tekrar sormaz
sudo -v || { echo "sudo yetkisi alınamadı"; exit 1; }

# ------------------------------------------------------------
bolum "0. GENEL"
alt "İşletim sistemi, çekirdek, açık kalma süresi, RAM"
grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release
uname -r
uptime -p
free -h

# ------------------------------------------------------------
bolum "1. SYSTEMD SERVİSLERİ VE TIMER'LAR"

# Paketler unit dosyalarını /usr/lib/systemd/system altına koyar.
# /etc/systemd/system altındaki GERÇEK dosyalar (symlink değil) genelde elle eklenmiştir.
# Her dosya için: bir pakete ait mi (dpkg -S), ne çalıştırıyor, hangi klasörde, hangi kullanıcıyla.
alt "Elle eklenmiş görünen unit dosyaları"
for f in $(find /etc/systemd/system /usr/local/lib/systemd/system -maxdepth 1 -type f \
            \( -name '*.service' -o -name '*.timer' -o -name '*.socket' \) 2>/dev/null); do
  if dpkg -S "$f" >/dev/null 2>&1; then sahip="paket"; else sahip="ELLE"; fi
  echo "[$sahip] $f"
  grep -E '^(Description|ExecStart|WorkingDirectory|User|OnCalendar)=' "$f" | sed 's/^/      /'
done

alt "Override (drop-in) klasörleri — bir servisin ayarını sonradan değiştirdiysen burada görünür"
find /etc/systemd/system -maxdepth 1 -type d -name '*.d' 2>/dev/null

alt "Açılışta otomatik başlayan servisler (enabled)"
systemctl list-unit-files --type=service --state=enabled --no-pager --no-legend

alt "Maskelenmiş (tamamen engellenmiş) unit'ler"
systemctl list-unit-files --state=masked --no-pager --no-legend

alt "Şu an çalışan servisler"
systemctl list-units --type=service --state=running --no-pager --no-legend

alt "Hata vermiş servisler"
systemctl --failed --no-pager --no-legend

alt "Timer'lar (systemd'nin zamanlanmış görevleri)"
systemctl list-timers --all --no-pager

alt "Kullanıcı seviyesi servisler (systemctl --user)"
systemctl --user list-unit-files --state=enabled --no-pager --no-legend 2>/dev/null
ls -la ~/.config/systemd/user 2>/dev/null

# ------------------------------------------------------------
bolum "2. APT PAKETLERİ"

# 'apt-mark showmanual' kurulumla gelen birçok paketi de 'manual' sayar.
# Bu yüzden ilk kurulumdaki paket listesiyle karşılaştırıp SADECE sonradan eklenenleri buluyoruz.
alt "Kurulumdan sonra elle eklenen paketler"
if [ -f /var/log/installer/initial-status.gz ]; then
  comm -23 <(apt-mark showmanual | sort -u) \
           <(gzip -dc /var/log/installer/initial-status.gz | sed -n 's/^Package: //p' | sort -u)
else
  echo "(initial-status.gz yok — aşağıdaki apt geçmişine bakacağız)"
fi

alt "apt geçmişi: hangi tarihte hangi komut çalıştırılmış (otomatik güncellemeler hariç)"
sudo zcat -f /var/log/apt/history.log* 2>/dev/null \
  | awk '/^Start-Date/{d=$2} /^Commandline/ && !/unattended-upgrade/{print d, $0}' | sort -s -k1,1
# sort -s -k1,1: sadece tarihe göre sırala, aynı gündeki satırların gerçek sırasını koru

alt "Ek (3. parti) apt depoları"
ls -la /etc/apt/sources.list.d/

alt "Depo dışından, .deb dosyasıyla kurulmuş paketler"
apt list --installed 2>/dev/null | grep 'local\]'

alt "NVIDIA / CUDA paketleri ve DKMS modülleri (GPU/LLM denemelerinden kalmış olabilir)"
dpkg -l | awk '/^ii/ && $2 ~ /nvidia|cuda|cudnn/ {print $2, $3}'
var_mi dkms && sudo dkms status

# ------------------------------------------------------------
bolum "3. DİĞER PAKET YÖNETİCİLERİ VE ELLE KURULANLAR"
alt "snap";    var_mi snap    && snap list
alt "flatpak"; var_mi flatpak && flatpak list
alt "pipx";    var_mi pipx    && pipx list --short

alt "pip --user (Ubuntu 24.04 sistem pip'ini kilitler; paketler çoğunlukla venv'lerde olur)"
pip3 list --user 2>/dev/null

alt "Python sanal ortamları (venv) — konumları"
sudo find / \( -path /proc -o -path /sys -o -path /run -o -path /snap \) -prune \
  -o -name pyvenv.cfg -printf '%h\n' 2>/dev/null

alt "conda kurulumları"
ls -d ~/miniconda3 ~/anaconda3 ~/miniforge3 /opt/conda 2>/dev/null

alt "npm global paketleri"
var_mi npm && npm ls -g --depth=0

alt ".NET SDK / runtime"
var_mi dotnet && { dotnet --list-sdks; dotnet --list-runtimes; }

alt "Ollama modelleri"
var_mi ollama && ollama list

alt "/usr/local/bin (elle kopyalanan programlar buraya gider)"
ls -la /usr/local/bin

# ------------------------------------------------------------
bolum "4. CONTAINER VE SANALLAŞTIRMA"
for t in docker podman containerd lxc lxd virsh qemu-system-x86_64 VBoxManage; do
  var_mi "$t" && echo "VAR: $t"
done
if var_mi docker; then
  alt "docker container'lar (durmuşlar dahil)"; sudo docker ps -a
  alt "docker image'lar";                       sudo docker images
  alt "docker volume'lar";                      sudo docker volume ls
  alt "docker disk kullanımı";                  sudo docker system df
fi
var_mi virsh && { alt "Mevcut VM'ler"; sudo virsh list --all; }

# ------------------------------------------------------------
bolum "5. CRON"
alt "Kullanıcı crontab'ları (root dahil)"
for u in $(sudo ls /var/spool/cron/crontabs 2>/dev/null); do
  echo "[$u]"; sudo crontab -l -u "$u" | grep -vE '^\s*(#|$)'
done

alt "/etc/crontab"
grep -vE '^\s*(#|$)' /etc/crontab

alt "/etc/cron.* içindekiler — pakete mi ait, elle mi eklenmiş?"
for f in /etc/cron.d/* /etc/cron.{hourly,daily,weekly,monthly}/*; do
  [ -f "$f" ] || continue
  if dpkg -S "$f" >/dev/null 2>&1; then echo "[paket] $f"; else echo "[ELLE]  $f"; fi
done

# ------------------------------------------------------------
bolum "6. DİNLEYEN PORTLAR"
# -t TCP, -u UDP, -l sadece dinleyenler, -p hangi süreç, -n isim/port çözümlemesi yapma
sudo ss -tulpn

# ------------------------------------------------------------
bolum "7. WEB SUNUCULARI VE SERTİFİKALAR"
alt "Kurulu web sunucusu / proxy paketleri"
dpkg -l nginx apache2 caddy haproxy lighttpd 2>/dev/null | awk '/^ii/{print $2, $3}'

alt "Etkin site yapılandırmaları"
ls -la /etc/nginx/sites-enabled /etc/nginx/conf.d /etc/apache2/sites-enabled /etc/caddy 2>/dev/null

alt "nginx özeti: hangi isim, hangi port, nereye yönlendiriyor"
var_mi nginx && sudo nginx -T 2>/dev/null \
  | grep -E '^\s*(server_name|listen|proxy_pass|root)\b' | sed 's/^\s*//' | sort | uniq -c

alt "Let's Encrypt sertifikaları"
sudo ls /etc/letsencrypt/live 2>/dev/null

# ------------------------------------------------------------
bolum "8. BÜYÜK VE SANA AİT DOSYALAR"
alt "/opt /srv /usr/local /home altındaki klasörlerin boyutu"
sudo du -sh /opt/* /srv/* /usr/local/* /home/* 2>/dev/null | sort -rh

alt "Ev dizinin (gizli klasörler dahil) — en büyük 20"
du -sh ~/.[!.]* ~/* 2>/dev/null | sort -rh | head -20

alt "Sistemdeki 500 MB'tan büyük dosyalar (modeller, ISO'lar, eski yedekler)"
sudo find / \( -path /proc -o -path /sys -o -path /run -o -path /snap \) -prune \
  -o -type f -size +500M -printf '%s\t%p\n' 2>/dev/null \
  | sort -rn | awk -F'\t' '{printf "%6.1f GB  %s\n", $1/1073741824, $2}'

# ------------------------------------------------------------
bolum "9. KULLANICILAR VE GRUPLAR"
alt "İnsan kullanıcıları (UID >= 1000)"
awk -F: '$3>=1000 && $3<65534 {print $1, "uid="$3, $6, $7}' /etc/passwd

alt "Sistem/servis kullanıcıları (UID 100-999) — uygulamaların açtığı hesaplar burada"
awk -F: '$3>=100 && $3<1000 {print $1, "uid="$3, $6, $7}' /etc/passwd

alt "Yetki veren gruplar"
getent group sudo docker libvirt kvm

# ------------------------------------------------------------
bolum "10. SSH — KORUNACAK (sadece okunuyor)"
alt "ssh servis/soket durumu (24.04'te ssh, soket üzerinden başlatılır)"
for u in ssh.socket ssh.service; do echo "$u: $(systemctl is-active $u)"; done

alt "Önemli sshd ayarları"
sudo grep -rhiE '^\s*(port|listenaddress|permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|allowusers)\b' \
  /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null

alt "~/.ssh içeriği (anahtarların kendisi yazdırılmıyor)"
ls -la ~/.ssh
echo "authorized_keys satır sayısı: $(wc -l < ~/.ssh/authorized_keys 2>/dev/null)"

# ------------------------------------------------------------
bolum "11. AĞ — KORUNACAK (sadece okunuyor)"
alt "Arayüzler ve MAC adresleri (DHCP rezervasyonunda lazım olacak)"
ip -br link
alt "IP adresleri";        ip -br addr
alt "Yönlendirme tablosu"; ip route

alt "Ağı yöneten servis"
for u in systemd-networkd NetworkManager; do echo "$u: $(systemctl is-active $u)"; done

alt "DNS"
resolvectl status 2>/dev/null | grep -E 'Current DNS|DNS Servers'

alt "netplan dosyaları"
ls -la /etc/netplan/
# Wi-Fi ayarı kaldıysa parola satırları çıktıda otomatik gizleniyor
sudo cat /etc/netplan/*.yaml 2>/dev/null | sed -E 's/(password:).*/\1 ***GIZLENDI***/'

# ------------------------------------------------------------
bolum "12. FIREWALL"
alt "ufw";                                               sudo ufw status verbose
alt "nftables tabloları (Docker/libvirt kendi tablolarını ekler)"; sudo nft list tables 2>/dev/null
alt "iptables kuralları (ilk 50)";                       sudo iptables -S 2>/dev/null | head -50

# ------------------------------------------------------------
bolum "13. DİSK"
alt "Diskler ve bölümler (ROTA=1 → HDD, ROTA=0 → SSD)"
lsblk -o NAME,SIZE,TYPE,ROTA,FSTYPE,MOUNTPOINTS

alt "Doluluk"
df -hT -x tmpfs -x devtmpfs -x squashfs -x efivarfs

alt "fstab (açılışta otomatik bağlanan diskler)"
grep -vE '^\s*(#|$)' /etc/fstab

alt "Kök dizinde en çok yer kaplayanlar"
sudo du -xh --max-depth=1 / 2>/dev/null | sort -rh | head -15

alt "/var altında en çok yer kaplayanlar"
sudo du -xh --max-depth=1 /var 2>/dev/null | sort -rh | head -10

alt "Journal (log) boyutu"
sudo journalctl --disk-usage

bolum "BİTTİ — $(date '+%F %T')"
