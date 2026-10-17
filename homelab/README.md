# Ev Sunucusu: Temizlik + KVM Lab Kurulumu

> 17 Ekim 2026 · Eski bir laptop'u (i5 7. nesil, 8 GB RAM, 512 GB SSD + 1 TB HDD) yeniden kurmadan temizleyip üzerine KVM/libvirt ile iki VM'lik bir Linux öğrenme lab'i kurdum. Hedef: RHCSA'ya hazırlık.

## IP tablosu

| Makine | OS | IP | MAC | RAM | vCPU | Disk | IP yöntemi |
|---|---|---|---|---|---|---|---|
| **home-lab** (host) | Ubuntu 24.04.5 | 192.168.1.58 | 50:9a:4c:cf:4c:4f | 7.6 GB | 8 | SSD + HDD | Router'da DHCP rezervasyonu (br0 üzerinde) |
| **ubuntu-lab** | Ubuntu 26.04.1 | 192.168.1.59 | 52:54:00:4c:00:59 | 1.5 GB | 2 | 20 GB qcow2 | Router'da DHCP rezervasyonu |
| **rocky-lab** | Rocky Linux 10.2 | 192.168.1.60 | 52:54:00:4c:00:60 | 1.5 GB | 2 | 20 GB qcow2 | Router'da DHCP rezervasyonu |

- Router: `192.168.1.1` · Ağ: `192.168.1.0/24`
- VM diskleri SSD'de (`/var/lib/libvirt/images`), ISO'lar ve yedekler HDD'de (`/srv/data`)
- VM MAC'lerini `virt-install` ile **ben belirledim**, böylece rezervasyonu VM kurulmadan önce router'a girebildim. `52:54:00` = QEMU/KVM önekidir; MAC'in sonu IP'nin son hanesiyle eşleşiyor.

```
                 ┌──────────── Router 192.168.1.1 (DHCP + rezervasyon) ────────────┐
                 │                                                                 │
           Laptop (.3)                                       home-lab (laptop sunucu)
                                                            ┌─────────────────────────┐
                                                            │  br0  .58  (yazılım switch)
                                                            │   ├── enp2s0 (fiziksel kart)
                                                            │   ├── vnet → ubuntu-lab .59
                                                            │   └── vnet → rocky-lab  .60
                                                            │  virbr0 192.168.122.1 (NAT, kullanılmıyor)
                                                            └─────────────────────────┘
```

---

## Aşama 1: Sistemi yeniden kurmadan temizlemek

### Yöntem
1. **Envanter** → salt-okunur bir betikle (`envanter.sh`) servisleri, paketleri, portları, cron'u, kullanıcıları, firewall'ı ve diski listeledim. Çıktıyı `oncesi-TARİH.txt` olarak kaydettim.
2. **Karar** → her kalem için sil / tut / emin değilim.
3. **Yedek** → silinecek her şeyi önce HDD'ye arşivledim.
4. **Temizlik** → doğru sırayla: servis durdur → disable → unit sil → dosyalar → kullanıcılar → firewall → paketler (purge) → autoremove.
5. **Doğrulama** → reboot + aynı betikle `sonrasi-TARİH.txt`, iki dosyayı karşılaştırma.

### Neyi neden kaldırdım

| Kalem | Neden |
|---|---|
| HomelabPanel + HomeDrop (systemd servisleri, `/opt/*`, `/srv/data/homedrop`, `/var/lib/homedrop`, servis kullanıcıları, ufw 5100/5200) | Artık kullanılmayan kendi .NET uygulamalarım |
| `aspnetcore-runtime-10.0` (+ autoremove ile dotnet runtime) | Onu kullanan uygulama kalmadı |
| `wpasupplicant`, `iw`, `rfkill` | Wi-Fi araçları; sunucu artık Ethernet ile çalışıyor |
| `net-tools` | Eski `ifconfig`/`netstat`; yerine `ip` ve `ss` |
| `open-vm-tools` | VMware misafir araçları; bu fiziksel bir makine |
| `modemmanager` | 3G/4G modem yönetimi |
| `multipath-tools`, `open-iscsi` | Kurumsal SAN depolama |
| `snapd`, `lxd-installer` | Hiç snap kurulu değildi |
| `cloud-init` | Bulut ilk açılış aracı; ağ ve SSH ayarlarının üzerine yazabiliyordu |
| `acl` | Kullanılmıyordu (libvirt kurulunca bağımlılık olarak geri geldi; libvirt imaj dosyalarına `setfacl` ile izin veriyor) |
| `lxd` grubu | lxd-installer'dan kalan artık grup |

