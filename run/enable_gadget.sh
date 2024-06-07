#!/bin/bash -eu

source /root/bin/envsetup.sh

if ! configfs_root=$(findmnt -o TARGET -n configfs)
then
  echo "error: configfs not found"
  exit 1
fi
readonly gadget_root="$configfs_root/usb_gadget/teslausb"

# USB supports many languages. 0x409 is US English
readonly lang=0x409

# configuration name can be anything, the convention
# appears to be to use "c"
readonly cfg=c

if [ -d "$gadget_root" ]
then
  echo "already prepared"
  exit 0
fi

modprobe libcomposite

mkdir -p "$gadget_root/configs/$cfg.1"

# common setup
echo 0x1d6b > "$gadget_root/idVendor"  # Linux Foundation
echo 0x0104 > "$gadget_root/idProduct" # Composite Gadget
echo 0x0100 > "$gadget_root/bcdDevice" # v1.0.0
echo 0x0200 > "$gadget_root/bcdUSB"    # USB 2.0
mkdir -p "$gadget_root/strings/$lang"
mkdir -p "$gadget_root/configs/$cfg.1/strings/$lang"
echo "TeslaUSB-$(grep Serial /proc/cpuinfo | awk '{print $3}')" > "$gadget_root/strings/$lang/serialnumber"
echo TeslaUSB > "$gadget_root/strings/$lang/manufacturer"
echo "TeslaUSB Composite Gadget" > "$gadget_root/strings/$lang/product"
echo "TeslaUSB Config" > "$gadget_root/configs/$cfg.1/strings/$lang/configuration"

# A bare Raspberry Pi 4 or 5 can peak at at over 1 A during boot, but idles around 500 mA.
# A Raspberry Pi Zero 2 W can peak at over 300 mA during boot, but idles around 100 mA.
# A Raspberry Pi Zero W can peak up to 220 mA during boot, but idles around 80 mA.
if isPi5
then
  echo 600 > "$gadget_root/configs/$cfg.1/MaxPower"
elif isPi4
then
  echo 500 > "$gadget_root/configs/$cfg.1/MaxPower"
elif isPi2
then
  echo 200 > "$gadget_root/configs/$cfg.1/MaxPower"
else
  echo 100 > "$gadget_root/configs/$cfg.1/MaxPower"
fi

# mass storage setup
mkdir -p "$gadget_root/functions/mass_storage.0"

echo "/backingfiles/cam_disk.bin" > "$gadget_root/functions/mass_storage.0/lun.0/file"
echo "TeslaUSB CAM $(du -h /backingfiles/cam_disk.bin | awk '{print $1}')" > "$gadget_root/functions/mass_storage.0/lun.0/inquiry_string"

lun="lun.1"

# one lun is created by default, so we only need to create the 2nd one
if [ -e "/backingfiles/music_disk.bin" ]
then
  mkdir -p "$gadget_root/functions/mass_storage.0/${lun}"
  echo "/backingfiles/music_disk.bin" > "$gadget_root/functions/mass_storage.0/${lun}/file"
  echo "TeslaUSB MUSIC $(du -h /backingfiles/music_disk.bin | awk '{print $1}')" > "$gadget_root/functions/mass_storage.0/${lun}/inquiry_string"
  lun="lun.2"
fi

# one lun is created by default, so we only need to create the 3nd one
if [ -e "/backingfiles/lightshow_disk.bin" ]
then
  mkdir -p "$gadget_root/functions/mass_storage.0/${lun}"
  echo "/backingfiles/lightshow_disk.bin" > "$gadget_root/functions/mass_storage.0/${lun}/file"
  echo "TeslaUSB LIGHTSHOW $(du -h /backingfiles/lightshow_disk.bin | awk '{print $1}')" > "$gadget_root/functions/mass_storage.0/${lun}/inquiry_string"
  if [[ $lun == "lun.1" ]]
  then
    lun="lun.2"
  elif [[ $lun == "lun.2" ]]
  then
    lun="lun.3"
  fi
fi

# boombox drive is either lun 1,2 or 3, depending on whether music drive or lightbox is used
if [ -e "/backingfiles/boombox_disk.bin" ]
then
  mkdir -p "$gadget_root/functions/mass_storage.0/${lun}"
  echo "/backingfiles/boombox_disk.bin" > "$gadget_root/functions/mass_storage.0/${lun}/file"
  echo "TeslaUSB BOOMBOX $(du -h /backingfiles/boombox_disk.bin | awk '{print $1}')" > "$gadget_root/functions/mass_storage.0/${lun}/inquiry_string"
fi

ln -sf "$gadget_root/functions/mass_storage.0" "$gadget_root/configs/$cfg.1"

# activate
find /sys/class/udc -type l -printf '%P\n' | head -1 > "$gadget_root/UDC"
