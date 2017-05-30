#!/bin/bash

if [[ $# -eq 0 ]] ; then
    echo "Please pass version number, e.g. $0 2.0"
    exit 0
fi

basedir=`pwd`/orangepiplus2-$1

# Make sure that the cross compiler can be found in the path before we do
# anything else, that way the builds don't fail half way through.
export CROSS_COMPILE=arm-linux-gnueabi-
if [ $(compgen -c $CROSS_COMPILE | wc -l) -eq 0 ] ; then
    echo "Missing cross compiler. Set up PATH according to the README"
    exit 1
fi
# Unset CROSS_COMPILE so that if there is any native compiling needed it doesn't
# get cross compiled.
unset CROSS_COMPILE

# Package installations for various sections.
# This will build a minimal XFCE Kali system with the top 10 tools.
# This is the section to edit if you would like to add more packages.
# See http://www.kali.org/new/kali-linux-metapackages/ for meta packages you can
# use. You can also install packages, using just the package name, but keep in
# mind that not all packages work on ARM! If you specify one of those, the
# script will throw an error, but will still continue on, and create an unusable
# image, keep that in mind.

arm="abootimg cgpt fake-hwclock ntpdate u-boot-tools vboot-utils vboot-kernel-utils"
base="e2fsprogs initramfs-tools kali-defaults kali-menu parted sudo usbutils"
desktop="fonts-croscore fonts-crosextra-caladea fonts-crosextra-carlito gnome-theme-kali gtk3-engines-xfce kali-desktop-xfce kali-root-login lightdm network-manager network-manager-gnome xfce4 xserver-xorg-video-fbdev"
tools="aircrack-ng ethtool nmap usbutils"
services="openssh-server"
extras="xfce4-terminal"

packages="${arm} ${base} ${desktop} ${tools} ${services} ${extras}"
architecture="armhf"
# If you have your own preferred mirrors, set them here.
# You may want to leave security.kali.org alone, but if you trust your local
# mirror, feel free to change this as well.
# After generating the rootfs, we set the sources.list to the default settings.
mirror=http.kali.org

# Set this to use an http proxy, like apt-cacher-ng, and uncomment further down
# to unset it.
#export http_proxy="http://localhost:3142/"

mkdir -p ${basedir}
cd ${basedir}

# create the rootfs - not much to modify here, except maybe the hostname.
debootstrap --foreign --arch $architecture kali-rolling kali-$architecture http://192.168.8.167:32769/$mirror/kali

cp /usr/bin/qemu-arm-static kali-$architecture/usr/bin/

LANG=C chroot kali-$architecture /debootstrap/debootstrap --second-stage
cat << EOF > kali-$architecture/etc/apt/sources.list
deb http://192.168.8.167:32769/$mirror/kali kali-rolling main contrib non-free
EOF

echo "orangepi" > kali-$architecture/etc/hostname

cat << EOF > kali-$architecture/etc/hosts
127.0.0.1       orangepi    localhost
::1             localhost ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff00::0         ip6-mcastprefix
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

cat << EOF > kali-$architecture/etc/network/interfaces
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

cat << EOF > kali-$architecture/etc/resolv.conf
nameserver 192.168.8.1
EOF

export MALLOC_CHECK_=0 # workaround for LP: #520465
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

mount -t proc proc kali-$architecture/proc
mount -o bind /dev/ kali-$architecture/dev/
mount -o bind /dev/pts kali-$architecture/dev/pts

cat << EOF > kali-$architecture/debconf.set
console-common console-data/keymap/policy select Select keymap from full list
console-common console-data/keymap/full select en-latin1-nodeadkeys
EOF

cat << EOF > kali-$architecture/third-stage
#!/bin/bash
dpkg-divert --add --local --divert /usr/sbin/invoke-rc.d.chroot --rename /usr/sbin/invoke-rc.d
cp /bin/true /usr/sbin/invoke-rc.d
echo -e "#!/bin/sh\nexit 101" > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

apt-get update
apt-get --yes --force-yes install locales-all

debconf-set-selections /debconf.set
rm -f /debconf.set
apt-get update
apt-get -y install git-core binutils ca-certificates initramfs-tools u-boot-tools
apt-get -y install locales console-common less nano git
echo "root:toor" | chpasswd
sed -i -e 's/KERNEL\!=\"eth\*|/KERNEL\!=\"/' /lib/udev/rules.d/75-persistent-net-generator.rules
rm -f /etc/udev/rules.d/70-persistent-net.rules
export DEBIAN_FRONTEND=noninteractive
apt-get --yes --force-yes install $packages
apt-get --yes --force-yes dist-upgrade
apt-get --yes --force-yes autoremove

sed -i -e 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
update-rc.d ssh enable

rm -f /usr/sbin/policy-rc.d
rm -f /usr/sbin/invoke-rc.d
dpkg-divert --remove --rename /usr/sbin/invoke-rc.d
rm -f /third-stage
EOF

chmod +x kali-$architecture/third-stage
LANG=C chroot kali-$architecture /third-stage
cat << EOF > kali-$architecture/cleanup
#!/bin/bash
rm -rf /root/.bash_history
apt-get update
apt-get clean
rm -f /0
rm -f /hs_err*
rm -f cleanup
rm -f /usr/bin/qemu*
EOF

chmod +x kali-$architecture/cleanup
LANG=C chroot kali-$architecture /cleanup
umount kali-$architecture/proc/sys/fs/binfmt_misc
umount kali-$architecture/dev/pts
umount kali-$architecture/dev/
umount kali-$architecture/proc
# Create the disk and partition it
dd if=/dev/zero of=${basedir}/kali-$1-orangepiplus2.img bs=1M count=7000
parted kali-$1-orangepiplus2.img --script -- mklabel msdos
parted kali-$1-orangepiplus2.img --script -- mkpart primary fat32 2048s 264191s
parted kali-$1-orangepiplus2.img --script -- mkpart primary ext4 264192s 100%
# Set the partition variables
loopdevice=`losetup -f --show ${basedir}/kali-$1-orangepiplus2.img`
device=`kpartx -va $loopdevice| sed -E 's/.*(loop[0-9])p.*/\1/g' | head -1`
sleep 5
device="/dev/mapper/${device}"
bootp=${device}p1
rootp=${device}p2
# Create file systems
mkfs.vfat $bootp
mkfs.ext4 $rootp
# Create the dirs for the partitions and mount them
mkdir -p ${basedir}/bootp ${basedir}/rootp
mount $bootp ${basedir}/bootp
mount $rootp ${basedir}/rootp
echo "Rsyncing rootfs to image file"
rsync -HPavz -q ${basedir}/kali-$architecture/ ${basedir}/rootp/
# Enable the serial console
echo "T1:12345:respawn:/sbin/agetty -L ttyS0 115200 vt100" >> ${basedir}/rootp/etc/inittab
# Load the ethernet module since it doesn't load automatically at boot.

cat > ${basedir}/rootp/etc/modules << _EOF_
# /etc/modules: kernel modules to load at boot time.
#
# This file contains the names of kernel modules that should be loaded
# at boot time, one per line. Lines beginning with "#" are ignored.
## Display and GPU
#ump
#mali
##mali_drm
## WiFi
#8192cu
#8188eu
8189es
## GPIO
#gpio-sunxi
_EOF_



cat << EOF > ${basedir}/rootp/etc/apt/sources.list
deb http://192.168.8.167:32769/http.kali.org/kali kali-rolling main non-free contrib
deb-src http://192.168.8.167:32769/http.kali.org/kali kali-rolling main non-free contrib
EOF

# Uncomment this if you use apt-cacher-ng otherwise git clones will fail.
#unset http_proxy

# Kernel section.  If you want to us ea custom kernel, or configuration, replace
# them in this section.
# Get, compile and install kernel
git clone /media/dsm/www/gitweb/OrangePiH3/uboot
git clone /media/dsm/www/gitweb/OrangePiH3/toolchain
git clone /media/dsm/www/gitweb/OrangePiH3/kernel
git clone /media/dsm/www/gitweb/OrangePiH3/scripts
git clone /media/dsm/www/gitweb/OrangePiH3/external

cross_comp="${basedir}/toolchain/bin/arm-linux-gnueabi"
cd ${basedir}/uboot
cd ${basedir}/uboot/configs
CONFIG="orangepi_plus2e_defconfig"
dts="sun8i-h3-orangepi-plus2e.dtb"
echo " Enter u-boot source director..."
cd ..
make -j $(grep -c processor /proc/cpuinfo) $CONFIG > /dev/null 2>&1
echo " Build u-boot..."
echo -e "\e[1;31m Build U-boot \e[0m"
make -j $(grep -c processor /proc/cpuinfo) ARCH=arm CROSS_COMPILE=${cross_comp}-
cp ${basedir}/uboot/u-boot-sunxi-with-spl.bin ${basedir}/bootp -rf
echo "*****compile uboot ok*****"
cp ${basedir}/external/Legacy_patch/uboot/orangepi.cmd ${basedir}/bootp/ -rf
cd ${basedir}/bootp/
sed -i '/sun8i-h3/d' orangepi.cmd
linenum=`grep -n "uImage" orangepi.cmd | awk '{print $1}' | awk -F: '{print $1}'`
sed -i "${linenum}i fatload mmc 0 0x46000000 ${dts}" orangepi.cmd
chmod +x orangepi.cmd u-boot-sunxi-with-spl.bin
mkimage -C none -A arm -T script -d ${basedir}/bootp/orangepi.cmd ${basedir}/bootp/boot.scr

#dd if=u-boot-sunxi-with-spl.bin of=$loopdevice bs=1024 seek=8
##############
#${basedir}/
cd ${basedir}/external/Legacy_patch/rootfs-test1
mkdir run
mkdir -p conf/conf.d
find . | cpio --quiet -o -H newc > ../rootfs-lobo.img
cd ..
gzip rootfs-lobo.img
cd ${basedir}/kernel
LINKERNEL_DIR=`pwd`
mkdir -p ${basedir}/rootp/lib/
mkdir -p ${basedir}/kernel/output/
cp ${basedir}/external/Legacy_patch/rootfs-lobo.img.gz ${basedir}/kernel/output/rootfs.cpio.gz
chmod +x ${basedir}/kernel/output/*
cp ${basedir}/kernel/output/rootfs.cpio.gz ${basedir}/kernel/output/
cp ${basedir}/external/Legacy_patch/Kconfig.piplus drivers/net/ethernet/sunxi/eth/Kconfig
cp ${basedir}/external/Legacy_patch/sunxi_geth.c.piplus drivers/net/ethernet/sunxi/eth/sunxi_geth.c
cp ${basedir}/external/Legacy_patch/sun8iw7p1smp_linux_defconfig arch/arm/configs/sun8iw7p1smp_linux_defconfig
sleep 1
echo -e "\e[1;31m Building kernel for OrangePi-plus2e ...\e[0m"
if [ ! -f ${basedir}/kernel/.config ]; then
echo -e "\e[1;31m Configuring ... \e[0m"
make -j $(grep -c processor /proc/cpuinfo) ARCH=arm CROSS_COMPILE=${cross_comp}- mrproper > /dev/null 2>&1
make -j $(grep -c processor /proc/cpuinfo) ARCH=arm CROSS_COMPILE=${cross_comp}- sun8iw7p1smp_linux_defconfig 
fi
sleep 1
# build kernel (use -jN, where N is number of cores you can spare for building)
echo -e "\e[1;31m Building Kernel and Modules \e[0m"
make -j $(grep -c processor /proc/cpuinfo) ARCH=arm CROSS_COMPILE=${cross_comp}- uImage
#==================================================
# copy uImage to output
cp arch/arm/boot/uImage ${basedir}/bootp/uImage_plus2e
make -j $(grep -c processor /proc/cpuinfo) ARCH=arm CROSS_COMPILE=${cross_comp}- modules
sleep 1
echo -e "\e[1;31m Exporting Modules \e[0m"
make -j $(grep -c processor /proc/cpuinfo) ARCH=arm CROSS_COMPILE=${cross_comp}- INSTALL_MOD_PATH=${basedir}/rootp modules_install
echo -e "\e[1;31m Exporting Firmware ... \e[0m"
make -j $(grep -c processor /proc/cpuinfo) ARCH=arm CROSS_COMPILE=${cross_comp}- INSTALL_MOD_PATH=${basedir}/rootp firmware_install
sleep 1
# build mali driver
##########################
SCRIPT_DIR=`pwd`
cd ${basedir}/kernel
# ####################################
# Copy config file to config directory
make -j $(grep -c processor /proc/cpuinfo) ARCH=arm CROSS_COMPILE=${cross_comp}- sun8iw7p1smp_linux_defconfig 
if [ $? -ne 0 ]; then
    echo "  Error: defconfig."
    exit 1
fi
export LICHEE_PLATFORM=linux
export KERNEL_VERSION=`make ARCH=arm CROSS_COMPILE=${cross_comp}- -s kernelversion -C ./`
LICHEE_KDIR=`pwd`
KDIR=`pwd`
export LICHEE_MOD_DIR=${LICHEE_KDIR}/rootp/lib/modules/${KERNEL_VERSION}
mkdir -p $LICHEE_MOD_DIR/kernel/drivers/gpu/mali
mkdir -p $LICHEE_MOD_DIR/kernel/drivers/gpu/ump
export LICHEE_KDIR
export MOD_DIR=${LICHEE_KDIR}/rootp/lib/modules/${KERNEL_VERSION}
export KDIR
cd modules/mali
make ARCH=arm CROSS_COMPILE=${cross_comp}- clean
if [ $? -ne 0 ]; then
    echo "  Error: clean."
    exit 1
fi
make ARCH=arm CROSS_COMPILE=${cross_comp}- build
if [ $? -ne 0 ]; then
    echo "  Error: build."
    exit 1
fi
make ARCH=arm CROSS_COMPILE=${cross_comp}- install
if [ $? -ne 0 ]; then
    echo "  Error: install."
    exit 1
fi
cp -rf $MOD_DIR/kernel/drivers/gpu/* ${basedir}/rootp/lib/modules/3.4.112/kernel/drivers/gpu/
cd ${basedir}
cd ..
echo "  mali build OK."
cp ${basedir}/../misc/zram ${basedir}/rootp/etc/init.d/zram
chmod +x ${basedir}/rootp/etc/init.d/zram
# Unmount partitions
umount $bootp
umount $rootp
kpartx -dv $loopdevice
# Clean up all the temporary build stuff and remove the directories.
# Comment this out to keep things around if you want to see what may have gone
# wrong.
echo "Cleaning up the temporary build files..."
rm -rf ${basedir}/uboot ${basedir}/kernel ${basedir}/bootp ${basedir}/rootp ${basedir}/kali-$architecture ${basedir}/boot ${basedir}/external ${basedir}/toolchain
# If you're building an image for yourself, comment all of this out, as you
# don't need the sha1sum or to compress the image, since you will be testing it
# soon.
echo "Generating sha1sum of kali-$1-orangepiplus2.img"
sha1sum kali-$1-orangepiplus2.img > ${basedir}/kali-$1-orangepiplus2.img.sha1sum
## Don't pixz on 32bit, there isn't enough memory to compress the images.
#MACHINE_TYPE=`uname -m`
#if [ ${MACHINE_TYPE} == 'x86_64' ]; then
#echo "Compressing kali-$1-orangepiplus2.img"
#pixz ${basedir}/kali-$1-orangepiplus2.img ${basedir}/kali-$1-orangepiplus2.img.xz
#rm ${basedir}/kali-$1-orangepiplus2.img
#echo "Generating sha1sum of kali-$1-orangepiplus2.img.xz"
#sha1sum kali-$1-orangepiplus2.img.xz > ${basedir}/kali-$1-orangepiplus2.img.xz.sha1sum
#fi