Sonuç: açılışta başlayan servis 49 → 31, dışarıya açık port 3 → 1 (sadece 22), elle eklenmiş unit 2 → 0.

### Önemli tuzaklar

**1. Metapaket + autoremove.** `cloud-init`'i purge etmek `ubuntu-server` metapaketini de götürüyordu. Metapaket gidince onun çektiği `sudo`, `vim`, `curl`, `git`, `tmux`, `unattended-upgrades` gibi "auto" işaretli paketler autoremove'a aday olur. Önce bunları manual işaretledim:
```bash
apt-cache depends --installed ubuntu-server ubuntu-server-minimal \
  | awk '$1 ~ /Depends:|Recommends:/ {print $2}' | grep -v '^<' | sort -u \
  | grep -vxF -f ~/silinecek.txt > ~/korunacak.txt
sudo apt-mark manual $(cat ~/korunacak.txt)
apt-get -s purge $P          # -s: simülasyon, hiçbir şey yapmaz
```

**2. sshd'de ilk değer kazanır.** `/etc/ssh/sshd_config.d/` içindeki dosyalar alfabetik okunur ve bir ayar için **ilk** bulunan değer geçerli olur. `00-hardening.conf` (no) dosyası `50-cloud-init.conf` (yes) dosyasını yeniyordu. Tuzak dosyayı sildim. Etkin değeri tahmin etme, sor: `sudo sshd -T | grep passwordauthentication`
> systemd drop-in'lerinde ve netplan'da kural tersidir: **son** okunan kazanır.

**3. `sudo` sadece komutu yükseltir.** Joker karakterleri ve `>` yönlendirmesini senin kabuğun (senin yetkinle) işler:
```bash
sudo gzip -t /root-only-dir/*.tar.gz        # ✗ * açılamaz
sudo bash -c 'gzip -t /root-only-dir/*.tar.gz'   # ✓
echo x | sudo tee /etc/dosya >/dev/null     # ✓ (sudo echo x > /etc/dosya çalışmaz)
```

**4. cloud-init'in ürettiği dosyalar paketine ait değildir** (`dpkg -S` bulamaz) → purge onları silmez. Ağ dosyası yerinde kaldığı için bağlantı kopmadı; sshd tuzak dosyasını elle sildim.

### Yedek (HDD)
```
/srv/data/yedek/temizlik-2026-10-17/   (chmod 700, sadece root)
├── uygulamalar.tar.gz        # /opt/*, unit dosyaları, /srv/data/homedrop
├── homedrop-varlib.tar.gz    # Data Protection anahtarı
├── ev-dizini.tar.gz          # ~/deploy, eski Wi-Fi yedekleri
├── etc-config.tar.gz         # netplan, ssh, cloud, ufw, modprobe.d
├── paket-secimleri.txt / paket-manual.txt
├── 50-cloud-init.yaml        # eski netplan dosyası (bridge sonrası buraya taşındı)
└── envanter/                 # öncesi/sonrası raporları
```

### Testte öğrendiklerim
- `stop` = şimdi durdur · `disable` = açılışta başlatma (`wants/` symlink'i silinir) · `mask` = hiçbir şekilde başlatılamaz (`/dev/null`'a symlink)
- `remove` config'leri bırakır (`dpkg -l` → `rc`), `purge` siler
- Grup üyeliği oturum açılırken okunur → `usermod -aG` sonrası çıkıp yeniden gir
- `ls -l` sparse dosyaların görünen boyutunu, `du -h` gerçekte kapladığı alanı gösterir

---

## Aşama 2: KVM lab

