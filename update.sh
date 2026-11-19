#!/bin/bash
set -uo pipefail
if [ "$(id -u)" != 0 ]; then
    U=$(id -un)
    exec doas env "FASD_USER=$U" bash "$0" "$@"
fi
{ [ -x /System/pkg-backend ] || command -v pacman >/dev/null; } || { echo "this script must run on Arch Linux or CachyOS"; exit 1; }
PB=/System/pkg-backend; [ -x "$PB" ] || PB=pacman
FU=${FASD_USER:-${SUDO_USER:-}}
mkdir -p /usr/local/bin /usr/share/fasdeqos /usr/share/fish/vendor_conf.d /usr/share/fish/vendor_completions.d /etc/pacman.d/hooks /var/lib/fasdeqos
cat >/usr/local/bin/pkg <<'EOF_PKG'
#!/bin/sh
PB=/System/pkg-backend; [ -x "$PB" ] || PB=pacman
c=${1:-}
OW='/usr/share/applications/*,/usr/share/icons/*,/etc/grub.d/*,/etc/ostree*'
[ $# -gt 0 ] && shift
case $c in
    install|add) set -- -S --needed --overwrite "$OW" "$@"; R=1 ;;
    remove|delete) set -- -Rns "$@"; R=1 ;;
    update) set -- -Sy; R=1 ;;
    upgrade) exec doas /usr/local/bin/fasd-upgrade ;;
    sysupgrade) set -- -Syu --overwrite "$OW" "$@"; R=1 ;;
    search) set -- -Ss "$@"; R=0 ;;
    list) set -- -Qe; R=0 ;;
    info) set -- -Si "$@"; R=0 ;;
    rebuild) exec doas dkms autoinstall ;;
    *) echo "usage: pkg install|remove|update|upgrade|sysupgrade|search|list|info|rebuild"; exit 1 ;;
esac
if [ "$R" = 1 ] && [ "$(id -u)" != 0 ]; then exec doas "$PB" "$@"; fi
exec "$PB" "$@"
EOF_PKG
chmod 755 /usr/local/bin/pkg
cat >/usr/local/bin/fasd-pkgbackend <<'EOF_FASD_PKGBACKEND'
#!/bin/sh
mkdir -p /System
if [ -f /usr/bin/pacman ] && [ ! -L /usr/bin/pacman ]; then
    mv -f /usr/bin/pacman /System/pkg-backend
fi
exit 0
EOF_FASD_PKGBACKEND
chmod 755 /usr/local/bin/fasd-pkgbackend
cat >/etc/pacman.d/hooks/fasd-pkgbackend.hook <<'EOF_FASD_PKGBACKEND_HOOK'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = pacman

[Action]
Description = Moving the package backend into /System
When = PostTransaction
Exec = /usr/local/bin/fasd-pkgbackend
EOF_FASD_PKGBACKEND_HOOK
chmod 644 /etc/pacman.d/hooks/fasd-pkgbackend.hook
cat >/usr/share/fish/vendor_conf.d/fasd-ls.fish <<'EOF_FASD_LS_FISH'
function ls --wraps ls --description 'ls that keeps the system folders out of /'
    set -l at 0
    test "$PWD" = /; and set at 1
    for a in $argv
        test "$a" = /; and set at 1
    end
    if test $at = 1
        command ls --color=auto --ignore=bin --ignore=boot --ignore=dev --ignore=etc --ignore=home --ignore=lib --ignore=lib64 --ignore=mnt --ignore=opt --ignore=proc --ignore=root --ignore=run --ignore=sbin --ignore=srv --ignore=sys --ignore=tmp --ignore=usr --ignore=var --ignore=lost+found --ignore=swapfile --ignore=.hidden --ignore=.snapshots --ignore=efi $argv
    else
        command ls --color=auto $argv
    end
end
EOF_FASD_LS_FISH
chmod 644 /usr/share/fish/vendor_conf.d/fasd-ls.fish
cat >/usr/local/bin/fasd-upgrade <<'EOF_FASD_UPGRADE'
#!/bin/sh
[ "$(id -u)" = 0 ] || exec doas "$0" "$@"
. /etc/fasdeqos/repo.conf 2>/dev/null
[ -n "${REPO:-}" ] || { echo "no repository configured"; exit 1; }
T=$(mktemp)
got=0
for b in ${BRANCH:-main} master; do
    if curl -fsSL --max-time 30 -H 'Cache-Control: no-cache' "https://raw.githubusercontent.com/$REPO/$b/update.sh" -o "$T"; then
        got=1
        break
    fi
done
if [ "$got" != 1 ]; then
    echo "cannot download update.sh from github.com/$REPO"
    rm -f "$T"
    exit 1
fi
N=$(sha256sum "$T" | cut -d' ' -f1)
O=$(cat /var/lib/fasdeqos/update.sha256 2>/dev/null)
if [ "$N" = "$O" ]; then
    echo "FasdeqOS is up to date"
    rm -f "$T"
    exit 0
fi
mkdir -p /var/lib/fasdeqos
if bash "$T"; then
    printf '%s\n' "$N" >/var/lib/fasdeqos/update.sha256
    rm -f "$T"
    exit 0
fi
echo "update failed"
rm -f "$T"
exit 1
EOF_FASD_UPGRADE
chmod 755 /usr/local/bin/fasd-upgrade
mkdir -p /etc/fasdeqos
[ -f /etc/fasdeqos/repo.conf ] || printf 'REPO=Fasdeq13/fasdeqos-repositoriy\nBRANCH=main\n' >/etc/fasdeqos/repo.conf
cat >/usr/share/fish/vendor_completions.d/pkg.fish <<'EOF_PKG_FISH'
complete -c pkg -f
complete -c pkg -n '__fish_use_subcommand' -a 'install remove update upgrade sysupgrade search list info rebuild'
complete -c pkg -n '__fish_seen_subcommand_from install info' -a '(/System/pkg-backend -Slq)'
complete -c pkg -n '__fish_seen_subcommand_from remove' -a '(/System/pkg-backend -Qeq)'
EOF_PKG_FISH
chmod 644 /usr/share/fish/vendor_completions.d/pkg.fish
cat >/usr/local/bin/fasd-apps <<'EOF_FASD_APPS'
#!/bin/sh
PB=/System/pkg-backend; [ -x "$PB" ] || PB=pacman
D=/Applications
ST=/var/lib/fasdeqos/apps.list
AD=/usr/local/share/applications
ID=/usr/local/share/fasdeqos/icons
mkdir -p "$D/tui" /var/lib/fasdeqos "$AD" "$ID"
touch "$ST"
LS=/var/lib/fasdeqos/layout.list
if [ -d "$D" ] && [ -f "$LS" ]; then
    MISS=$(mktemp)
    while IFS="	" read -r d p; do
        [ -n "$d" ] && [ ! -e "$d" ] && echo "$p" >>"$MISS"
    done <"$LS"
    if [ -s "$MISS" ] && [ "$(wc -l <"$MISS")" -le 2 ]; then
        while IFS= read -r p; do
            "$PB" -Rns --noconfirm "$p" >/dev/null 2>&1
        done <"$MISS"
    fi
    rm -f "$MISS"
