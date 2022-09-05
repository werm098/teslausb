#!/bin/bash -eux
#
# Pre-install script to make things look sufficiently like what
# the main Raspberry Pi centric install scripts expect.
#

rootpart=$(findmnt -n -o SOURCE /)
rootname=$(lsblk -no pkname "${rootpart}")
rootdev="/dev/${rootname}"

# Check that the root partition is the last one.
lastpart=$(sfdisk -l "$rootdev" | tail -1 | awk '{print $1}')

if [ "$rootpart" != "$lastpart" ]
then
  echo "STOP: root partition is not the last partition."
  exit 1
fi

# Check if there is sufficient unpartitioned space after the root
# partition to create the backingfiles and mutable partitions
unpart=$(sfdisk -F "$rootdev" | grep -o '[0-9]* bytes' | head -1 | awk '{print $1}')
if [ "$unpart" -lt  $(( (1<<30) * 40)) ]
then
  # There is insufficient unpartitioned space.
  # Check if we've already shrunk the root filesystem, and shrink the root
  # partition to match if it hasn't been already

  devsectorsize=$(cat "/sys/block/${rootname}/queue/hw_sector_size")
  read -r fsblockcount fsblocksize < <(tune2fs -l "${rootpart}" | grep "Block count:\|Block size:" | awk ' {print $2}' FS=: | tr -d ' ' | tr '\n' ' ' | (cat; echo))
  fsnumsectors=$((fsblockcount * fsblocksize / devsectorsize + 1))

  partnumsectors=$(sfdisk -l -o Sectors "${rootdev}" | tail -1)
  if [ "$partnumsectors" -le "$fsnumsectors" ]
  then
    echo "insufficient unpartitioned space, attempting to shrink root file system"

    cat <<- EOF > /etc/rc.local
		#!/bin/bash
		{
		  while ! curl -s https://raw.githubusercontent.com/marcone/teslausb/main-dev/setup/rock/install.sh
		  do
		    sleep 1
		  done
		} | bash
		EOF
    chmod a+x /etc/rc.local

    {
      while ! curl -s https://raw.githubusercontent.com/marcone/teslausb/main-dev/tools/debian-resizefs.sh
      do
        sleep 1
      done
    } | bash -s 3G
    exit 0
  fi
  # shrink root partition to match root file system size
  echo "shrinking root partition to match root fs, $fsnumsectors sectors"
  sleep 3
  rootpartstartsector=$(sfdisk -l -o Start "${rootdev}" | tail -1)
  partnum=${rootpart:0-1}

  echo "${rootpartstartsector},${fsnumsectors}" | sfdisk --force "${rootdev}" -N "${partnum}"
  reboot
  exit 0
fi

# Copy the sample config file from github
if [ ! -e /boot/teslausb_setup_variables.conf ] && [ ! -e /root/teslausb_setup_variables.conf ]
then
  curl -o /boot/teslausb_setup_variables.conf https://raw.githubusercontent.com/marcone/teslausb/main-dev/pi-gen-sources/00-teslausb-tweaks/files/teslausb_setup_variables.conf.sample
fi

# and the wifi config template
if [ ! -e /boot/wpa_supplicant.conf.sample ]
then
  curl -o /boot/wpa_supplicant.conf.sample https://raw.githubusercontent.com/marcone/teslausb/main-dev/pi-gen-sources/00-teslausb-tweaks/files/wpa_supplicant.conf.sample
fi

# Copy our rc.local from github, which will allow setup to
# continue using the regular "one step setup" process used
# for setting up a Raspberry Pi with the prebuilt image
rm -f /etc/rc.local
curl -o /etc/rc.local https://raw.githubusercontent.com/marcone/teslausb/main-dev/pi-gen-sources/00-teslausb-tweaks/files/rc.local
chmod a+x /etc/rc.local

if [ ! -x "$(command -v dos2unix)" ]
then
  apt install dos2unix
fi

if [ ! -x "$(command -v sntp)" ]
then
  apt install sntp
fi

# indicate we're waiting for the user to log in and finish setup
led=/sys/class/leds/user-led2
if [ -e "$led" ]
then
  echo timer > ${led}/trigger
  echo 150 > ${led}/delay_off
  echo 50 > ${led}/delay_on
fi

# If there is a user with id 1000, assume it is the default user
# the user will be logging in as.
DEFUSER=$(grep ":1000:1000:" /etc/passwd | awk -F : '{print $1}')
if [ -n "$DEFUSER" ]
then
  if [ ! -e "/home/$DEFUSER/.bash_profile" ] || ! grep "SETUP_FINISHED" "/home/$DEFUSER/.bash_profile"
  then
    cat <<- EOF >> "/home/$DEFUSER/.bash_profile"
		if [ ! -e /boot/TESLAUSB_SETUP_FINISHED ]
		then
		  echo "+-------------------------------------------+"
		  echo "| To continue teslausb setup, run 'sudo -i' |"
		  echo "+-------------------------------------------+"
		fi
	EOF
    chown "$DEFUSER.$DEFUSER" "/home/$DEFUSER/.bash_profile"
  fi
fi

if [ ! -e /root/.bash_profile ] || ! grep "SETUP_FINISHED" /root/.bash_profile
then
  cat <<- EOF >> /root/.bash_profile
	if [ ! -e /boot/TESLAUSB_SETUP_FINISHED ]
	then
	  echo "+------------------------------------------------------------------------+"
	  echo "| To continue teslausb setup, edit the file                              |"
	  echo "| /boot/teslausb_setup_variables.conf with your favorite                 |"
	  echo "| editor, e.g. 'nano /boot/teslausb_setup_variables.conf' and fill in    |"
	  echo "| the required variables. Instructions are in the file, and at           |"
	  echo "| https://github.com/marcone/teslausb/blob/main-dev/doc/OneStepSetup.md  |"
	  echo "| (though ignore the Raspberry Pi specific bits about flashing and       |"
	  echo "| mounting the sd card on a PC)                                          |"
	  echo "|                                                                        |"
	  echo "| When done, save changes and run /etc/rc.local                          |"
	  echo "+------------------------------------------------------------------------+"
	fi
	EOF
fi