### 1. Kapak kapalıyken uyumasın
```ini
# /etc/systemd/logind.conf.d/homelab.conf
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
```
Ek olarak `sleep/suspend/hibernate/hybrid-sleep.target` maskeli. Etkin ayarı görmek için: `systemd-analyze cat-config systemd/logind.conf`

### 2. KVM + libvirt
```bash
grep -cE 'vmx|svm' /proc/cpuinfo        # >0 → VT-x var
ls -l /dev/kvm                          # varsa BIOS'ta da açık
sudo apt install qemu-system-x86 libvirt-daemon-system virtinst cpu-checker
# Not: ekransız sunucuda --no-install-recommends eklenmeli; yoksa ~200 GUI kütüphanesi de geliyor
kvm-ok
sudo usermod -aG libvirt,kvm zahit     # -a olmadan diğer gruplardan çıkarırsın!
echo 'export LIBVIRT_DEFAULT_URI=qemu:///system' >> ~/.bashrc
virt-host-validate qemu
```

### 3. Bridge (br0)
Fiziksel kartı yazılımsal bir switch'e (`br0`) port yaptım ve IP'yi switch'e taşıdım. VM'ler de aynı switch'e takılıyor ve router'dan kendi IP'lerini alıyor.

```yaml
# /etc/netplan/60-bridge.yaml   (chmod 600)
network:
  version: 2
  renderer: networkd
  ethernets:
    enp2s0:
      dhcp4: false
      dhcp6: false
  bridges:
    br0:
      interfaces: [enp2s0]
      macaddress: 50:9a:4c:cf:4c:4f   # enp2s0'ın MAC'i → router aynı cihazı görür, rezervasyon tutar
      dhcp4: true
      dhcp6: false
```
```bash
tmux new -s ag                                            # bağlantı koparsa işlem ölmesin
sudo netplan try --config-file ~/60-bridge.yaml --timeout 180
# başka pencerede test et (ip -br addr, ping, YENİ ssh) → SONRA Enter
bridge link            # enp2s0 → master br0 state forwarding
```
- `parameters: {stp: false, forward-delay: 0}` bloğu `netplan try` ile reddedildi ("reverting custom parameters for bridges and bonds is not supported"). Gerek de yokmuş: networkd'de STP varsayılan olarak kapalı (`networkctl status br0` → `STP: no`).
- `br_netfilter` modülü yüklü değil → bridge trafiği ufw'ye uğramıyor. (Docker kurulursa yüklenir; VM'ler ağa çıkamazsa ilk bakılacak yer.)
- Kalıcılığı reboot ile test ettim.

**Bridge vs NAT**

| | `virbr0` (libvirt default, NAT) | `br0` (bridge) |
|---|---|---|
| VM'in IP'si | Özel ağ 192.168.122.0/24 | Ev ağından (router) |
| VM → internet | ✓ (host'un IP'si arkasından) | ✓ |
| Laptop → VM | ✗ (port yönlendirme gerekir) | ✓ doğrudan |
| Ne zaman | İzole test ağı; **Wi-Fi** üzerinden çalışan host (Wi-Fi bridge edilemez); ev ağına IP harcamamak | VM'ler gerçek sunucu gibi ağda görünsün |

### 4. ISO'lar (HDD)
```bash
sudo mkdir -p /srv/data/iso && sudo chown zahit: /srv/data/iso && cd /srv/data/iso
wget -c https://releases.ubuntu.com/resolute/ubuntu-26.04.1-live-server-amd64.iso
wget -c https://releases.ubuntu.com/resolute/SHA256SUMS
wget -c https://download.rockylinux.org/pub/rocky/10/isos/x86_64/Rocky-10-latest-x86_64-minimal.iso
wget -c https://download.rockylinux.org/pub/rocky/10/isos/x86_64/Rocky-10-latest-x86_64-minimal.iso.CHECKSUM
sha256sum -c SHA256SUMS --ignore-missing
sha256sum -c Rocky-10-latest-x86_64-minimal.iso.CHECKSUM
```