fi
NOW=$(mktemp)
find "$D" -type f \( -iname '*.appimage' -o -name '*.pkg.tar.zst' \) | sort >"$NOW"
slug() { basename "$1" | sed 's/\.[Aa]pp[Ii]mage$//;s/\.pkg\.tar\.zst$//' | tr -c 'A-Za-z0-9._\n-' '-' | tr 'A-Z' 'a-z'; }
record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$ST"; }
add_appimage() {
    f=$1
    chmod +x "$f"
    s=$(slug "$f")
    t=$(mktemp -d)
    ( cd "$t" && "$f" --appimage-extract '*.desktop' >/dev/null 2>&1; "$f" --appimage-extract '.DirIcon' >/dev/null 2>&1 )
    src=$(ls "$t"/squashfs-root/*.desktop 2>/dev/null | head -n 1)
    name=$s
    cat=Utility
    [ -n "$src" ] && { n=$(sed -n 's/^Name=//p' "$src" | head -n 1); [ -n "$n" ] && name=$n; c=$(sed -n 's/^Categories=//p' "$src" | head -n 1); [ -n "$c" ] && cat=$c; }
    icon=application-x-executable
    if [ -e "$t/squashfs-root/.DirIcon" ]; then
        cp -L "$t/squashfs-root/.DirIcon" "$ID/$s.png" 2>/dev/null && icon=$ID/$s.png
    fi
    term=false
    case "$f" in "$D"/tui/*) term=true ;; esac
    {
        echo "[Desktop Entry]"
        echo "Type=Application"
        echo "Name=$name"
        echo "Exec=\"$f\" %U"
        echo "Icon=$icon"
        echo "Terminal=$term"
        echo "Categories=$cat;"
    } >"$AD/fasd-$s.desktop"
    rm -rf "$t"
    record "$f" appimage "$s"
}
add_pkg() {
    f=$1
    id=$("$PB" -Qp "$f" 2>/dev/null | awk '{print $1}')
    [ -n "$id" ] || return 0
    case "$f" in
        "$D"/tui/*) ;;
        *) bsdtar -tf "$f" 2>/dev/null | grep -q 'usr/share/applications/.*\.desktop$' || { mv "$f" "$D/tui/" && f=$D/tui/$(basename "$f"); } ;;
    esac
    "$PB" -U --noconfirm --needed "$f" >/dev/null 2>&1 || return 0
    record "$f" pkg "$id"
}
while IFS= read -r f; do
    grep -qF "$f	" "$ST" && continue
    case "$f" in
        *.pkg.tar.zst) add_pkg "$f" ;;
        *) add_appimage "$f" ;;
    esac
done <"$NOW"
find "$D" -type f \( -iname '*.appimage' -o -name '*.pkg.tar.zst' \) | sort >"$NOW"
OLD=$(mktemp)
cp "$ST" "$OLD"
: >"$ST"
while IFS="	" read -r f kind id; do
    if grep -qxF "$f" "$NOW"; then
        printf '%s\t%s\t%s\n' "$f" "$kind" "$id" >>"$ST"
    else
        case "$kind" in
            appimage) rm -f "$AD/fasd-$id.desktop" "$ID/$id.png" ;;
            pkg) "$PB" -Rns --noconfirm "$id" >/dev/null 2>&1 ;;
        esac
    fi
done <"$OLD"
rm -f "$NOW" "$OLD"
update-desktop-database "$AD" >/dev/null 2>&1 || true
exit 0
EOF_FASD_APPS
chmod 755 /usr/local/bin/fasd-apps
cat >/etc/systemd/system/fasd-apps.service <<'EOF_FASD_APPS_SERVICE'
[Unit]
Description=FasdeqOS application integration
[Service]
Type=oneshot
ExecStart=/usr/bin/flock /run/fasd-apps.lock /usr/local/bin/fasd-apps
ExecStartPost=/usr/local/bin/fasd-layout
[Install]
WantedBy=multi-user.target
EOF_FASD_APPS_SERVICE
chmod 644 /etc/systemd/system/fasd-apps.service
cat >/etc/systemd/system/fasd-apps.path <<'EOF_FASD_APPS_PATH'
[Unit]
Description=Watch /Applications
[Path]
PathChanged=/Applications
PathChanged=/Applications/tui
[Install]
WantedBy=multi-user.target
EOF_FASD_APPS_PATH
chmod 644 /etc/systemd/system/fasd-apps.path
cat >/usr/local/bin/fasd-layout <<'EOF_FASD_LAYOUT'
#!/bin/sh
PB=/System/pkg-backend; [ -x "$PB" ] || PB=pacman
exec 9>/run/fasd-apps.lock
flock -n 9 || exit 0
SL=/usr/share/fasdeqos/system.list
ST=/var/lib/fasdeqos/layout.list
mkdir -p /var/lib/fasdeqos /System/Index /System/Kernel /System/Frameworks /Applications/tui /Mount
ln -sfn /usr/bin /System/Index/bin
ln -sfn /usr/include /System/Index/include
ln -sfn /usr/lib /System/Index/lib
ln -sfn /usr/lib /System/Index/libexec
ln -sfn /usr/share /System/Index/share
ln -sfn /etc /System/Settings
ln -sfn /var /System/Variable
ln -sfn /usr/lib/modules /System/Kernel/Modules
ln -sfn /boot /System/Kernel/Boot
ln -sfn /dev /System/Kernel/Devices
ln -sfn /sys /System/Kernel/Objects
ln -sfn /proc /System/Kernel/Status
[ -e /Users ] || ln -s /home /Users
rmdir /mnt /srv /opt /home 2>/dev/null
for fw in gtk3:GTK3 gtk4:GTK4 qt5-base:Qt5 qt6-base:Qt6 mesa:Mesa vulkan-icd-loader:Vulkan; do
    p=${fw%%:*}
    n=${fw##*:}
    if "$PB" -Qq "$p" >/dev/null 2>&1; then
        mkdir -p "/System/Frameworks/$n"
        "$PB" -Q "$p" >"/System/Frameworks/$n/Info"
        ln -sfn /usr/lib "/System/Frameworks/$n/lib"
        ln -sfn /usr/include "/System/Frameworks/$n/include"
        ln -sfn /usr/share "/System/Frameworks/$n/share"
    else
        rm -rf "/System/Frameworks/$n"
    fi
done
printf '%s\n' bin boot dev etc home lib lib64 mnt opt proc root run sbin srv sys tmp usr var lost+found swapfile .snapshots efi >/.hidden
U=$(awk -F: '$3 == 1000 {print $1; exit}' /etc/passwd)
touch "$ST"
if [ -x /usr/local/bin/FasdQuery ] && [ ! -d /Applications/FasdQuery.app ]; then
    mkdir -p /Applications/FasdQuery.app/Contents
    printf 'fasdquery\n' >/Applications/FasdQuery.app/Contents/Info
    ln -sfn /usr/local/share/applications/fasdquery.desktop /Applications/FasdQuery.app/Contents/Desktop
    ln -sfn /usr/local/bin/FasdQuery /Applications/FasdQuery.app/Contents/Executable
    [ -n "$(awk -F: '$3 == 1000 {print $1; exit}' /etc/passwd)" ] && chown -R "$(awk -F: '$3 == 1000 {print $1; exit}' /etc/passwd):$(awk -F: '$3 == 1000 {print $1; exit}' /etc/passwd)" /Applications/FasdQuery.app
fi
WANT=$(mktemp)
for p in $("$PB" -Qeq); do
    grep -qx "$p" "$SL" 2>/dev/null && continue
    files=$("$PB" -Qlq "$p" 2>/dev/null)
    desk=$(printf '%s\n' "$files" | grep '^/usr/share/applications/.*\.desktop$' | head -n 1)
    ver=$("$PB" -Q "$p" | awk '{print $2}')
    if [ -n "$desk" ]; then
        name=$(sed -n 's/^Name=//p' "$desk" | head -n 1)
        [ -n "$name" ] || name=$p
        d="/Applications/$(printf '%s' "$name" | tr '/' '-').app"
        if [ ! -d "$d" ]; then
            mkdir -p "$d/Contents"
            printf '%s %s\n' "$p" "$ver" >"$d/Contents/Info"
            ln -sfn "$desk" "$d/Contents/Desktop"
            ex=$(sed -n 's/^Exec=\([^ ]*\).*/\1/p' "$desk" | head -n 1)
            [ -n "$ex" ] && [ -x "/usr/bin/$ex" ] && ln -sfn "/usr/bin/$ex" "$d/Contents/Executable"
            [ -n "$U" ] && chown -R "$U:$U" "$d"
        fi
        printf '%s\t%s\n' "$d" "$p" >>"$WANT"
    else
        bins=$(printf '%s\n' "$files" | grep '^/usr/bin/[^/]*$')
        [ -n "$bins" ] || continue
        d="/Applications/tui/$p"
        if [ ! -d "$d" ]; then
            mkdir -p "$d"
            printf '%s %s\n' "$p" "$ver" >"$d/Info"
            for b in $bins; do
                ln -sfn "$b" "$d/$(basename "$b")"
            done
            [ -n "$U" ] && chown -R "$U:$U" "$d"
        fi
        printf '%s\t%s\n' "$d" "$p" >>"$WANT"
    fi
done
while IFS="	" read -r d p; do
    [ -n "$d" ] || continue
    grep -qF "$d	" "$WANT" || case "$d" in /Applications/*) rm -rf "$d" ;; esac
done <"$ST"
cat "$WANT" >"$ST"
rm -f "$WANT"
chmod 0777 /Applications /Applications/tui
exit 0
EOF_FASD_LAYOUT
chmod 755 /usr/local/bin/fasd-layout
cat >/usr/share/fasdeqos/system.list <<'EOF_SYSTEM_LIST'
base
linux
linux-firmware
linux-headers
mkinitcpio
dkms
intel-ucode
amd-ucode
networkmanager
wpa_supplicant
bluez
bluez-utils
cups
openssh
pipewire
pipewire-pulse
pipewire-alsa
wireplumber
power-profiles-daemon
niri
noctalia
ly
xwayland-satellite
xdg-desktop-portal-gnome
xdg-desktop-portal-gtk
polkit-gnome
gnome-keyring
xdg-user-dirs
opendoas
btrfs-progs
dosfstools
efibootmgr
pciutils
mesa
vulkan-radeon
vulkan-intel
vulkan-icd-loader
archlinux-keyring
pacman-contrib
fish
nvidia-open-dkms
nvidia-utils
lib32-nvidia-utils
nvidia-settings
ttf-jetbrains-mono
noto-fonts
noto-fonts-emoji
brightnessctl
gvfs
starship
papirus-icon-theme
ttf-jetbrains-mono-nerd
noto-fonts-cjk
cmake
ninja
gcc
qt6-svg
qt6-base
git
curl
nano
fastfetch
EOF_SYSTEM_LIST
chmod 644 /usr/share/fasdeqos/system.list
cat >/etc/pacman.d/hooks/fasd-layout.hook <<'EOF_FASD_LAYOUT_HOOK'
[Trigger]
Operation = Install
Operation = Remove
Operation = Upgrade
Type = Package
Target = *

[Action]
Description = Updating /Applications and /System views
When = PostTransaction
Exec = /usr/local/bin/fasd-layout
EOF_FASD_LAYOUT_HOOK
chmod 644 /etc/pacman.d/hooks/fasd-layout.hook
cat >/usr/local/bin/fasd-first <<'EOF_FASD_FIRST'
#!/bin/sh
icons() {
    for d in /Applications/*.app; do
        [ -d "$d" ] || continue
        gio info -a metadata::custom-icon "$d" 2>/dev/null | grep -q 'custom-icon' && continue
        ic=$(sed -n 's/^Icon=//p' "$d/Contents/Desktop" 2>/dev/null | head -n 1)
        [ -n "$ic" ] || continue
        case "$ic" in
            /*) f=$ic ;;
            *) f=$(find /usr/share/icons/Papirus-Dark/64x64/apps /usr/share/icons/hicolor/scalable/apps /usr/share/icons/hicolor/256x256/apps /usr/share/pixmaps /usr/local/share/icons /usr/local/share/fasdeqos/icons -name "$ic.*" 2>/dev/null | head -n 1) ;;
        esac
        [ -n "$f" ] && gio set "$d" metadata::custom-icon "file://$f" 2>/dev/null
    done
}
M=$HOME/.config/fasdeqos/first-done
if [ ! -f "$M" ]; then
    mkdir -p "$HOME/.config/fasdeqos" "$HOME/.config/gtk-3.0"
    xdg-user-dirs-update
    {
        echo "file:///Applications Applications"
        for k in DOWNLOAD DOCUMENTS PICTURES MUSIC VIDEOS; do
            d=$(xdg-user-dir "$k")
            echo "file://$d $(basename "$d")"
        done
    } >"$HOME/.config/gtk-3.0/bookmarks"
    starship preset catppuccin-powerline -o "$HOME/.config/starship.toml" 2>/dev/null
    gsettings set org.gnome.desktop.interface icon-theme Papirus-Dark
    gsettings set org.gnome.desktop.interface color-scheme prefer-dark
    gsettings set com.github.stunkymonkey.nautilus-open-any-terminal terminal ghostty 2>/dev/null
    /usr/local/bin/fasd-outputs
    touch "$M"
fi
icons
exit 0
EOF_FASD_FIRST
chmod 755 /usr/local/bin/fasd-first
cat >/usr/local/bin/fasd-outputs <<'EOF_FASD_OUTPUTS'
#!/bin/sh
C=$HOME/.config/niri/config.kdl
n=0
while [ $n -lt 100 ]; do
    niri msg version >/dev/null 2>&1 && break
    n=$((n + 1))
    sleep 0.2
done
json=$(niri msg --json outputs 2>/dev/null) || exit 0
printf '%s' "$json" | awk 'BEGIN { RS = "\"name\":\"" }
NR > 1 {
    name = substr($0, 1, index($0, "\"") - 1)
    bw = 0; bh = 0; br = 0
    s = $0
    while (match(s, /"width":[0-9]+,"height":[0-9]+,"refresh_rate":[0-9]+/)) {
        m = substr(s, RSTART, RLENGTH)
        s = substr(s, RSTART + RLENGTH)
        split(m, a, /[^0-9]+/)
        w = a[2] + 0; h = a[3] + 0; r = a[4] + 0
        if (w * h > bw * bh || (w * h == bw * bh && r > br)) { bw = w; bh = h; br = r }
    }
    v = (index($0, "\"vrr_supported\":true") > 0) ? 1 : 0
    if (bw > 0) printf "%s %dx%d@%d.%03d %d\n", name, bw, bh, int(br / 1000), br % 1000, v
}' | while read -r name mode vrr; do
    niri msg output "$name" mode "$mode" >/dev/null 2>&1
    [ -f "$C" ] || continue
    grep -q "^output \"$name\"" "$C" && continue
    {
        printf '\noutput "%s" {\n    mode "%s"\n' "$name" "$mode"
        [ "$vrr" = 1 ] && printf '    variable-refresh-rate on-demand=true\n'
        printf '}\n'
    } >>"$C"
done
exit 0
EOF_FASD_OUTPUTS
chmod 755 /usr/local/bin/fasd-outputs
cat >/usr/local/bin/fasd-fasdquery <<'EOF_FASD_FASDQUERY'
#!/bin/sh
PB=/System/pkg-backend; [ -x "$PB" ] || PB=pacman
[ "$(id -u)" = 0 ] || exec doas "$0" "$@"
T=$(mktemp -d)
"$PB" -S --needed --asdeps --noconfirm cmake ninja gcc qt6-svg git >/dev/null 2>&1
if git clone --depth 1 https://github.com/Fasdeq13/FasdQuery.git "$T/src" >/dev/null 2>&1 \
    && cmake -S "$T/src" -B "$T/b" -G Ninja -DCMAKE_BUILD_TYPE=Release >/dev/null 2>&1 \
    && ninja -C "$T/b" >/dev/null 2>&1; then
    install -Dm755 "$T/b/FasdQuery" /usr/local/bin/FasdQuery
    install -Dm644 "$T/src/app_icon.svg" /usr/share/icons/hicolor/scalable/apps/fasdquery.svg
    mkdir -p /usr/local/share/applications
    printf '[Desktop Entry]\nType=Application\nName=FasdQuery\nComment=File search\nExec=/usr/local/bin/FasdQuery\nIcon=fasdquery\nCategories=Utility;\nTerminal=false\n' >/usr/local/share/applications/fasdquery.desktop
    gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1
    /usr/local/bin/fasd-layout
    rm -rf "$T"
    exit 0
fi
rm -rf "$T"
echo "FasdQuery was not built"
exit 1
EOF_FASD_FASDQUERY
chmod 755 /usr/local/bin/fasd-fasdquery
cat >/usr/local/bin/fastab <<'EOF_FASTAB'
#!/bin/sh
case "${LC_ALL:-${LANG:-en}}" in
    ru*) T1="fastab: выбор дисков для автомонтирования"; T2="Стрелки: выбор   Пробел: отметить   o: параметры   Enter: применить   q: выход"; T3="Нет дисков, которых нет в fstab"; T4="Параметры монтирования (пусто = defaults): "; T5="Готово. Диски смонтируются при следующей загрузке."; T6="Нужен root"; T7="Применено";;
    uk*) T1="fastab: вибір дисків для автомонтування"; T2="Стрілки: вибір   Пробіл: позначити   o: параметри   Enter: застосувати   q: вихід"; T3="Немає дисків, яких нема у fstab"; T4="Параметри монтування (порожньо = defaults): "; T5="Готово. Диски змонтуються при наступному завантаженні."; T6="Потрібен root"; T7="Застосовано";;
    *) T1="fastab: pick disks to mount at boot"; T2="Arrows: move   Space: toggle   o: options   Enter: apply   q: quit"; T3="No disks missing from fstab"; T4="Mount options (empty = defaults): "; T5="Done. Disks will be mounted on next boot."; T6="Root required"; T7="Applied";;
esac
[ "$(id -u)" = 0 ] || exec doas /usr/local/bin/fastab "$@"
FSTAB=/etc/fstab
LIST=$(mktemp)
blkid | while IFS= read -r l; do
    dev=${l%%:*}
    uuid=$(echo "$l" | sed -n 's/.* UUID="\([^"]*\)".*/\1/p')
    typ=$(echo "$l" | sed -n 's/.* TYPE="\([^"]*\)".*/\1/p')
    lab=$(echo "$l" | sed -n 's/.* LABEL="\([^"]*\)".*/\1/p')
    case "$typ" in ext4|ext3|ext2|btrfs|vfat|xfs|f2fs|exfat|ntfs) ;; *) continue;; esac
    [ -n "$uuid" ] || continue
    grep -q "$uuid" "$FSTAB" 2>/dev/null && continue
    cm=$(findmnt -rno TARGET "$dev" 2>/dev/null | head -n 1)
    case "$cm" in /|/boot|/boot/*|/efi|/Users) continue ;; esac
    sz=$(awk -v d="${dev#/dev/}" '$4 == d {printf "%.1fG", $3/1048576}' /proc/partitions)
    echo "$dev|$uuid|$typ|${lab:-${dev#/dev/}}|$sz|defaults|0" >>"$LIST"
done
N=$(wc -l <"$LIST")
[ "$N" -gt 0 ] || { echo "$T3"; rm -f "$LIST"; exit 0; }
OLD=$(stty -g)
trap 'stty "$OLD"; rm -f "$LIST"; printf "\033[?25h"' EXIT INT TERM
stty -icanon -echo min 1 time 0
cur=1
draw() {
    printf '\033[H\033[2J\033[1m%s\033[0m\n%s\n\n' "$T1" "$T2"
    i=1
    while IFS='|' read -r dev uuid typ lab sz opt sel; do
        m=" "; [ "$sel" = 1 ] && m="x"
        p="  "; [ "$i" = "$cur" ] && p="> "
        [ "$i" = "$cur" ] && printf '\033[7m'
        printf '%s[%s] %-12s %-6s %-8s %-16s %s\033[0m\n' "$p" "$m" "$dev" "$typ" "$sz" "$lab" "$opt"
        i=$((i+1))
    done <"$LIST"
}
setfield() {
    awk -F'|' -v OFS='|' -v n="$1" -v f="$2" -v v="$3" 'NR == n {$f = v} {print}' "$LIST" >"$LIST.n" && cat "$LIST.n" >"$LIST"; rm -f "$LIST.n"
}
getfield() { sed -n "${1}p" "$LIST" | cut -d'|' -f"$2"; }
printf '\033[?25l'
while :; do
    draw
    k=$(dd bs=1 count=1 2>/dev/null)
    case "$k" in
        q) exit 0;;
        " ") s=$(getfield "$cur" 7); [ "$s" = 1 ] && s=0 || s=1; setfield "$cur" 7 "$s";;
        o) printf '\033[?25h\n%s' "$T4"; stty "$OLD"; read -r o; stty -icanon -echo min 1 time 0; printf '\033[?25l'; [ -n "$o" ] || o=defaults; setfield "$cur" 6 "$o";;
        j) [ "$cur" -lt "$N" ] && cur=$((cur+1));;
        k) [ "$cur" -gt 1 ] && cur=$((cur-1));;
        "$(printf '\n')"|"")
            while IFS='|' read -r dev uuid typ lab sz opt sel; do
                [ "$sel" = 1 ] || continue
                mp="/Mount/$(echo "$lab" | tr ' /' '__')"
                mkdir -p "$mp"
                umount "$dev" 2>/dev/null
                [ "$typ" = ntfs ] && typ=ntfs3
                pass=2; [ "$typ" = vfat ] || [ "$typ" = exfat ] && pass=0
                echo "UUID=$uuid $mp $typ $opt 0 $pass" >>"$FSTAB"
                mount "$mp" 2>/dev/null
                case "$typ" in ext4|ext3|ext2|btrfs|xfs|f2fs) [ "$(stat -c %u "$mp")" = 0 ] && chown 1000:1000 "$mp" ;; esac
            done <"$LIST"
            printf '\033[H\033[2J%s\n' "$T5"
            exit 0;;
        "$(printf '\033')")
            r=$(dd bs=1 count=2 2>/dev/null)
            case "$r" in
                "[A") [ "$cur" -gt 1 ] && cur=$((cur-1));;
                "[B") [ "$cur" -lt "$N" ] && cur=$((cur+1));;
            esac;;
    esac
done
EOF_FASTAB
chmod 755 /usr/local/bin/fastab
cat >/usr/share/fasdeqos/packages.installed <<'EOF_PACKAGES_INSTALLED'
networkmanager
wpa_supplicant
bluez
bluez-utils
cups
openssh
pipewire
pipewire-pulse
pipewire-alsa
wireplumber
power-profiles-daemon
brightnessctl
niri
xwayland-satellite
noctalia
ly
xdg-desktop-portal-gnome
xdg-desktop-portal-gtk
polkit-gnome
gnome-keyring
gvfs
xdg-user-dirs
fish
starship
ghostty
firefox
nautilus
discord
btop
cava
zed
papirus-icon-theme
opendoas
btrfs-progs
dosfstools
efibootmgr
git
curl
nano
fastfetch
pciutils
mesa
vulkan-radeon
vulkan-intel
vulkan-icd-loader
ttf-jetbrains-mono
ttf-jetbrains-mono-nerd
noto-fonts
noto-fonts-emoji
noto-fonts-cjk
archlinux-keyring
pacman-contrib
zram-generator
EOF_PACKAGES_INSTALLED
chmod 644 /usr/share/fasdeqos/packages.installed

base64 -d >/usr/share/fasdeqos/logo.ansi <<'EOF_LOGO'
ICAgICAgICAgICAbWzM4OzI7MjI1OzIxNDsxODFt4paEG1swbRtbMzg7MjsyMjY7MjAwOzExMG3iloQbWzBtG1szODsyOzIyOTsyMjM7MjA1bRtbNDg7MjsyMjY7MTc3OzUxbeKWgBtbMG0bWzM4OzI7MjI2OzIxNDsxNTltG1s0ODsyOzIyMDsxNDg7MTZt4paAG1swbRtbMzg7MjsyMjc7MjA3OzEyMW0bWzQ4OzI7MjEyOzEyNjsybeKWgBtbMG0bWzM4OzI7MjI5OzIwMjs5Nm0bWzQ4OzI7MjA2OzExMTswbeKWgBtbMG0bWzM4OzI7MjI5OzE5Njs4NG0bWzQ4OzI7MjAxOzk2OzBt4paAG1swbRtbMzg7MjsyMjc7MTkyOzg0bRtbNDg7MjsxOTk7ODI7MG3iloAbWzBtG1szODsyOzIyNTsxOTY7MTA3bRtbNDg7MjsxOTc7NzY7MG3iloAbWzBtG1szODsyOzIyNDsyMDk7MTQ5bRtbNDg7MjsxOTk7ODc7NG3iloAbWzBtG1szODsyOzIyOTsyMjU7MjA1bRtbNDg7MjsyMDk7MTI5OzM0beKWgBtbMG0bWzM4OzI7MjIxOzE3ODsxMDFt4paEG1swbRtbMzg7MjsyMjc7MjE0OzE5M23iloQbWzBtICAbWzM4OzI7MjMxOzIwNDsxOTFt4paEG1swbRtbMzg7MjsyMjQ7MTcyOzE0Mm3iloQbWzBtG1szODsyOzIyMDsxNDE7MTA0beKWhBtbMG0bWzM4OzI7MjIzOzExNTs4NG3iloQbWzBtG1szODsyOzIyNzsxMDI7ODht4paEG1swbRtbMzg7MjsyMjg7MTA5OzEwN23iloQbWzBtG1szODsyOzIyOTsxMzg7MTM3beKWhBtbMG0bWzM4OzI7MjMyOzIwNDsyMDNt4paEG1swbSAgCiAgICAgICAgG1szODsyOzIyMDsyMDY7MTg3beKWhBtbMG0bWzM4OzI7MjI0OzIxMzsyMDJtG1s0ODsyOzIzMDsxOTk7OTdt4paAG1swbRtbMzg7MjsyMjM7MTk4OzExOW0bWzQ4OzI7MjQ0OzIwOTs4NW3iloAbWzBtG1szODsyOzIzMzsxODg7NjFtG1s0ODsyOzI0ODsyMjM7OTlt4paAG1swbRtbMzg7MjsyMzM7MTc3OzUwbRtbNDg7MjsyNTQ7MjI4Ozg0beKWgBtbMG0bWzM4OzI7MjMxOzE2OTs0NG0bWzQ4OzI7MjU1OzIxNzs1N23iloAbWzBtG1szODsyOzIyNjsxNTM7MjltG1s0ODsyOzI1NTsxOTc7MzNt4paAG1swbRtbMzg7MjsyMTM7MTIyOzEzbRtbNDg7MjsyNTQ7MTY5OzE5beKWgBtbMG0bWzM4OzI7MTkyOzgyOzZtG1s0ODsyOzI0OTsxMzA7MTJt4paAG1swbRtbMzg7MjsxNjk7NTM7NG0bWzQ4OzI7MjMyOzgxOzEybeKWgBtbMG0bWzM4OzI7MTU1OzM5OzRtG1s0ODsyOzE5OTs0MTsxMW3iloAbWzBtG1szODsyOzE1MTsyNzs0bRtbNDg7MjsxNTY7MjA7N23iloAbWzBtG1szODsyOzE0ODsxMzs0bRtbNDg7MjsxMjc7MTQ7NW3iloAbWzBtG1szODsyOzE0NTs1OzBtG1s0ODsyOzExNzsxMTs2beKWgBtbMG0bWzM4OzI7MTU0OzMwOzBtG1s0ODsyOzExMDsxOzdt4paAG1swbRtbMzg7MjsxOTY7MTAwOzIzbRtbNDg7Mjs5OTswOzBt4paAG1swbRtbMzg7MjsyMjE7MTcwOzEyNG0bWzQ4OzI7MTQ2OzQwOzBt4paAG1swbRtbMzg7MjsyMDM7MTczOzE2Nm0bWzQ4OzI7MjE2OzEzMTs5MW3iloAbWzBtG1szODsyOzIxMDsxNTc7MTM3bRtbNDg7MjsyMTM7MjA5OzIxMW3iloAbWzBtG1szODsyOzIwOTsxNDY7MTIzbeKWgBtbMG0bWzM4OzI7MTk4OzEyNTsxMDdt4paAG1swbRtbMzg7MjsxOTg7MTAzOzkwbRtbNDg7MjsyMDU7MjAyOzIwMm3iloAbWzBtG1szODsyOzIxNTs2Njs0OW0bWzQ4OzI7MTgzOzE3NDsxNzFt4paAG1swbRtbMzg7MjsyNDA7MjI7OG0bWzQ4OzI7MjIwOzExNzs2OW3iloAbWzBtG1szODsyOzI0NTsxMzsxM20bWzQ4OzI7MjU0OzcxOzlt4paAG1swbRtbMzg7MjsyNDI7Mjg7MzBtG1s0ODsyOzI1NDs1MTs4beKWgBtbMG0bWzM4OzI7MjI2OzE0NTsxNDdtG1s0ODsyOzI0Mzs0NTsyMm3iloAbWzBtG1szODsyOzIxODsxODE7MTc3beKWhBtbMG0KICAgICAgG1szODsyOzIyNzsyMTY7MjEybeKWhBtbMG0bWzM4OzI7MjIzOzIwOTsxOTRtG1s0ODsyOzIzMzsyMDE7OTFt4paAG1swbRtbMzg7MjsyMzY7MjA0Ozg4bRtbNDg7MjsyNTU7MjA1OzE5beKWgBtbMG0bWzM4OzI7MjUxOzIyMDs3NG0bWzQ4OzI7MjUzOzIxMDszNm3iloAbWzBtG1szODsyOzI1NDsyMjc7NzltG1s0ODsyOzI1MjsyMDA7MjRt4paAG1swbRtbMzg7MjsyNTQ7MjE0OzQ2bRtbNDg7MjsyNTE7MTg4OzE5beKWgBtbMG0bWzM4OzI7MjUxOzE5NjsyNm0bWzQ4OzI7MjUxOzE3NjsxNW3iloAbWzBtG1szODsyOzI1MDsxNzk7MTdtG1s0ODsyOzI1MjsxNjY7MTJt4paAG1swbRtbMzg7MjsyNTI7MTY2OzExbRtbNDg7MjsyNDI7MTIzOzEybeKWgBtbMG0bWzM4OzI7MjUyOzE0NDsxMG0bWzQ4OzI7MjIyOzY1Ozht4paAG1swbRtbMzg7MjsyNDc7MTA5OzExbRtbNDg7MjsxOTk7MzA7Nm3iloAbWzBtG1szODsyOzI0Mjs3NTsxNG0bWzQ4OzI7MTgxOzE0OzZt4paAG1swbRtbMzg7MjsyNDA7NDc7MTdtG1s0ODsyOzE2Mzs4OzZt4paAG1swbRtbMzg7MjsyMjU7MjU7MTZtG1s0ODsyOzE0NDs1OzZt4paAG1swbRtbMzg7MjsxODY7MTM7MTJtG1s0ODsyOzEzMzs0OzZt4paAG1swbRtbMzg7MjsxMjA7NTs3bRtbNDg7MjsxMjQ7Mzs3beKWgBtbMG0bWzM4OzI7NzI7NDszbRtbNDg7MjsxMTA7Mzs1beKWgBtbMG0bWzM4OzI7NTY7NTs0bRtbNDg7Mjs3NTszOzRt4paAG1swbRtbMzg7MjszODswOzRtG1s0ODsyOzUwOzU7NG3iloAbWzBtG1szODsyOzEyMTsxMjswbRtbNDg7MjszMjsxOzRt4paAG1swbRtbMzg7MjsyMjM7MTExOzkybRtbNDg7MjsxNTc7NTsybeKWgBtbMG0bWzM4OzI7MjEyOzIwOTsyMDltG1s0ODsyOzIxOTsxMjI7MTIybeKWgBtbMG0bWzM4OzI7MjExOzIxNDsyMTRt4paEG1swbRtbMzg7MjsyMTA7MTk4OzE5N20bWzQ4OzI7MjA3OzE5NDsxOTFt4paAG1swbRtbMzg7MjsxODc7MTc0OzE3OG0bWzQ4OzI7MTc3OzE2MTsxNjJt4paAG1swbRtbMzg7MjsyMDg7MTUxOzEwMW0bWzQ4OzI7MjIwOzE0Njs1N23iloAbWzBtG1szODsyOzI1NTsxMDM7MG0bWzQ4OzI7MjU1OzEyMDswbeKWgBtbMG0bWzM4OzI7MjUxOzk2OzhtG1s0ODsyOzI1MTsxMDg7Nm3iloAbWzBtG1szODsyOzI1Mjs4MDswbRtbNDg7MjsyNTI7MTAwOzBt4paAG1swbRtbMzg7MjsyMTY7MTQwOzExNG0bWzQ4OzI7MjE4OzE1MjsxMTJt4paAG1swbQogICAgIBtbMzg7MjsyMjE7MjEwOzE5NW3iloQbWzBtG1szODsyOzIyNTsyMDQ7MTM3bRtbNDg7MjsyNDI7MTk3OzQ4beKWgBtbMG0bWzM4OzI7MjUzOzE5NjsxMm0bWzQ4OzI7MjUzOzE3NTswbeKWgBtbMG0bWzM4OzI7MjUxOzE4ODs4bRtbNDg7MjsyNTA7MTcxOzExbeKWgBtbMG0bWzM4OzI7MjUxOzE4NjsxNW0bWzQ4OzI7MjUxOzE2MzsxMG3iloAbWzBtG1szODsyOzI1MTsxNzY7MTRtG1s0ODsyOzI1MDsxNTI7OG3iloAbWzBtG1szODsyOzI1MTsxNjY7MTBtG1s0ODsyOzI1MTsxNDY7OW3iloAbWzBtG1szODsyOzI1MTsxNTQ7MTJtG1s0ODsyOzIzMDs3Mjs4beKWgBtbMG0bWzM4OzI7MjMyOzg2OzEwbRtbNDg7MjsyMTM7MjU7Mm3iloAbWzBtG1szODsyOzIxMjszMDs0bRtbNDg7MjsyMTA7Mjg7NW3iloAbWzBtG1szODsyOzIwMjsyMDs1bRtbNDg7MjsyMDI7MjI7Nm3iloAbWzBtG1szODsyOzE5MjsxNzs1bRtbNDg7MjsxOTM7MTU7Nm3iloAbWzBtG1szODsyOzE4MDsxMjs2bRtbNDg7MjsxODE7MTA7Nm3iloAbWzBtG1szODsyOzE2Nzs4OzZtG1s0ODsyOzE3MDs3OzZt4paAG1swbRtbMzg7MjsxNTA7NDs2bRtbNDg7MjsxNjY7NTs2beKWgBtbMG0bWzM4OzI7MTMzOzM7Nm0bWzQ4OzI7MTY3OzQ7N23iloAbWzBtG1szODsyOzEyMzs0OzdtG1s0ODsyOzE2Nzs0Ozdt4paAG1swbRtbMzg7MjsxMjU7NDs2bRtbNDg7MjsxNjU7Mzs2beKWgBtbMG0bWzM4OzI7MTMxOzM7Nm0bWzQ4OzI7MTM4OzM7NW3iloAbWzBtG1szODsyOzg1OzM7NW0bWzQ4OzI7ODk7Mzs1beKWgBtbMG0bWzM4OzI7NDc7NTs1bRtbNDg7Mjs4MTszOzVt4paAG1swbRtbMzg7Mjs2NDswOzNtG1s0ODsyOzY1OzU7N23iloAbWzBtG1szODsyOzE5ODsxNjsyNG0bWzQ4OzI7MTQ0OzA7MG3iloAbWzBtG1szODsyOzE5NjsxNjM7MTYybRtbNDg7MjsxOTI7NzU7Nzdt4paAG1swbRtbMzg7MjsxOTI7MTgzOzE4NW0bWzQ4OzI7MTc1OzE1OTsxNTNt4paAG1swbRtbMzg7MjsxODQ7MTUwOzExNm0bWzQ4OzI7MjMxOzE3MTs0OW3iloAbWzBtG1szODsyOzI0ODsxNTQ7MTFtG1s0ODsyOzI1NTsxNDU7MG3iloAbWzBtG1szODsyOzI1MzsxMjQ7Mm0bWzQ4OzI7MjUwOzEyMDs3beKWgBtbMG0bWzM4OzI7MjUzOzExNDsybRtbNDg7MjsyNTU7MTIxOzBt4paAG1swbRtbMzg7MjsyNDc7MTIwOzdtG1s0ODsyOzIyODsxNDk7NTZt4paAG1swbRtbMzg7MjsyMTE7MTc3OzE1Mm0bWzQ4OzI7MjE4OzIwOTsyMTBt4paAG1swbQogICAgIBtbMzg7MjsyMjM7MjAxOzEzNW0bWzQ4OzI7MjMzOzIwMTs3Nm3iloAbWzBtG1szODsyOzI1MzsxODQ7Nm0bWzQ4OzI7MjU0OzE4MDswbeKWgBtbMG0bWzM4OzI7MjUwOzE2MTs3bRtbNDg7MjsyNDk7MTU1Ozht4paAG1swbRtbMzg7MjsyNDk7MTUzOzdtG1s0ODsyOzI0OTsxMzg7N23iloAbWzBtG1szODsyOzI0OTsxNDA7Nm0bWzQ4OzI7MjQ4OzEyMzs3beKWgBtbMG0bWzM4OzI7MjUxOzEzNzs3bRtbNDg7MjsyNDc7MTA1Ozdt4paAG1swbRtbMzg7MjsyMzg7ODY7OG0bWzQ4OzI7MjI4OzM4OzRt4paAG1swbRtbMzg7MjsyMTk7MjY7M20bWzQ4OzI7MjIxOzI1OzNt4paAG1swbRtbMzg7MjsyMTY7MzA7NG0bWzQ4OzI7MjE2OzIxOzVt4paAG1swbRtbMzg7MjsyMDk7MjE7NW0bWzQ4OzI7MjEyOzE1OzRt4paAG1swbRtbMzg7MjsyMDE7MTU7NW0bWzQ4OzI7MjI4OzE1OzRt4paAG1swbRtbMzg7MjsxOTg7MTI7NW0bWzQ4OzI7MjMwOzE0OzVt4paAG1swbRtbMzg7MjsyMTA7MTE7NW0bWzQ4OzI7MTgyOzExOzVt4paAG1swbRtbMzg7MjsyMTY7MTA7Nm0bWzQ4OzI7MTA3Ozc7NW3iloAbWzBtG1szODsyOzE5Mjs3OzhtG1s0ODsyOzUxOzM7NG3iloAbWzBtG1szODsyOzE0OTs1OzZtG1s0ODsyOzMzOzM7NW3iloAbWzBtG1szODsyOzEwNDszOzVtG1s0ODsyOzQwOzI7NW3iloAbWzBtG1szODsyOzcwOzM7NW0bWzQ4OzI7MzI7Mzs1beKWgBtbMG0bWzM4OzI7MzQ7Mzs0bRtbNDg7MjszNjs0OzVt4paAG1swbRtbMzg7MjszMDsyOzRtG1s0ODsyOzQ4OzM7Nm3iloAbWzBtG1szODsyOzM3OzM7NG0bWzQ4OzI7NTY7Njs3beKWgBtbMG0bWzM4OzI7NTA7Njs1bRtbNDg7Mjs2NjswOzFt4paAG1swbRtbMzg7Mjs4MDswOzBtG1s0ODsyOzExMzs0OzZt4paAG1swbRtbMzg7MjsxNjc7MTQ7MjFtG1s0ODsyOzIxNjsxMzc7NDRt4paAG1swbRtbMzg7MjsyMjQ7MTcwOzczbRtbNDg7MjsyNTU7MTgyOzE3beKWgBtbMG0bWzM4OzI7MjU1OzE2Mjs3bRtbNDg7MjsyNTQ7MTM3OzRt4paAG1swbRtbMzg7MjsyNTI7MTMwOzRtG1s0ODsyOzI0ODsxMTc7OG3iloAbWzBtG1szODsyOzI1NTsxMzE7Mm0bWzQ4OzI7MjQ2OzcwOzNt4paAG1swbRtbMzg7MjsyNDM7MTIxOzdtG1s0ODsyOzIwNDsxMTI7OTdt4paAG1swbRtbMzg7MjsyMDQ7MTY4OzE0N23iloAbWzBtIAogICAgG1szODsyOzIyNzsyMTg7MjA3bRtbNDg7MjsyMjQ7MjEyOzE4NW3iloAbWzBtG1szODsyOzI0MTsyMDc7NDBtG1s0ODsyOzI0NjsyMTI7MjFt4paAG1swbRtbMzg7MjsyNTQ7MTgxOzBtG1s0ODsyOzI1MzsxODU7Mm3iloAbWzBtG1szODsyOzI1MDsxNTE7OG0bWzQ4OzI7MjUwOzE1Mjs2beKWgBtbMG0bWzM4OzI7MjQ5OzEyNzs2bRtbNDg7MjsyNDk7MTI0OzZt4paAG1swbRtbMzg7MjsyNDg7MTA5OzZtG1s0ODsyOzI0OTsxMDA7NW3iloAbWzBtG1szODsyOzI0NTs3Nzs2bRtbNDg7MjsyNDc7NzM7NW3iloAbWzBtG1szODsyOzIzMTsyNzszbRtbNDg7MjsyNDU7Mzc7M23iloAbWzBtG1szODsyOzIyNzsyMTsybRtbNDg7MjsyNTU7MzY7NG3iloAbWzBtG1szODsyOzIzNjsxOTszbRtbNDg7MjsyMjA7Mjc7NG3iloAbWzBtG1szODsyOzI0NDsyMDs1bRtbNDg7MjsxMTY7MTA7NG3iloAbWzBtG1szODsyOzE4NjsxNjs2bRtbNDg7Mjs1MTsyOzRt4paAG1swbRtbMzg7Mjs5Mjs3OzRtG1s0ODsyOzc0OzE7NW3iloAbWzBtG1szODsyOzQyOzM7NW0bWzQ4OzI7MTIwOzM7MTNt4paAG1swbRtbMzg7Mjs1NjsyOzdtG1s0ODsyOzEwODszOzEybeKWgBtbMG0bWzM4OzI7ODE7Mzs5bRtbNDg7Mjs3MjszOzht4paAG1swbRtbMzg7Mjs4NjszOzEwbRtbNDg7Mjs2MDsyOzdt4paAG1swbRtbMzg7Mjs3MjsyOzhtG1s0ODsyOzQ2OzQ7Nm3iloAbWzBtG1szODsyOzQ0OzM7NW0bWzQ4OzI7NDg7Njs1beKWgBtbMG0bWzM4OzI7NTQ7NDs2bRtbNDg7Mjs1OTswOzBt4paAG1swbRtbMzg7Mjs2Mzs1OzdtG1s0ODsyOzkzOzA7MG3iloAbWzBtG1szODsyOzc3OzA7MG0bWzQ4OzI7MTg0Ozk1OzQwbeKWgBtbMG0bWzM4OzI7MTQzOzMxOzE1bRtbNDg7MjsyNDg7MjA4Ozc0beKWgBtbMG0bWzM4OzI7MjQwOzE4Mzs1OW0bWzQ4OzI7MjMyOzE0NzszOW3iloAbWzBtG1szODsyOzI1NTsyMDU7MzhtG1s0ODsyOzIwMzs0MTsxNm3iloAbWzBtG1szODsyOzIzMjsxMTE7MTFtG1s0ODsyOzE5NDswOzEzbeKWgBtbMG0bWzM4OzI7MjE5OzUwOzEzbRtbNDg7MjsyMTg7MDsxMm3iloAbWzBtG1szODsyOzIzMzs4OzEwbRtbNDg7MjsyMTA7ODc7OTNt4paAG1swbRtbMzg7MjsyMDk7Nzc7ODZtG1s0ODsyOzIxNDsyMTE7MjA4beKWgBtbMG0bWzM4OzI7MjE2OzIxMDsyMTFt4paAG1swbSAgCiAgICAbWzM4OzI7MjIyOzIwODsxNzJtG1s0ODsyOzIyMjsyMTI7MTgxbeKWgBtbMG0bWzM4OzI7MjQ3OzIxMTsxM20bWzQ4OzI7MjQ2OzIwMTsxM23iloAbWzBtG1szODsyOzI1NDsxOTU7NG0bWzQ4OzI7MjUzOzE3OTsybeKWgBtbMG0bWzM4OzI7MjUwOzE2Mjs1bRtbNDg7MjsyNTI7MTg0OzZt4paAG1swbRtbMzg7MjsyNTA7MTMyOzRtG1s0ODsyOzI1NDsxNjU7NG3iloAbWzBtG1szODsyOzI1MDsxMDc7NG0bWzQ4OzI7MjUyOzEzMzs1beKWgBtbMG0bWzM4OzI7MjU1Ozk0OzVtG1s0ODsyOzIxNjs4MDs3beKWgBtbMG0bWzM4OzI7MjUwOzcwOzdtG1s0ODsyOzEzODsyMDs1beKWgBtbMG0bWzM4OzI7MTcwOzI5OzVtG1s0ODsyOzEwNTswOzJt4paAG1swbRtbMzg7Mjs4Mzs1OzRtG1s0ODsyOzE0MjszOzVt4paAG1swbRtbMzg7Mjs4MTswOzVtG1s0ODsyOzE5MDs0OzExbeKWgBtbMG0bWzM4OzI7MTMyOzM7MTFtG1s0ODsyOzE1Nzs0OzE1beKWgBtbMG0bWzM4OzI7MTQ4OzM7MTVtG1s0ODsyOzU1OzM7N23iloAbWzBtG1szODsyOzgyOzM7MTBtG1s0ODsyOzQ1OzM7NW3iloAbWzBtG1szODsyOzQ0OzM7Nm0bWzQ4OzI7NzM7Njs4beKWgBtbMG0bWzM4OzI7NTc7NDs3bRtbNDg7Mjs5MzszOzht4paAG1swbRtbMzg7Mjs3MDs2OzhtG1s0ODsyOzg0OzA7M23iloAbWzBtG1szODsyOzU2OzA7Mm0bWzQ4OzI7MTEwOzIyOzEybeKWgBtbMG0bWzM4OzI7Nzg7MDswbRtbNDg7MjsxOTI7NzU7Mzlt4paAG1swbRtbMzg7MjsxMzg7NDI7MjFtG1s0ODsyOzIzNTs5MDs1M23iloAbWzBtG1szODsyOzIxNDsxMzM7NjRtG1s0ODsyOzIwNjszNTszMW3iloAbWzBtG1szODsyOzIyNDsxMzk7NjRtG1s0ODsyOzE3NjswOzEybeKWgBtbMG0bWzM4OzI7MTg5OzQwOzIzbRtbNDg7MjsxOTA7MDsxOW3iloAbWzBtG1szODsyOzE4MTswOzEzbRtbNDg7MjsyMTY7MTA7MjZt4paAG1swbRtbMzg7MjsyMTQ7MDsxOG0bWzQ4OzI7MjA2OzI7MTFt4paAG1swbRtbMzg7MjsyMjg7MTg7MzFtG1s0ODsyOzE5Mzs4OTs5NW3iloAbWzBtG1szODsyOzIwODsxMjI7MTI0beKWgBtbMG0gICAgIAogICAbWzM4OzI7MjEzOzEzMTsxMTJt4paEG1swbRtbMzg7MjsyMDU7MTc0OzE1Mm0bWzQ4OzI7MTg5OzE1NTsxNTBt4paAG1swbRtbMzg7MjsyNDE7MTkwOzI2bRtbNDg7MjsyMzM7MTg0OzUzbeKWgBtbMG0bWzM4OzI7MjUyOzE0MTswbRtbNDg7MjsyNTM7MTM1OzBt4paAG1swbRtbMzg7MjsyMzk7MTA5OzVtG1s0ODsyOzI0MDs4Mjs2beKWgBtbMG0bWzM4OzI7MjIyOzkxOzVtG1s0ODsyOzIyMjszODszbeKWgBtbMG0bWzM4OzI7MTg5OzQyOzRtG1s0ODsyOzIxMDsyMzs0beKWgBtbMG0bWzM4OzI7MTYxOzY7NG0bWzQ4OzI7MjA2OzE5OzVt4paAG1swbRtbMzg7MjsxNzM7NjszbRtbNDg7MjsxOTU7MTU7Nm3iloAbWzBtG1szODsyOzE5Njs5OzVtG1s0ODsyOzE5MDsxMDs1beKWgBtbMG0bWzM4OzI7MjIxOzc7Nm0bWzQ4OzI7MTQ1Ozg7NG3iloAbWzBtG1szODsyOzE2NDs1OzhtG1s0ODsyOzQ1OzE7MW3iloAbWzBtG1szODsyOzQ0OzQ7NG0bWzQ4OzI7NjU7MDsxbeKWgBtbMG0bWzM4OzI7NTY7Njs1bRtbNDg7MjsxMDQ7Mzs0beKWgBtbMG0bWzM4OzI7ODM7Mjs1bRtbNDg7MjsxNDg7Mjk7MTBt4paAG1swbRtbMzg7MjsxMDU7MDs1bRtbNDg7MjsyMDE7NzI7MTVt4paAG1swbRtbMzg7MjsxNDA7MTg7MTFtG1s0ODsyOzI0MDs5ODsxN23iloAbWzBtG1szODsyOzE3OTs2MjsyNG0bWzQ4OzI7MjU0Ozc3OzEzbeKWgBtbMG0bWzM4OzI7MjM4OzgzOzMzbRtbNDg7MjsyNTE7MzU7OG3iloAbWzBtG1szODsyOzI0Nzs0MzsyMm0bWzQ4OzI7MjUyOzE1OzE0beKWgBtbMG0bWzM4OzI7MjI1OzA7MTNtG1s0ODsyOzI0MzsxMjsyM23iloAbWzBtG1szODsyOzIxNTswOzIwbRtbNDg7MjsxOTg7NzsyMm3iloAbWzBtG1szODsyOzIxNTs4OzI2bRtbNDg7MjsxMzE7NDsxNm3iloAbWzBtG1szODsyOzE5MTs2OzIybRtbNDg7Mjs4NTszOzEwbeKWgBtbMG0bWzM4OzI7MTM3Ozc7MTdtG1s0ODsyOzExNDszOzE0beKWgBtbMG0bWzM4OzI7MTUzOzA7Nm0bWzQ4OzI7MjA0OzI7MTdt4paAG1swbRtbMzg7MjsyMDE7MTEyOzExOG0bWzQ4OzI7MjA2OzE0MjsxNDVt4paAG1swbSAgICAgIAogG1szODsyOzIyNDsxODg7MTQwbeKWhBtbMG0bWzM4OzI7MjI2OzEzNzs5Nm0bWzQ4OzI7MjM4Ozk3OzRt4paAG1swbRtbMzg7MjsyMDY7MTExOzg1bRtbNDg7MjsyMDM7MTczOzE2N23iloAbWzBtG1szODsyOzE5ODsxOTk7MjA5bRtbNDg7MjsyMTY7MjEzOzIxMm3iloAbWzBtG1szODsyOzIxNDsxNzE7ODdtG1s0ODsyOzE5ODsxNzY7MTQ1beKWgBtbMG0bWzM4OzI7MjU0OzE0MzswbRtbNDg7MjsyNDY7MTYxOzEybeKWgBtbMG0bWzM4OzI7MjQ2OzkzOzExbRtbNDg7MjsyNTI7MTA5OzExbeKWgBtbMG0bWzM4OzI7MjQ5OzYyOzEwbRtbNDg7MjsyNTI7NjQ7MTVt4paAG1swbRtbMzg7MjsyMDU7MjY7OW0bWzQ4OzI7MjExOzE3OzEwbeKWgBtbMG0bWzM4OzI7MTU5Ozc7Nm0bWzQ4OzI7MTg3OzI7NG3iloAbWzBtG1szODsyOzE1NDs0OzZtG1s0ODsyOzE5MzsxODs3beKWgBtbMG0bWzM4OzI7MTM0OzA7NG0bWzQ4OzI7MTYxOzQ0OzExbeKWgBtbMG0bWzM4OzI7NzM7MDsybRtbNDg7MjsxOTQ7ODc7MTRt4paAG1swbRtbMzg7MjsxMDk7MTU7Nm0bWzQ4OzI7MjQwOzEyMjsxM23iloAbWzBtG1szODsyOzE2NTs1MTsxMW0bWzQ4OzI7MjU1OzEzMzs2beKWgBtbMG0bWzM4OzI7MjE0OzkzOzEzbRtbNDg7MjsyNTU7MTI0OzRt4paAG1swbRtbMzg7MjsyNDc7MTE4OzExbRtbNDg7MjsyNTU7MTAyOzRt4paAG1swbRtbMzg7MjsyNTU7MTA5OzZtG1s0ODsyOzIzMjs3Mzs3beKWgBtbMG0bWzM4OzI7MjU1Ozc3OzVtG1s0ODsyOzE4NTs0MzsxMW3iloAbWzBtG1szODsyOzI1NTs0ODsxMG0bWzQ4OzI7MTI0OzE4OzExbeKWgBtbMG0bWzM4OzI7MjM0OzI4OzE2bRtbNDg7Mjs3NDs1OzEwbeKWgBtbMG0bWzM4OzI7MTgwOzEzOzE2bRtbNDg7Mjs1NDsyOzlt4paAG1swbRtbMzg7MjsxMTA7NTsxMm0bWzQ4OzI7NjY7MjsxMG3iloAbWzBtG1szODsyOzY4OzM7OW0bWzQ4OzI7OTU7NDsxM23iloAbWzBtG1szODsyOzczOzM7MTBtG1s0ODsyOzEyMjsyOzE0beKWgBtbMG0bWzM4OzI7MTE0OzQ7MTVtG1s0ODsyOzE2ODsyOzIwbeKWgBtbMG0bWzM4OzI7MTgzOzA7MTVtG1s0ODsyOzIzNzs5Ozht4paAG1swbRtbMzg7MjsyMjY7Mjk7MzNtG1s0ODsyOzIxNDs5MDs3Nm3iloAbWzBtG1szODsyOzIwNDsxODA7MTc5beKWgBtbMG0gICAgICAKG1szODsyOzIxODsyMDk7MTk4bRtbNDg7MjsyMTg7MjAwOzEzNG3iloAbWzBtG1szODsyOzI0MDsxNjk7MjdtG1s0ODsyOzI1MTsxOTA7MW3iloAbWzBtG1szODsyOzI0MzsxMjQ7MTFtG1s0ODsyOzI1MzsxNDk7MG3iloAbWzBtG1szODsyOzE5NTsxNzA7MTY3bRtbNDg7MjsyMzA7MTUxOzQ1beKWgBtbMG0bWzM4OzI7MjA1OzE5ODsyMDNtG1s0ODsyOzIxMTsxNzQ7OTBt4paAG1swbRtbMzg7MjsxODU7MTcwOzE4MW0bWzQ4OzI7MjA3OzE3Nzs5Mm3iloAbWzBtG1szODsyOzIwODsxNTc7NzNtG1s0ODsyOzIxNjsxODA7Njlt4paAG1swbRtbMzg7MjsyNTQ7MTQwOzdtG1s0ODsyOzI1MzsyMDQ7Mjht4paAG1swbRtbMzg7MjsyNTA7ODk7MjBtG1s0ODsyOzI1NTsxODk7MjFt4paAG1swbRtbMzg7MjsyNDY7Nzk7MjJtG1s0ODsyOzI1NTsxNzg7MTNt4paAG1swbRtbMzg7MjsyNDA7MTA0OzE4bRtbNDg7MjsyNTU7MTU2OzZt4paAG1swbRtbMzg7MjsyNTA7MTM3OzE1bRtbNDg7MjsyMzI7MTIwOzNt4paAG1swbRtbMzg7MjsyNTU7MTQ5OzltG1s0ODsyOzE5Mjs4Mjs0beKWgBtbMG0bWzM4OzI7MjU1OzE0MTs0bRtbNDg7MjsxNDA7NDk7Nm3iloAbWzBtG1szODsyOzI1NTsxMTc7M20bWzQ4OzI7ODM7MjI7Nm3iloAbWzBtG1szODsyOzIyMDs5MDs1bRtbNDg7MjszOTs0OzZt4paAG1swbRtbMzg7MjsxNjQ7NjA7Nm0bWzQ4OzI7MjI7MDs1beKWgBtbMG0bWzM4OzI7MTA0OzMwOzdtG1s0ODsyOzMzOzA7N23iloAbWzBtG1szODsyOzYwOzg7OW0bWzQ4OzI7NTI7Mjs5beKWgBtbMG0bWzM4OzI7NDE7MDs4bRtbNDg7Mjs3MTszOzEwbeKWgBtbMG0bWzM4OzI7NTA7MDs4bRtbNDg7Mjs4NDszOzExbeKWgBtbMG0bWzM4OzI7Njk7MjsxMG0bWzQ4OzI7OTY7MzsxMm3iloAbWzBtG1szODsyOzg2OzM7MTJtG1s0ODsyOzEyMjszOzE0beKWgBtbMG0bWzM4OzI7MTA5OzM7MTRtG1s0ODsyOzE1NDsyOzE2beKWgBtbMG0bWzM4OzI7MTM3OzM7MTVtG1s0ODsyOzE3Nzs1OzE2beKWgBtbMG0bWzM4OzI7MTgyOzU7MTltG1s0ODsyOzE5MDs0OzEybeKWgBtbMG0bWzM4OzI7MjM0OzE3OzE1bRtbNDg7MjsyMjg7NDI7MG3iloAbWzBtG1szODsyOzI0NTs1ODsxOW0bWzQ4OzI7MjA3OzEzMDs5Mm3iloAbWzBtG1szODsyOzE5NzsxNTk7MTUwbRtbNDg7MjsyMTc7MjEzOzIxNm3iloAbWzBtICAgICAgIAobWzM4OzI7MjE5OzIwMzsxMjNtG1s0ODsyOzIxMzsxOTg7MTc3beKWgBtbMG0bWzM4OzI7MjU1OzIyOTs4bRtbNDg7MjsyMzk7MjI5OzU1beKWgBtbMG0bWzM4OzI7MjUyOzIwMjsxMm0bWzQ4OzI7MjU1OzI1MDszNG3iloAbWzBtG1szODsyOzI1NTsyMDU7NG0bWzQ4OzI7MjU1OzIyNjszNW3iloAbWzBtG1szODsyOzI1NTsyMjg7NG0bWzQ4OzI7MjU1OzE4NjsyMm3iloAbWzBtG1szODsyOzI1NTsyMzU7N20bWzQ4OzI7MjUyOzEyNjs5beKWgBtbMG0bWzM4OzI7MjU1OzIxNjs2bRtbNDg7MjsyMzM7NjQ7MG3iloAbWzBtG1szODsyOzI0MjsxNzI7OG0bWzQ4OzI7MjAxOzE4OzBt4paAG1swbRtbMzg7MjsyMzQ7MTIwOzVtG1s0ODsyOzE5NzswOzBt4paAG1swbRtbMzg7MjsxOTY7Njc7NG0bWzQ4OzI7MTg4OzA7MG3iloAbWzBtG1szODsyOzEzODsyOTs0bRtbNDg7MjsxMzQ7MDszbeKWgBtbMG0bWzM4OzI7OTI7Nzs2bRtbNDg7Mjs4NDszOzdt4paAG1swbRtbMzg7Mjs1NTswOzZtG1s0ODsyOzYwOzQ7Nm3iloAbWzBtG1szODsyOzMxOzA7NW0bWzQ4OzI7NjA7NTs3beKWgBtbMG0bWzM4OzI7MzA7MDs1bRtbNDg7Mjs2NTs0Ozht4paAG1swbRtbMzg7Mjs0NDsyOzZtG1s0ODsyOzcwOzQ7OW3iloAbWzBtG1szODsyOzU4OzQ7OG0bWzQ4OzI7ODA7MzsxMG3iloAbWzBtG1szODsyOzY2OzM7OW0bWzQ4OzI7MTAwOzI7MTFt4paAG1swbRtbMzg7Mjs4MDszOzEwbRtbNDg7MjsxMDM7MzsxMW3iloAbWzBtG1szODsyOzk3OzM7MTNtG1s0ODsyOzg1OzI7N23iloAbWzBtG1szODsyOzEwMzszOzEybRtbNDg7Mjs4MjszOzRt4paAG1swbRtbMzg7MjsxMTQ7MzsxMW0bWzQ4OzI7OTY7NTszbeKWgBtbMG0bWzM4OzI7MTIyOzM7OW0bWzQ4OzI7MTI5OzU7NG3iloAbWzBtG1szODsyOzEzMjs0OzdtG1s0ODsyOzE4NTsxMzswbeKWgBtbMG0bWzM4OzI7MTU4OzI7NG0bWzQ4OzI7MjM4OzY0OzBt4paAG1swbRtbMzg7MjsyMDk7MzY7MG0bWzQ4OzI7MjIxOzEzNzs2Nm3iloAbWzBtG1szODsyOzIxMTsxMjE7NjJtG1s0ODsyOzE5NDsxNzg7MTczbeKWgBtbMG0bWzM4OzI7MTk4OzE4NTsxODRt4paAG1swbSAgICAgICAgCiAbWzM4OzI7MjE0OzE5NzsxNzJt4paAG1swbRtbMzg7MjsyMjE7MTk1Ozk2beKWgBtbMG0bWzM4OzI7MjMzOzE4NDs1OW0bWzQ4OzI7MjE0OzIwMjsxOTZt4paAG1swbRtbMzg7MjsyMzc7MTUzOzM4bRtbNDg7MjsyMTQ7MjA0OzE5M23iloAbWzBtG1szODsyOzIzNjsxMTU7MzRtG1s0ODsyOzIxNjsyMDk7MTk5beKWgBtbMG0bWzM4OzI7MjI4OzkyOzQzbRtbNDg7MjsyMjA7MjE1OzIxMm3iloAbWzBtG1szODsyOzIxNTs5MDs2NG3iloAbWzBtG1szODsyOzIwNzsxMTg7MTA1beKWgBtbMG0bWzM4OzI7MjAxOzEwNDs5OW3iloAbWzBtG1szODsyOzE2NDsxMjsxMm0bWzQ4OzI7MTk4OzE1NjsxNTZt4paAG1swbRtbMzg7MjsxMTk7MDswbRtbNDg7MjsxODc7NTc7NTht4paAG1swbRtbMzg7Mjs5NjsyOzhtG1s0ODsyOzE3NDs2Ozlt4paAG1swbRtbMzg7Mjs5Mjs1OzExbRtbNDg7MjsxNjQ7MDswbeKWgBtbMG0bWzM4OzI7OTY7NTsxMG0bWzQ4OzI7MTY2OzA7MW3iloAbWzBtG1szODsyOzExMDs0OzExbRtbNDg7MjsxNjQ7MDszbeKWgBtbMG0bWzM4OzI7MTIxOzQ7MTFtG1s0ODsyOzExODswOzBt4paAG1swbRtbMzg7Mjs5OTszOzhtG1s0ODsyOzExMTswOzBt4paAG1swbRtbMzg7Mjs3Njs0OzRtG1s0ODsyOzE0OTs0OzBt4paAG1swbRtbMzg7Mjs5MTs0OzNtG1s0ODsyOzE5NjsxOTswbeKWgBtbMG0bWzM4OzI7MTMyOzU7M20bWzQ4OzI7MjMxOzUxOzBt4paAG1swbRtbMzg7MjsxODM7MTU7MW0bWzQ4OzI7MjQxOzk4OzEybeKWgBtbMG0bWzM4OzI7MjMxOzQ2OzBtG1s0ODsyOzIxODsxNDA7NjFt4paAG1swbRtbMzg7MjsyNDU7MTA3OzE2bRtbNDg7MjsxODc7MTU3OzEzMG3iloAbWzBtG1szODsyOzIwNjsxNTA7ODhtG1s0ODsyOzE5OTsxODY7MTkwbeKWgBtbMG0bWzM4OzI7MTk0OzE3OTsxNzZt4paAG1swbSAgICAgICAgICAKICAgICAgICAgICAbWzM4OzI7MjEyOzIwOTsyMDht4paAG1swbRtbMzg7MjsxOTg7MTUyOzE1MW3iloAbWzBtG1szODsyOzE5Njs5NTs5M23iloAbWzBtG1szODsyOzIwNDs1OTs1Nm0bWzQ4OzI7MjAzOzE5OTsxOTht4paAG1swbRtbMzg7MjsxODk7Mzg7MzBtG1s0ODsyOzE5NjsxNzc7MTczbeKWgBtbMG0bWzM4OzI7MTc2OzM4OzIxbRtbNDg7MjsxOTU7MTY4OzE2MW3iloAbWzBtG1szODsyOzE5Mzs1MTsyNG0bWzQ4OzI7MTkyOzE2NzsxNTht4paAG1swbRtbMzg7MjsyMTA7NzU7MzJtG1s0ODsyOzE5MTsxNzY7MTY5beKWgBtbMG0bWzM4OzI7MjE0OzExMTs1Nm0bWzQ4OzI7MTk2OzE4NzsxODdt4paAG1swbRtbMzg7MjsyMDM7MTQwOzkwbRtbNDg7MjsyMDY7MTk3OzIwMm3iloAbWzBtG1szODsyOzE4NjsxNTQ7MTMxbeKWgBtbMG0bWzM4OzI7MTkzOzE3NzsxNzlt4paAG1swbRtbMzg7MjsyMTk7MjExOzIxNG3iloAbWzBtICAgICAgICAgICAgCg==
EOF_LOGO
printf 'NAME="FasdeqOS"\nPRETTY_NAME="FasdeqOS"\nID=fasdeqos\nID_LIKE=arch\nVERSION_ID=0.5\nBUILD_ID=rolling\nANSI_COLOR="38;2;226;177;51"\nLOGO=fasdeqos\nHOME_URL="https://github.com/Fasdeq13"\n' >/etc/os-release
sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
for f in /usr/share/applications/lstopo.desktop /usr/share/applications/discord.desktop /etc/ostree-mkinitcpio.conf /etc/grub.d/15_ostree; do
    [ -e "$f" ] && ! "$PB" -Qo "$f" >/dev/null 2>&1 && rm -f "$f"
done
"$PB" -Sy --noconfirm
DEL=""
for p in grub grub-btrfs os-prober ostree alacritty chromium gnome-text-editor easyeffects localsend; do
    "$PB" -Qq "$p" >/dev/null 2>&1 && DEL="$DEL $p"
done
[ -n "$DEL" ] && "$PB" -Rns --noconfirm $DEL
rm -rf /boot/grub /etc/default/grub /etc/grub.d
OW='/usr/share/applications/*,/usr/share/icons/*,/etc/grub.d/*,/etc/ostree*'
WANT=$(grep -v '^#' /usr/share/fasdeqos/packages.installed | tr '\n' ' ')
for p in steam nautilus-open-any-terminal; do
    "$PB" -Si "$p" >/dev/null 2>&1 && WANT="$WANT $p"
done
"$PB" -S --needed --noconfirm --overwrite "$OW" $WANT
"$PB" -Syu --noconfirm --overwrite "$OW"
/usr/local/bin/fasd-fasdquery
systemctl daemon-reload
systemctl enable --now fasd-apps.path >/dev/null 2>&1
mkdir -p /etc/skel/.config/fish /etc/skel/.config/ghostty /etc/skel/.config/fastfetch
for d in /Users/* /home/*; do
    [ -d "$d" ] || continue
    u=$(stat -c %U "$d")
    [ "$u" = root ] && continue
    C=$d/.config
    mkdir -p "$C/niri" "$C/fish" "$C/ghostty" "$C/fastfetch" "$C/fasdeqos"
    LAYV=$(sed -n 's/^[[:space:]]*layout "\(.*\)"/\1/p' "$C/niri/config.kdl" 2>/dev/null | head -n 1)
    OPTV=$(sed -n 's/^[[:space:]]*options "\(.*\)"/\1/p' "$C/niri/config.kdl" 2>/dev/null | head -n 1)
    OUTS=$(awk '/^output "/ {p=1} p {print} /^}/ {p=0}' "$C/niri/config.kdl" 2>/dev/null)
    [ -n "$LAYV" ] || LAYV=us
    {
        cat <<'EOK'
prefer-no-csd

hotkey-overlay {
    skip-at-startup
}

EOK
        printf 'input {\n    keyboard {\n        xkb {\n            layout "%s"\n' "$LAYV"
        [ -n "$OPTV" ] && printf '            options "%s"\n' "$OPTV"
        printf '        }\n    }\n    touchpad {\n        tap\n        dwt\n        natural-scroll\n        click-method "clickfinger"\n        scroll-method "two-finger"\n    }\n}\n'
        cat <<'EOK'

layout {
    gaps 6
    center-focused-column "never"
    default-column-width { proportion 0.5; }
}

window-rule {
    geometry-corner-radius 8
    clip-to-geometry true
}

window-rule {
    match app-id="^(Throne)$"
    open-floating true
}


window-rule {
    match app-id="^steam_app_.*"
    match app-id="^gamescope"
    open-fullscreen true
}
binds {
    Mod+O { toggle-overview; }
    Mod+T { spawn "ghostty"; }
    Mod+Return { spawn "ghostty"; }
    Mod+E { spawn "nautilus"; }
    Ctrl+Alt+E { spawn "nautilus"; }
    Ctrl+Alt+T { spawn "ghostty"; }
    Mod+B { spawn "firefox"; }
    Mod+Q { close-window; }
    Alt+F4 { close-window; }
    Mod+F { maximize-column; }
    Mod+Shift+F { fullscreen-window; }
    Mod+Shift+V { toggle-window-floating; }
    Mod+W { focus-window-or-workspace-up; }
    Mod+A { focus-column-left; }
    Mod+S { focus-window-or-workspace-down; }
    Mod+D { focus-column-right; }
    Mod+Left { focus-column-left; }
    Mod+Right { focus-column-right; }
    Mod+Up { focus-window-or-workspace-up; }
    Mod+Down { focus-window-or-workspace-down; }
    Mod+Shift+Left { move-column-left; }
    Mod+Shift+Right { move-column-right; }
    Mod+Shift+Up { move-window-up-or-to-workspace-up; }
    Mod+Shift+Down { move-window-down-or-to-workspace-down; }
    Mod+Minus { set-column-width "-10%"; }
    Mod+Shift+Minus { set-window-height "-10%"; }
    Mod+Equal { set-column-width "+10%"; }
    Mod+Shift+Equal { set-window-height "+10%"; }
    Mod+1 { focus-workspace 1; }
    Mod+2 { focus-workspace 2; }
    Mod+3 { focus-workspace 3; }
    Mod+4 { focus-workspace 4; }
    Mod+5 { focus-workspace 5; }
    Mod+6 { focus-workspace 6; }
    Mod+7 { focus-workspace 7; }
    Mod+8 { focus-workspace 8; }
    Mod+9 { focus-workspace 9; }
    Mod+Ctrl+1 { move-column-to-workspace 1; }
    Mod+Ctrl+2 { move-column-to-workspace 2; }
    Mod+Ctrl+3 { move-column-to-workspace 3; }
    Mod+Ctrl+4 { move-column-to-workspace 4; }
    Mod+Ctrl+5 { move-column-to-workspace 5; }
    Mod+Ctrl+6 { move-column-to-workspace 6; }
    Mod+Ctrl+7 { move-column-to-workspace 7; }
    Mod+Ctrl+8 { move-column-to-workspace 8; }
    Mod+Ctrl+9 { move-column-to-workspace 9; }
    Mod+Shift+S { spawn "noctalia" "msg" "screenshot-region"; }
    Print { screenshot; }
    Mod+V { spawn "noctalia" "msg" "panel-toggle" "clipboard"; }
    Alt+Space { spawn "noctalia" "msg" "panel-toggle" "launcher"; }
    Mod+Shift+A { spawn "noctalia" "msg" "panel-toggle" "control-center"; }
    XF86AudioRaiseVolume allow-when-locked=true { spawn "noctalia" "msg" "volume-up"; }
    XF86AudioLowerVolume allow-when-locked=true { spawn "noctalia" "msg" "volume-down"; }
    XF86AudioMute allow-when-locked=true { spawn "noctalia" "msg" "volume-mute"; }
    XF86AudioPlay allow-when-locked=true { spawn "noctalia" "msg" "media" "play-pause"; }
    XF86AudioNext allow-when-locked=true { spawn "noctalia" "msg" "media" "next"; }
    XF86AudioPrev allow-when-locked=true { spawn "noctalia" "msg" "media" "previous"; }
    XF86MonBrightnessUp allow-when-locked=true { spawn "brightnessctl" "set" "5%+"; }
    XF86MonBrightnessDown allow-when-locked=true { spawn "brightnessctl" "set" "5%-"; }
    Mod+Shift+Slash { show-hotkey-overlay; }
    Mod+K { show-hotkey-overlay; }
    Mod+Shift+E { quit; }
    Mod+TouchpadScrollDown cooldown-ms=200 { focus-workspace-down; }
    Mod+TouchpadScrollUp cooldown-ms=200 { focus-workspace-up; }
    Mod+TouchpadScrollRight { focus-column-right; }
    Mod+TouchpadScrollLeft { focus-column-left; }
    Mod+Shift+TouchpadScrollDown cooldown-ms=200 { move-column-to-workspace-down; }
    Mod+Shift+TouchpadScrollUp cooldown-ms=200 { move-column-to-workspace-up; }
    Mod+Shift+TouchpadScrollRight { move-column-right; }
    Mod+Shift+TouchpadScrollLeft { move-column-left; }
    Mod+Ctrl+TouchpadScrollUp { set-window-height "+5%"; }
    Mod+Ctrl+TouchpadScrollDown { set-window-height "-5%"; }
    Mod+Ctrl+TouchpadScrollRight { set-column-width "+5%"; }
    Mod+Ctrl+TouchpadScrollLeft { set-column-width "-5%"; }
    Mod+WheelScrollDown cooldown-ms=150 { focus-workspace-down; }
    Mod+WheelScrollUp cooldown-ms=150 { focus-workspace-up; }
    Mod+WheelScrollRight { focus-column-right; }
    Mod+WheelScrollLeft { focus-column-left; }
    Mod+Shift+WheelScrollDown cooldown-ms=150 { move-column-to-workspace-down; }
    Mod+Shift+WheelScrollUp cooldown-ms=150 { move-column-to-workspace-up; }
}


gestures {
    hot-corners {
        off
    }
}
EOK
        printf '\nspawn-at-startup "/usr/local/bin/fasd-first"\nspawn-at-startup "noctalia"\nspawn-at-startup "/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1"\nspawn-at-startup "xdg-user-dirs-update"\nspawn-at-startup "gnome-keyring-daemon" "--start" "--components=secrets"\n'
        cat <<'EOK'

window-rule {
    match app-id=r#"^steam$"# title=r#"^notificationtoasts_\d+_desktop$"#
    default-floating-position x=10 y=10 relative-to="bottom-right"
    open-focused false
}

window-rule {
    match app-id=r#"^steam$"#
    exclude title=r#"^Steam$"#
    open-floating true
}
EOK
    } >"$C/niri/config.kdl"
    [ -n "$OUTS" ] && printf '\n%s\n' "$OUTS" >>"$C/niri/config.kdl"
    printf 'set -g fish_greeting\nif status is-interactive\n    starship init fish | source\nend\n' >"$C/fish/config.fish"
    cat >"$C/ghostty/config" <<'EOP'
window-decoration = none
background-opacity = 0.95
font-family = JetBrainsMono Nerd Font
font-size = 11
window-padding-x = 8
window-padding-y = 8
theme = Catppuccin Mocha
confirm-close-surface = false
EOP
    cat >"$C/fastfetch/config.jsonc" <<'EOP'
{
  "logo": { "type": "file-raw", "source": "/usr/share/fasdeqos/logo.ansi", "padding": { "top": 1, "right": 3 } },
  "display": { "separator": "  ", "color": { "keys": "yellow", "title": "yellow" } },
  "modules": [
    "title",
    "separator",
    { "type": "os", "key": " OS", "format": "{name}" },
    { "type": "kernel", "key": " Kernel" },
    { "type": "uptime", "key": " Uptime" },
    { "type": "packages", "key": " Packages", "format": "{all}" },
    { "type": "shell", "key": " Shell" },
    { "type": "wm", "key": " WM" },
    { "type": "terminal", "key": " Terminal" },
    { "type": "cpu", "key": " CPU" },
    { "type": "gpu", "key": " GPU" },
    { "type": "memory", "key": " Memory" },
    { "type": "disk", "key": " Disk", "folders": "/" },
    "break",
    "colors"
  ]
}
EOP
    rm -f "$C/fasdeqos/first-done" "$C/starship.toml"
    chown -R "$u:$(id -gn "$u")" "$C"
done
/usr/local/bin/fasd-layout
/usr/local/bin/fasd-pkgbackend
echo "FasdeqOS updated. Log out and back in to apply the new configuration."