### 5. VM'ler (seri konsoldan metin kurulum)
```bash
virt-install --name ubuntu-lab --memory 2048 --vcpus 2 \
  --disk size=20,format=qcow2,bus=virtio \
  --location /srv/data/iso/ubuntu-26.04.1-live-server-amd64.iso,kernel=casper/vmlinuz,initrd=casper/initrd \
  --os-variant ubuntu24.04 \
  --network bridge=br0,model=virtio,mac=52:54:00:4c:00:59 \
  --graphics none --extra-args 'console=ttyS0,115200n8'

virt-install --name rocky-lab --memory 2048 --vcpus 2 --cpu host-passthrough \
  --disk size=20,format=qcow2,bus=virtio \
  --location /srv/data/iso/Rocky-10-latest-x86_64-minimal.iso \
  --os-variant rocky9 \
  --network bridge=br0,model=virtio,mac=52:54:00:4c:00:60 \
  --graphics none --extra-args 'inst.text console=ttyS0,115200n8'
```
- `--os-variant`: host'un osinfo veritabanı 26.04/rocky10'u tanımıyor → en yakın sürüm
- `--cpu host-passthrough`: Rocky 10 **x86-64-v3** ister (`/lib64/ld-linux-x86-64.so.2 --help | grep v3`)
- Kurulum için 2 GB RAM, sonra 1.5 GB'a düşürdüm
- Konsoldan çıkış `Ctrl+]`, tekrar bağlanma `virsh console <vm>`
- **Anaconda'da Ctrl+C basma** → kurulum programını öldürür. Bir alandan çıkmak için boş Enter, geri dönmek için `c`.

### 6. SSH (laptop → VM)
```powershell
# Windows'ta ssh-copy-id yok:
type $env:USERPROFILE\.ssh\id_ed25519_homelab.pub | ssh zahit@192.168.1.59 "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```
```
# ~/.ssh/config (laptop)
Host ubuntu-lab
    HostName 192.168.1.59
    User zahit
    IdentityFile ~/.ssh/id_ed25519_homelab
    IdentitiesOnly yes        # çok key varken "Too many authentication failures" olmasın

Host rocky-lab
    HostName 192.168.1.60
    User zahit
    IdentityFile ~/.ssh/id_ed25519_homelab
    IdentitiesOnly yes
```
Her makinede (host + 2 VM) aynı dosya:
```
# /etc/ssh/sshd_config.d/00-hardening.conf
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AuthenticationMethods publickey
```
```bash
sudo sshd -t && sudo systemctl reload ssh     # Ubuntu
sudo sshd -t && sudo systemctl reload sshd    # Rocky (servis adı farklı)
# laptop'tan test:
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password rocky-lab   # → Permission denied (publickey)
```
- Kendi ayarını başka bir aracın dosyasına (`50-cloud-init.conf`) yazma; kendi dosyanı aç ve önüne geç.
- Rocky'de `~/.ssh` etiketi `ssh_home_t` olmalı (`ls -Z`). Değilse `restorecon -Rv ~/.ssh`.

### 7. Rocky'ye özel
```bash
sudo hostnamectl set-hostname rocky-lab
getenforce                                          # Enforcing
sudo firewall-cmd --permanent --remove-service=cockpit
sudo firewall-cmd --reload
sudo firewall-cmd --list-services                   # runtime
sudo firewall-cmd --permanent --list-services       # kalıcı — ikisini de kontrol et
```
Diğer farklar: yönetici grubu `wheel` (Ubuntu'da `sudo`), paket yöneticisi `dnf`, ağ `NetworkManager`/`nmcli`, minimal kurulumda editör olarak sadece `vi` var.

### 8. RAM ve snapshot
```bash
virsh shutdown rocky-lab
virsh setmaxmem rocky-lab 1536M --config   # önce üst sınır
virsh setmem    rocky-lab 1536M --config
virsh dumpxml rocky-lab | grep -iE '<os|loader|nvram'   # loader/nvram yok → BIOS → internal snapshot olur

virsh snapshot-create-as rocky-lab temiz-kurulum --description "..."
virsh snapshot-list rocky-lab
virsh snapshot-revert rocky-lab temiz-kurulum    # sonrasındaki her değişiklik silinir
virsh snapshot-delete rocky-lab temiz-kurulum    # VM'in şu anki hâli DEĞİŞMEZ, sadece o nokta silinir
```
**Snapshot yedek değildir.** Internal snapshot aynı qcow2 dosyasının içindedir; dosya ya da disk giderse snapshot da gider. Yedek = başka bir diske/makineye bağımsız kopya.

Her iki VM'de geri dönüş testi yapıldı: dosya oluştur → kapat → revert → dosya yok ✓

---

## Sorun günlüğü

| Belirti | Sebep | Çözüm / ders |
|---|---|---|
| `gzip: .../*.tar.gz: No such file` | `chmod 700` klasörde `*`'ı zahit'in kabuğu açamadı | `sudo bash -c '...'` |
| `netplan try`: "reverting custom parameters ... not supported" | Bridge `parameters` geri alınamıyor | Bloğu çıkar; STP zaten kapalı |
| `try`'da Enter 4 saniyede basıldı | Test etmeden onay | Önce yeni pencerede ip/ping/**yeni SSH**, sonra Enter |
| Reboot sonrası terminale `0;8;18M32;...` yazılıyor | tmux öldü, terminal fare modunda kaldı | `reset` ya da yeni sekme |
| ubuntu-lab `.116` aldı | Rezervasyon ilk DHCP kirasından **sonra** girildi, router eski kirayı verdi | Modem reboot (kiralar silindi). Ders: rezervasyonu cihaz ağa girmeden önce gir |
| rocky-lab `.123` aldı | Router'da MAC **yanlış yazılmış** | Router'ın istemci listesiyle `virsh domiflist` karşılaştır → düzelt → `nmcli connection down/up` |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | `known_hosts`'ta aynı IP için eski host key | VM'de `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` ile doğrula → laptop'ta `ssh-keygen -R 192.168.1.59` |
| `qemu-img: Permission denied` | qcow2 `root:root 600`; `virsh` libvirtd üzerinden çalışır, `qemu-img` dosyayı doğrudan açar | `sudo qemu-img ...` ya da `virsh vol-info` |
| Anaconda "unknown error" | Netmask alanında Ctrl+C | `virsh destroy` + `virsh undefine --storage vda`, baştan kur |
| Anaconda dil seçimi uygulanmadı | Numara "Press ENTER to continue" satırına yazıldı | Sayfalamada sadece Enter; numara seçim satırına |
| vi'dan çıkamama | Türkçe Q'da `:` = Shift + `.` | `Esc` → `:wq` / `:q!` |

---

## Kendini test et

1. `stop`, `disable`, `mask` farkı nedir? `disable` diskte neyi siler?
2. `apt-mark manual` atlansaydı `apt autoremove` neyi silerdi?
3. `sudo echo x > /etc/f` neden çalışmaz?
4. İki dosyada çelişen `PasswordAuthentication` varsa hangisi geçerli olur, nasıl kesin öğrenilir?
5. VM `virbr0`'a bağlı olsaydı laptop'tan SSH olur muydu? VM internete çıkar mıydı?
6. `netplan try` neden `apply`'dan güvenli? Enter'a ne zaman basılmalı?
7. Rezervasyon varken VM neden başka IP alabilir? (iki farklı sebep)
8. `firewall-cmd --remove-service=cockpit` (`--permanent` olmadan) çalıştırılırsa `--list-services` ne gösterir, reboot sonra ne olur?
9. Snapshot ile yedek farkı? `snapshot-delete` VM'i değiştirir mi?

---

## Sonraki adımlar
- [ ] `virsh autostart` (VM'ler host ile açılsın mı?)
- [ ] KVM kurulumundan gelen gereksiz GUI kütüphanelerini simülasyonla incele
- [ ] VM disklerini HDD'ye yedekleyen bir betik (snapshot ≠ yedek)
- [ ] RHCSA konuları rocky-lab üzerinde: LVM, kullanıcı/grup, SELinux, systemd, cron, nmcli statik IP, NFS/autofs, podman
