#!/bin/bash
#
# Bootstrap installs Windows ISO to a Linode from a temporary block storage volume.
# by Kit Knox - Akamai Technologies
#
# - Downloads ISO directly from Microsoft
# - Overlays VirtIO Drivers into ISO
# - Deploys ISO as Bootable USB on recovery partition on main raw disk
# - Deploys autounattend.xml to fully automate installation of Windows and enabling of Remote Desktop
#
#<UDF name="TOKEN" Label="Linode API Token" />
#<UDF name="WINDOWS_PASSWORD" Label="Administrator Password for Windows" example="Password" />
#<UDF name="INSTALL_WINDOWS_VERSION" Label="Windows Version" oneOf="w11,2k22" default="2k22"/>
#<UDF name="AUTOLOGIN" Label="Auto Login to Windows" oneOf="true,false" default="true"/>
#<UDF name="W11_ISO_URL" Label="Windows 11 ISO URL (Not Required For Windows Server) - Get Fresh URL From https://www.microsoft.com/en-us/software-download/windows11 or a direct link to your own (e.g. MicroWin) ISO, or UPLOAD to scp it to the Linode during stage 3" default="NOURL"/>
#<UDF name="W11_IMAGE_INDEX" Label="Windows 11 install image index (auto = only image, or the 'Windows 11 Pro' edition)" default="auto"/>

# Replaced with values from StackScript UDF
#TOKEN=
#WINDOWS_PASSWORD=
#INSTALL_WINDOWS_VERSION=
#AUTOLOGIN=
#W11_ISO_URL=
#W11_IMAGE_INDEX=
VIRTIO_ISO_URL='https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso'
W2K22_ISO_URL='https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US'

# STAGE changes dynamically as install progresses
STAGE=1
# Persist UDF variables for future stages after reboot
if [ $STAGE == 1 ]; then
  sed -i "s/^#TOKEN=/TOKEN=$TOKEN/" /root/StackScript
  sed -i "s/^#WINDOWS_PASSWORD=/WINDOWS_PASSWORD=\"$(echo $WINDOWS_PASSWORD | sed -e 's/\\/\\\\/g; s/\//\\\//g; s/&/\\\&/g')\"/" /root/StackScript
  sed -i "s/^#INSTALL_WINDOWS_VERSION=/INSTALL_WINDOWS_VERSION=$INSTALL_WINDOWS_VERSION/" /root/StackScript
  sed -i "s/^#AUTOLOGIN=/AUTOLOGIN=$AUTOLOGIN/" /root/StackScript
  sed -i "s/^#W11_ISO_URL=/W11_ISO_URL=\"$(echo $W11_ISO_URL | sed -e 's/\\/\\\\/g; s/\//\\\//g; s/&/\\\&/g')\"/" /root/StackScript
  sed -i "s/^#W11_IMAGE_INDEX=/W11_IMAGE_INDEX=${W11_IMAGE_INDEX:-auto}/" /root/StackScript
fi

stage1() {
  echo "Stage 1 started"
  export LINODE_ID=`dmidecode -t1 | grep Serial | awk '{print $3}'`
  ROOT_UUID=`lsblk -o UUID,MOUNTPOINT -P |  grep 'MOUNTPOINT="/"' | sed 's/[0-9]*$//' | awk '{print $1}' | sed 's/UUID="//' | sed 's/"//'`
  if ! [ $LINODE_ID -gt 0 ]; then
    echo "Invalid LinodeID"
    exit
  fi
  if ! [ -f "/usr/bin/jq" ]; then
    echo "jq package missing"
    export DEBIAN_FRONTEND=noninteractive
    apt update
    apt install -yq jq wimtools genisoimage libwin-hivex-perl
  fi
  if ! [ -e "/dev/disk/by-id/scsi-0Linode_Volume_temp-$LINODE_ID" ]; then
    echo "LinodeID: $LINODE_ID - Creating Block Storage Volume"
    VOLUME_ID=$(curl -sH "Content-Type: application/json" \
      -H "Authorization: Bearer $TOKEN" \
      -X POST -d "{
        \"label\": \"temp-$LINODE_ID\",
        \"size\": 30,
        \"linode_id\": $LINODE_ID
      }" \
      https://api.linode.com/v4/volumes | jq -r '.id')
    echo "Created Block Storage Volume ID: $VOLUME_ID"
  else
    echo "Block storage volume device already exists, querying for Volume ID"
    VOLUME_ID=$(curl -sH "Authorization: Bearer $TOKEN" \
      -H "X-Filter: {\"label\": \"temp-$LINODE_ID\"}" \
      https://api.linode.com/v4/volumes | jq -r '.data[0].id')
    echo "Found existing Block Storage Volume ID: $VOLUME_ID"
  fi
  while ! [ -e "/dev/disk/by-id/scsi-0Linode_Volume_temp-$LINODE_ID" ]
  do
    echo "Waiting for block storage volume."
    sleep 5
  done
  echo "Found block storage volume for Linode ID: $LINODE_ID"
  if ! lsblk -f "/dev/disk/by-id/scsi-0Linode_Volume_temp-$LINODE_ID" | grep ext4 > /dev/null; then
    echo "No filesystem found, creating."
    mkfs.ext4 -U $ROOT_UUID "/dev/disk/by-id/scsi-0Linode_Volume_temp-$LINODE_ID"
  fi
  mkdir "/mnt/temp-$LINODE_ID"
  mount  "/dev/disk/by-id/scsi-0Linode_Volume_temp-$LINODE_ID" /mnt/temp-$LINODE_ID
  echo "Block Storage Volume ID: $VOLUME_ID"

  BLOCK_CONFIG_ID=`curl -sH "Authorization: Bearer $TOKEN" \
      https://api.linode.com/v4/linode/instances/$LINODE_ID/configs | jq '.data[] | select (.label == "BLOCK") | .id'`
  NEW_CONFIG=`curl -sH "Authorization: Bearer $TOKEN" \
    https://api.linode.com/v4/linode/instances/$LINODE_ID/configs | jq ".data[] | select (.label|test(\"My (Ubuntu|Debian).*\"))" | jq '.kernel = "linode/grub2"' | jq ' .devices.sda.disk_id = null | .devices.sda.disk_id = null | .devices.sdc.disk_id = null | .devices.sdd = null | .devices.sdb = null | .root_device = "/dev/sda"' | jq " .devices.sda.volume_id = $VOLUME_ID" | jq " .devices.sdc = null" | grep -v "\"id\":" | jq '.label = "BLOCK"' | grep -v "\"created\":" | grep -v "\"updated\":"`

  echo "## New Config"
  echo "$NEW_CONFIG" | jq

  if ! [ $BLOCK_CONFIG_ID -gt 0 ]; then
    echo "BLOCK config doesn't exist, creating."
    curl -sH "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" \
        -X POST -d "$NEW_CONFIG"\
        https://api.linode.com/v4/linode/instances/$LINODE_ID/configs | jq
  else
    echo "BLOCK config exists, updating."
    curl -sH "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" \
        -X PUT -d "$NEW_CONFIG"\
        https://api.linode.com/v4/linode/instances/$LINODE_ID/configs/$BLOCK_CONFIG_ID | jq
  fi

  BLOCK_CONFIG_ID=`curl -sH "Authorization: Bearer $TOKEN" \
      https://api.linode.com/v4/linode/instances/$LINODE_ID/configs | jq '.data[] | select (.label == "BLOCK") | .id'`
  echo "BLOCK ConfigID: $BLOCK_CONFIG_ID"

  echo "rsync started"
  rsync -aAX / /mnt/temp-$LINODE_ID/ --exclude /sys/ --exclude /proc/ --exclude /dev/ --exclude /tmp/ --exclude /media/ --exclude /mnt/ --exclude /run/
  mkdir /mnt/temp-$LINODE_ID/sys /mnt/temp-$LINODE_ID/proc /mnt/temp-$LINODE_ID/dev /mnt/temp-$LINODE_ID/tmp /mnt/temp-$LINODE_ID/media /mnt/temp-$LINODE_ID/mnt /mnt/temp-$LINODE_ID/run
  echo "rsync finished"
  # Remove swap from fstab
  grep -v swap /mnt/temp-$LINODE_ID/etc/fstab > fstab.new
  cp fstab.new /mnt/temp-$LINODE_ID/etc/fstab
  rm fstab.new
  cp $0 /mnt/temp-$LINODE_ID/etc/rc.local
  chmod +x /mnt/temp-$LINODE_ID/etc/rc.local
  sed -i "s/STAGE=1/STAGE=2/" /mnt/temp-$LINODE_ID/etc/rc.local

  # Retry reboot with exponential backoff if Linode is busy
  MAX_RETRIES=5
  RETRY_COUNT=0
  WAIT_TIME=10

  while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    echo "Attempting reboot (attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)..."
    sleep $WAIT_TIME

    REBOOT_RESPONSE=$(curl -sH "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" \
        -X POST -d "{\"config_id\": $BLOCK_CONFIG_ID}" \
        https://api.linode.com/v4/linode/instances/$LINODE_ID/reboot)

    echo "$REBOOT_RESPONSE" | jq

    # Check if response contains "Linode busy" error
    if echo "$REBOOT_RESPONSE" | grep -q "Linode busy"; then
      RETRY_COUNT=$((RETRY_COUNT + 1))
      WAIT_TIME=$((WAIT_TIME * 2))  # Exponential backoff
      echo "Linode busy, waiting ${WAIT_TIME}s before retry..."
    else
      # Success or different error - exit loop
      echo "Reboot request completed"
      break
    fi
  done

  if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo "Error: Failed to reboot after $MAX_RETRIES attempts"
    exit 1
  fi
}

stage2() {
  echo "Stage 2 started"
  export LINODE_ID=`dmidecode -t1 | grep Serial | awk '{print $3}'`
  if ! [ $LINODE_ID -gt 0 ]; then
    echo "Invalid LinodeID"
    exit
  fi
  ROOT_DISK_ID=`curl -sH "Authorization: Bearer $TOKEN" \
      https://api.linode.com/v4/linode/instances/$LINODE_ID/disks | jq ".data[] | select (.label|test(\"(Ubuntu|Debian).*\")) | .id"`
  echo "Root Disk ID: $ROOT_DISK_ID"
  echo "Deleting Root Disk"
  curl -sH "Authorization: Bearer $TOKEN" \
      -X DELETE \
      https://api.linode.com/v4/linode/instances/$LINODE_ID/disks/$ROOT_DISK_ID
  while [ $ROOT_DISK_ID -gt 0 ]; do
    echo "Root disk still exist.  Waiting."
    sleep 5
    ROOT_DISK_ID=`curl -sH "Authorization: Bearer $TOKEN" \
        https://api.linode.com/v4/linode/instances/$LINODE_ID/disks | jq ".data[] | select (.label|test(\"(Ubuntu|Debian).*\")) | .id"`
    echo "ROOT_DISK_ID: $ROOT_DISK_ID"
  done
  SWAP_DISK_ID=`curl -sH "Authorization: Bearer $TOKEN" \
      https://api.linode.com/v4/linode/instances/$LINODE_ID/disks | jq ".data[] | select (.label|test(\"(Swap).*\")) | .id"`
  echo "SWAP Disk ID: $SWAP_DISK_ID"
  echo "Deleting Swap Disk"
  curl -sH "Authorization: Bearer $TOKEN" \
      -X DELETE \
      https://api.linode.com/v4/linode/instances/$LINODE_ID/disks/$SWAP_DISK_ID
  while [ $SWAP_DISK_ID -gt 0 ]; do
    echo "Swap disk still exist.  Waiting."
    sleep 5
    SWAP_DISK_ID=`curl -sH "Authorization: Bearer $TOKEN" \
        https://api.linode.com/v4/linode/instances/$LINODE_ID/disks | jq ".data[] | select (.label|test(\"(Swap).*\")) | .id"`
    echo "ROOT_DISK_ID: $ROOT_DISK_ID"
  done
  LINODE_INSTANCE_TYPE=`dmidecode -t1|grep "Family" | awk '{print $2}' | sed 's/Linode.//'`
  LINODE_DISK_MAX=`curl https://api.linode.com/v4/linode/types | jq ".data[] | select (.id == \"$LINODE_INSTANCE_TYPE\") | .disk"`
  echo "DISK_MAX: $LINODE_DISK_MAX"
  NEW_DISK_SIZE=$(($LINODE_DISK_MAX))

  echo "Instance Type: $LINODE_INSTANCE_TYPE - New Size: $NEW_DISK_SIZE"
  curl -sH "Content-Type: application/json" \
      -H "Authorization: Bearer $TOKEN" \
      -X POST -d "{
        \"label\": \"Windows\",
        \"filesystem\": \"raw\",
        \"size\": $NEW_DISK_SIZE
      }" \
      https://api.linode.com/v4/linode/instances/$LINODE_ID/disks | jq

  RAW_DISK_ID=`curl -sH "Authorization: Bearer $TOKEN" \
        https://api.linode.com/v4/linode/instances/$LINODE_ID/disks | jq ".data[] | select (.label == \"Windows\") | .id"`
  echo "RAW_DISK_ID: $RAW_DISK_ID"
  BLOCK_CONFIG_ID=`curl -sH "Authorization: Bearer $TOKEN" \
      https://api.linode.com/v4/linode/instances/$LINODE_ID/configs | jq '.data[] | select (.label == "BLOCK") | .id'`

  NEW_CONFIG=`curl -sH "Authorization: Bearer $TOKEN" \
      https://api.linode.com/v4/linode/instances/$LINODE_ID/configs | jq '.data[] | select (.label == "BLOCK")' | jq ' .devices.sdb = null' | jq " .devices.sdb.disk_id = $RAW_DISK_ID" | grep -v "\"id\":" | jq '.label = "BLOCK"' | grep -v "\"created\":" | grep -v "\"updated\":"`

  echo "## New Config"
  echo "$NEW_CONFIG" | jq
  echo

  if ! [ $BLOCK_CONFIG_ID -gt 0 ]; then
    echo "## BLOCK config doesn't exist, creating."
    curl -sH "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" \
        -X POST -d "$NEW_CONFIG"\
        https://api.linode.com/v4/linode/instances/$LINODE_ID/configs | jq
  else
    echo "## BLOCK config exists, updating."
    curl -sH "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" \
        -X PUT -d "$NEW_CONFIG"\
        https://api.linode.com/v4/linode/instances/$LINODE_ID/configs/$BLOCK_CONFIG_ID | jq
  fi

  BLOCK_CONFIG_ID=`curl -sH "Authorization: Bearer $TOKEN" \
      https://api.linode.com/v4/linode/instances/$LINODE_ID/configs | jq '.data[] | select (.label == "BLOCK") | .id'`
  echo "## BLOCK Config: $BLOCK_CONFIG_ID"

  sed -i "s/STAGE=2/STAGE=3/" /etc/rc.local

  # Retry reboot with exponential backoff if Linode is busy
  MAX_RETRIES=5
  RETRY_COUNT=0
  WAIT_TIME=10

  while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    echo "Attempting reboot (attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)..."
    sleep $WAIT_TIME

    REBOOT_RESPONSE=$(curl -sH "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" -X POST\
        https://api.linode.com/v4/linode/instances/$LINODE_ID/reboot)

    echo "$REBOOT_RESPONSE" | jq

    # Check if response contains "Linode busy" error
    if echo "$REBOOT_RESPONSE" | grep -q "Linode busy"; then
      RETRY_COUNT=$((RETRY_COUNT + 1))
      WAIT_TIME=$((WAIT_TIME * 2))  # Exponential backoff
      echo "Linode busy, waiting ${WAIT_TIME}s before retry..."
    else
      # Success or different error - exit loop
      echo "Reboot request completed"
      break
    fi
  done

  if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo "Error: Failed to reboot after $MAX_RETRIES attempts"
    exit 1
  fi
}

# Path of the install image (install.wim or install.esd) under a mounted ISO
install_image_path() {
  if [ -f "$1/sources/install.wim" ]; then
    echo "$1/sources/install.wim"
  elif [ -f "$1/sources/install.esd" ]; then
    echo "$1/sources/install.esd"
  fi
}

wim_image_count() {
  wimlib-imagex info "$1" | awk -F: '/^Image Count/ {gsub(/ /, "", $2); print $2; exit}'
}

wim_image_name() {
  wimlib-imagex info "$1" "$2" | awk -F': *' '/^Name:/ {print $2; exit}'
}

# True if image $2 of WIM $1 contains the given driver (vioscsi, netkvm, ...)
wim_has_driver() {
  wimlib-imagex dir "$1" "$2" --path=/Windows/System32/DriverStore/FileRepository 2>/dev/null | grep -qiE "/$3\.(inf|sys)$" && return 0
  wimlib-imagex dir "$1" "$2" --path=/Windows/System32/drivers 2>/dev/null | grep -qiE "/$3\.sys$"
}

# Pick which install image Setup should apply.
# W11_IMAGE_INDEX=<n> forces it; "auto" uses the only image (MicroWin) or "Windows 11 Pro".
resolve_image_index() {
  if [ -n "$W11_IMAGE_INDEX" ] && [ "$W11_IMAGE_INDEX" != "auto" ]; then
    echo "$W11_IMAGE_INDEX"
    return
  fi
  local count idx
  count=$(wim_image_count "$1")
  if [ "${count:-1}" -le 1 ]; then
    echo 1
    return
  fi
  idx=$(wimlib-imagex info "$1" | awk '/^Index:/ {i=$2} /^Name:/ && / Pro$/ {print i; exit}')
  echo "${idx:-1}"
}

# Inspects the downloaded ISO: sets IMAGE_INDEX and ISO_HAS_VIRTIO (true/false).
# The ISO counts as pre-injected (e.g. MicroWin with VirtIO drivers) when the
# Setup image in boot.wim has vioscsi and the install image has vioscsi + netkvm.
inspect_iso() {
  local iso="$1" mnt=/mnt/iso-check bootwim inst boot_idx name
  ISO_HAS_VIRTIO=false
  IMAGE_INDEX=1
  mkdir -p $mnt
  if ! mount -o loop,ro "$iso" $mnt; then
    echo "Error: $iso is not a readable ISO (download failed or wrong URL?)"
    exit 1
  fi
  bootwim="$mnt/sources/boot.wim"
  inst=$(install_image_path $mnt)
  if [ -z "$inst" ] || ! [ -f "$bootwim" ]; then
    echo "Error: sources/boot.wim or sources/install.wim/esd not found on ISO"
    umount $mnt
    exit 1
  fi
  if [ -z "$(find $mnt -maxdepth 1 -iname bootmgr -print -quit)" ]; then
    echo "Error: bootmgr missing from ISO root - it cannot boot in Linode's legacy BIOS mode"
    umount $mnt
    exit 1
  fi

  wimlib-imagex info "$inst" | grep -E '^(Index|Name):'
  IMAGE_INDEX=$(resolve_image_index "$inst")
  name=$(wim_image_name "$inst" "$IMAGE_INDEX")
  echo "Selected install image index $IMAGE_INDEX: $name"
  if [ -z "$name" ]; then
    echo "Error: install image index $IMAGE_INDEX does not exist in $(basename $inst)"
    umount $mnt
    exit 1
  fi
  if echo "$name" | grep -qi "home"; then
    echo "Warning: '$name' has no Remote Desktop host - you will only have Glish/Lish access"
  fi

  # Windows Setup runs from the last image in boot.wim (normally index 2)
  boot_idx=$(wim_image_count "$bootwim")
  local ok=true
  wim_has_driver "$bootwim" "$boot_idx" vioscsi || { echo "boot.wim index $boot_idx: vioscsi missing"; ok=false; }
  wim_has_driver "$inst" "$IMAGE_INDEX" vioscsi || { echo "install image $IMAGE_INDEX: vioscsi missing"; ok=false; }
  wim_has_driver "$inst" "$IMAGE_INDEX" netkvm  || { echo "install image $IMAGE_INDEX: netkvm missing"; ok=false; }
  ISO_HAS_VIRTIO=$ok
  echo "ISO already contains VirtIO drivers: $ISO_HAS_VIRTIO"
  umount $mnt
}

# Copy VirtIO drivers from virtio-win.iso into $WinPEDriver$ on the install media.
# Windows Setup loads every driver in that folder in WinPE (so it can see the
# virtio-scsi disk) and adds them to the installed system. No WIM editing needed.
add_winpe_drivers() {
  local media="$1" vmnt=/root/virtio-mnt osdir=w11 d n=0
  [ "$INSTALL_WINDOWS_VERSION" == "2k22" ] && osdir=2k22
  mkdir -p $vmnt
  mount -o loop,ro /virtio-win.iso $vmnt || { echo "Error: cannot mount virtio-win.iso"; return 1; }
  for d in vioscsi viostor NetKVM Balloon vioserial; do
    if [ -d "$vmnt/$d/$osdir/amd64" ]; then
      mkdir -p "$media/\$WinPEDriver\$/$d"
      cp -r "$vmnt/$d/$osdir/amd64/." "$media/\$WinPEDriver\$/$d/"
      echo "  added $d ($osdir/amd64)"
      n=$((n + 1))
    fi
  done
  umount $vmnt
  [ $n -gt 0 ]
}

# W11_ISO_URL=UPLOAD: wait until the ISO has been copied to /root/upload.iso
# and /root/iso-ready exists (created after the upload has finished).
wait_for_upload() {
  local ip n=0
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="src") print $(i+1)}')
  [ -z "$ip" ] && ip="<linode-ip>"
  rm -f /root/iso-ready
  while ! [ -f /root/iso-ready ]; do
    if [ $((n % 12)) -eq 0 ]; then
      echo "=================================================================="
      echo "Waiting for ISO upload. From your PC run:"
      echo "  scp YOUR.iso root@$ip:/root/upload.iso"
      echo "  ssh root@$ip touch /root/iso-ready"
      echo "=================================================================="
    fi
    n=$((n + 1))
    sleep 5
  done
  if ! [ -f /root/upload.iso ]; then
    echo "Error: /root/iso-ready exists but /root/upload.iso is missing"
    exit 1
  fi
  echo "Upload received ($(stat -c %s /root/upload.iso) bytes)"
  mv /root/upload.iso windows-amd64.iso
}

stage3() {

  export LINODE_ID=`dmidecode -t1 | grep Serial | awk '{print $3}'`
  if ! [ $LINODE_ID -gt 0 ]; then
    echo "Invalid LinodeID"
    exit
  fi

  # Install all required packages for stage 3 in one operation
  PACKAGES_NEEDED=false
  if ! [ -f /usr/bin/wimmount ]; then PACKAGES_NEEDED=true; fi
  if ! command -v kexec >/dev/null; then PACKAGES_NEEDED=true; fi
  if ! [ -f /usr/bin/cpio ]; then PACKAGES_NEEDED=true; fi

  if [ "$PACKAGES_NEEDED" = true ]; then
    echo "Installing required packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -yq wimtools genisoimage libwin-hivex-perl ntfs-3g kexec-tools cpio
  fi

  RAW_DISK_ID=`curl -sH "Authorization: Bearer $TOKEN" \
        https://api.linode.com/v4/linode/instances/$LINODE_ID/disks | jq ".data[] | select (.label == \"Windows\") | .id"`
   echo "RAW_DISK_ID: $RAW_DISK_ID"

  WINDOWS_CONFIG_ID=`curl -sH "Authorization: Bearer $TOKEN" \
      https://api.linode.com/v4/linode/instances/$LINODE_ID/configs | jq '.data[] | select (.label == "Windows") | .id'`

  NEW_CONFIG=`curl -sH "Authorization: Bearer $TOKEN" \
      https://api.linode.com/v4/linode/instances/$LINODE_ID/configs | jq '.data[] | select (.label == "BLOCK")' | jq ' .kernel = "linode/direct-disk" | .devices.sda.volume_id = null | .devices.sdb = null | .devices.sdc = null | .root_device = "/dev/sda"' | jq " .devices.sda.disk_id = $RAW_DISK_ID" | grep -v "\"id\":" | jq '.label = "Windows"' | grep -v "\"created\":" | grep -v "\"updated\":"`

  echo "## New Config"
  echo "$NEW_CONFIG" | jq

  if ! [ $WINDOWS_CONFIG_ID -gt 0 ]; then
    echo "## Windows config doesn't exist, creating."
    curl -sH "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" \
        -X POST -d "$NEW_CONFIG"\
        https://api.linode.com/v4/linode/instances/$LINODE_ID/configs | jq
  else
    echo "## Windows config exists, updating."
    curl -sH "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" \
        -X PUT -d "$NEW_CONFIG"\
        https://api.linode.com/v4/linode/instances/$LINODE_ID/configs/$WINDOWS_CONFIG_ID | jq
 fi

  WINDOWS_CONFIG_ID=`curl -sH "Authorization: Bearer $TOKEN" \
      https://api.linode.com/v4/linode/instances/$LINODE_ID/configs | jq '.data[] | select (.label == "Windows") | .id'`
  echo "## Windows Config: $WINDOWS_CONFIG_ID"

  # Query for the temp block volume ID
  VOLUME_ID=$(curl -sH "Authorization: Bearer $TOKEN" \
    -H "X-Filter: {\"label\": \"temp-$LINODE_ID\"}" \
    https://api.linode.com/v4/volumes | jq -r '.data[0].id')
  echo "Volume ID: $VOLUME_ID"

  if ! [ -f woeusb.sh ]; then
    wget -O woeusb.sh https://github.com/WoeUSB/WoeUSB/releases/download/v5.2.4/woeusb-5.2.4.bash
    chmod +x woeusb.sh
  fi
  if ! [ -f windows-amd64.iso ]; then
    if [ $INSTALL_WINDOWS_VERSION == "2k22" ]; then
      wget -q -O windows-amd64.iso $W2K22_ISO_URL
    fi
    if [ $INSTALL_WINDOWS_VERSION == "w11" ] && [ "${W11_ISO_URL^^}" == "UPLOAD" ]; then
      wait_for_upload
    elif [ $INSTALL_WINDOWS_VERSION == "w11" ]; then
      echo "Downloading Windows ISO from $W11_ISO_URL ..."
      wget -q --tries=5 -O windows-amd64.iso "$W11_ISO_URL"
    fi
  fi
  ISO_SIZE=$(stat -c %s windows-amd64.iso 2>/dev/null || echo 0)
  echo "ISO size: $ISO_SIZE bytes"
  if [ "$ISO_SIZE" -lt 1000000000 ]; then
    echo "Error: ISO download failed or is incomplete (< 1 GB). Check W11_ISO_URL / your tunnel."
    rm -f windows-amd64.iso
    exit 1
  fi

  inspect_iso windows-amd64.iso
  if [ $INSTALL_WINDOWS_VERSION == "w11" ]; then
    sed -i "s/IMAGE_INDEX_PLACEHOLDER/$IMAGE_INDEX/" /root/autounattend.xml
  fi

  # Drivers missing from the ISO are supplied through $WinPEDriver$ on the
  # install partition (distrobuilder's snap is no longer available).
  NEED_WINPE_DRIVERS=false
  if [ "$ISO_HAS_VIRTIO" == "true" ]; then
    echo "ISO is pre-injected with VirtIO drivers"
  else
    NEED_WINPE_DRIVERS=true
    echo "VirtIO drivers will be added via \$WinPEDriver\$"
    if ! [ -s /virtio-win.iso ]; then
      wget -q -O /virtio-win.iso "$VIRTIO_ISO_URL"
    fi
    if ! [ -s /virtio-win.iso ]; then
      echo "Error: could not download virtio-win.iso"
      exit 1
    fi
  fi
  if ! [ -f windows_virtio.iso ]; then
    ln windows-amd64.iso windows_virtio.iso
  fi
  if ! [ -f windows_virtio.iso ]; then
    echo "Error: No valid VirtIO ISO found."
    exit
  fi

  # Create manual partition layout to support >4GB files and provide empty installation target
  # Partition 1: 8GB NTFS (bootable, contains installation media)
  # Partition 2: Remaining space NTFS (empty, Windows installation target)
  echo "Creating MBR partition table on /dev/sdb..."
  parted -s /dev/sdb mklabel msdos

  echo "Creating partition 1 (8GB NTFS for installation media)..."
  parted -s /dev/sdb mkpart primary ntfs 1MiB 8GiB
  parted -s /dev/sdb set 1 boot on

  echo "Creating partition 2 (remaining space for Windows installation)..."
  parted -s /dev/sdb mkpart primary ntfs 8GiB 100%

  # Format both partitions as NTFS
  echo "Formatting partitions as NTFS..."
  mkfs.ntfs -f -Q /dev/sdb1  # Quick format for installation media
  mkfs.ntfs -f -Q /dev/sdb2  # Quick format for Windows installation target

  # Wait for partition table to update
  sleep 2
  partprobe /dev/sdb
  sleep 2

  # Use WoeUSB in partition mode to copy installation media to partition 1 only
  # This leaves partition 2 empty for Windows installation
  echo "Copying Windows installation media to /dev/sdb1 with WoeUSB..."
  if ! ./woeusb.sh --partition windows_virtio.iso /dev/sdb1; then
    echo "Error: WoeUSB failed, not continuing (temp volume and logs are kept)"
    exit 1
  fi

  # Copy autounattend.xml to the installation media partition
  echo "Copying autounattend.xml to installation media..."
  if ! mount /dev/sdb1 /mnt; then
    echo "Error: cannot mount /dev/sdb1"
    exit 1
  fi
  for f in bootmgr boot/bcd sources/boot.wim; do
    if [ -z "$(find /mnt -maxdepth 2 -ipath "/mnt/$f" -print -quit)" ]; then
      echo "Error: install media incomplete, /dev/sdb1 is missing $f - not continuing"
      umount /mnt
      exit 1
    fi
  done
  # ntfs-3g is case sensitive: drop any answer file shipped on the ISO (MicroWin
  # adds its own) so ours is the only one Setup finds. Ours installs to partition 2
  # and leaves the install media on partition 1 alone.
  find /mnt -maxdepth 1 -iname 'autounattend.xml' -delete
  cp /root/autounattend.xml /mnt/
  if [ "$NEED_WINPE_DRIVERS" == "true" ]; then
    echo "Adding VirtIO drivers to \$WinPEDriver\$..."
    if ! add_winpe_drivers /mnt; then
      echo "Error: no VirtIO drivers copied, Setup would not find the disk"
      umount /mnt
      exit 1
    fi
  fi
  umount /mnt

  # ===== kexec-based cleanup =====
  echo "Preparing cleanup environment..."

  # Build initramfs structure
  echo "Building initramfs..."
  mkdir -p /tmp/initramfs/{bin,lib,lib64,dev,proc,sys,etc}

  # Copy busybox
  cp /bin/busybox /tmp/initramfs/bin/
  ln -s busybox /tmp/initramfs/bin/sh

  # Copy curl and its shared libraries
  cp /usr/bin/curl /tmp/initramfs/bin/
  for lib in $(ldd /usr/bin/curl | grep -o '/lib[^ ]*'); do
    mkdir -p "/tmp/initramfs$(dirname $lib)"
    cp "$lib" "/tmp/initramfs$lib" 2>/dev/null || true
  done

  # Copy jq and its shared libraries
  cp /usr/bin/jq /tmp/initramfs/bin/
  for lib in $(ldd /usr/bin/jq | grep -o '/lib[^ ]*'); do
    mkdir -p "/tmp/initramfs$(dirname $lib)"
    cp "$lib" "/tmp/initramfs$lib" 2>/dev/null || true
  done

  # Copy SSL certificates for HTTPS
  echo "Copying SSL certificates..."
  mkdir -p /tmp/initramfs/etc/ssl/certs
  cp -r /etc/ssl/certs/* /tmp/initramfs/etc/ssl/certs/ 2>/dev/null || true
  # Also copy ca-certificates
  if [ -f /etc/ca-certificates.conf ]; then
    cp /etc/ca-certificates.conf /tmp/initramfs/etc/
  fi

  # Copy kernel modules for network support
  echo "Copying kernel modules..."
  KVER=$(uname -r)
  mkdir -p /tmp/initramfs/lib/modules/$KVER

  # Use modprobe --show-depends to get exact module dependencies
  echo "Querying virtio_net dependencies..."
  modprobe --show-depends virtio_net 2>/dev/null | awk '{print $2}' | while read module; do
    if [ -f "$module" ]; then
      # Create directory structure in initramfs
      module_dir=$(dirname "$module")
      mkdir -p "/tmp/initramfs$module_dir"
      # Copy the module
      cp "$module" "/tmp/initramfs$module"
      echo "  Copied: $module"
    fi
  done

  # Copy modules.dep and related files for modprobe to work
  echo "Copying module metadata..."
  cp /lib/modules/$KVER/modules.order /tmp/initramfs/lib/modules/$KVER/ 2>/dev/null || true
  cp /lib/modules/$KVER/modules.builtin /tmp/initramfs/lib/modules/$KVER/ 2>/dev/null || true
  cp /lib/modules/$KVER/modules.builtin.bin /tmp/initramfs/lib/modules/$KVER/ 2>/dev/null || true

  # Generate a minimal modules.dep for just the modules we copied
  depmod -b /tmp/initramfs $KVER 2>/dev/null || true

  # Copy modprobe and kmod
  cp /usr/bin/kmod /tmp/initramfs/bin/ 2>/dev/null || cp /bin/kmod /tmp/initramfs/bin/ 2>/dev/null || true
  ln -s kmod /tmp/initramfs/bin/modprobe 2>/dev/null || true
  ln -s kmod /tmp/initramfs/bin/insmod 2>/dev/null || true

  # Copy kmod dependencies
  for lib in $(ldd /usr/bin/kmod 2>/dev/null | grep -o '/lib[^ ]*' || ldd /bin/kmod 2>/dev/null | grep -o '/lib[^ ]*'); do
    mkdir -p "/tmp/initramfs$(dirname $lib)"
    cp "$lib" "/tmp/initramfs$lib" 2>/dev/null || true
  done

  # Capture current network configuration
  # Detect current network interface dynamically
  CURRENT_IFACE=$(ip route | grep default | awk '{print $5}')
  CURRENT_IP=$(ip -4 addr show dev $CURRENT_IFACE | grep inet | awk '{print $2}')
  CURRENT_GW=$(ip route | grep default | awk '{print $3}')
  echo "Current network: $CURRENT_IFACE with IP $CURRENT_IP, gateway $CURRENT_GW"

  # Create init script for cleanup
  echo "Creating cleanup script..."
  cat > /tmp/initramfs/init <<'INITEOF'
#!/bin/busybox sh

# Mount essential filesystems
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys

# Load network drivers
echo "Loading virtio network drivers..."
export LD_LIBRARY_PATH=/lib:/lib64
/bin/modprobe virtio_net 2>&1 || /bin/busybox echo "modprobe failed, network may not work"

# Configure networking with static IP
# Wait for network interfaces to appear (up to 10 seconds)
echo "Waiting for network interfaces..."
for i in 1 2 3 4 5 6 7 8 9 10; do
  IFACE=$(/bin/busybox ls /sys/class/net/ | /bin/busybox grep -v lo | /bin/busybox head -n 1)
  if [ -n "$IFACE" ]; then
    break
  fi
  /bin/busybox sleep 1
done

# Debug: Show all network interfaces
echo "=== Network Interface Debug ==="
/bin/busybox ls -la /sys/class/net/
/bin/busybox ip link show
echo "Detected interface: '$IFACE'"
echo "==============================="

if [ -z "$IFACE" ]; then
  echo "ERROR: No network interface detected!"
  IFACE=eth0  # Fallback to eth0
fi

echo "Using network interface: $IFACE"
/bin/busybox ip link set lo up
/bin/busybox ip addr add CURRENT_IP_PLACEHOLDER dev $IFACE
/bin/busybox ip link set $IFACE up
/bin/busybox ip route add default via CURRENT_GW_PLACEHOLDER
echo "nameserver 8.8.8.8" > /etc/resolv.conf

# Give network time to initialize
/bin/busybox sleep 3

# Verify network configuration
echo "=== Network Configuration Verification ==="
echo "IP address being set: CURRENT_IP_PLACEHOLDER"
echo "Gateway being set: CURRENT_GW_PLACEHOLDER"
echo ""
echo "Interface status:"
/bin/busybox ip addr show
echo ""
echo "Routing table:"
/bin/busybox ip route show
echo ""
echo "Testing connectivity to gateway..."
/bin/busybox ping -c 1 -W 2 CURRENT_GW_PLACEHOLDER && echo "Gateway: OK" || echo "Gateway: FAILED"
echo ""
echo "Testing connectivity to 8.8.8.8..."
/bin/busybox ping -c 1 -W 2 8.8.8.8 && echo "8.8.8.8: OK" || echo "8.8.8.8: FAILED"
echo ""
echo "Testing DNS resolution..."
/bin/busybox nslookup api.linode.com && echo "DNS: OK" || echo "DNS: FAILED"
echo "=========================================="

# Embedded variables
TOKEN="TOKEN_PLACEHOLDER"
LINODE_ID=LINODE_ID_PLACEHOLDER
VOLUME_ID=VOLUME_ID_PLACEHOLDER
WINDOWS_CONFIG_ID=WINDOWS_CONFIG_ID_PLACEHOLDER

export LD_LIBRARY_PATH=/lib:/lib64

# Test curl with verbose output
echo "=== Testing curl HTTPS connectivity ==="
echo "Attempting to fetch Linode API status..."
curl -v -H "Authorization: Bearer $TOKEN" \
  https://api.linode.com/v4/linode/instances/$LINODE_ID/configs 2>&1 | head -20
echo ""
echo "Checking SSL certificate bundle..."
ls -la /etc/ssl/certs/ | head -10
echo "=========================================="

echo "Cleaning up configuration profiles..."

# Delete Ubuntu config
UBUNTU_CONFIG_ID=$(curl -sH "Authorization: Bearer $TOKEN" \
  https://api.linode.com/v4/linode/instances/$LINODE_ID/configs | \
  jq -r '.data[] | select(.label | test("My (Ubuntu|Debian).*")) | .id')
if [ -n "$UBUNTU_CONFIG_ID" ]; then
  echo "Deleting Ubuntu config ID: $UBUNTU_CONFIG_ID"
  curl -sH "Authorization: Bearer $TOKEN" \
    -X DELETE https://api.linode.com/v4/linode/instances/$LINODE_ID/configs/$UBUNTU_CONFIG_ID
fi

# Delete BLOCK config
BLOCK_CONFIG_ID=$(curl -sH "Authorization: Bearer $TOKEN" \
  https://api.linode.com/v4/linode/instances/$LINODE_ID/configs | \
  jq -r '.data[] | select(.label == "BLOCK") | .id')
if [ -n "$BLOCK_CONFIG_ID" ]; then
  echo "Deleting BLOCK config ID: $BLOCK_CONFIG_ID"
  curl -sH "Authorization: Bearer $TOKEN" \
    -X DELETE https://api.linode.com/v4/linode/instances/$LINODE_ID/configs/$BLOCK_CONFIG_ID
fi

echo "Detaching block volume ID: $VOLUME_ID"
DETACH_RESPONSE=$(curl -sH "Authorization: Bearer $TOKEN" \
  -X POST https://api.linode.com/v4/volumes/$VOLUME_ID/detach)
echo "Detach API response: $DETACH_RESPONSE"

# Poll for detachment (60 second timeout)
echo "Waiting for volume detachment..."
DETACHED=false
for i in $(seq 1 30); do
  echo "Detachment check attempt $i/30..."
  VOLUME_STATUS=$(curl -sH "Authorization: Bearer $TOKEN" \
    https://api.linode.com/v4/volumes/$VOLUME_ID)
  ATTACHED=$(echo "$VOLUME_STATUS" | jq -r '.linode_id')
  echo "Volume status: linode_id=$ATTACHED"

  if [ "$ATTACHED" = "null" ]; then
    DETACHED=true
    echo "Volume detached successfully"
    break
  fi
  /bin/busybox sleep 2
done

# Delete volume if detached
if [ "$DETACHED" = "true" ]; then
  echo "Deleting block volume..."
  curl -sH "Authorization: Bearer $TOKEN" \
    -X DELETE https://api.linode.com/v4/volumes/$VOLUME_ID
else
  echo "Volume detachment timed out, skipping deletion"
fi

# Reboot to Windows config with retry logic
echo "Rebooting to Windows configuration..."
MAX_RETRIES=5
RETRY_COUNT=0
WAIT_TIME=10

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  /bin/busybox sleep $WAIT_TIME

  REBOOT_RESPONSE=$(curl -sH "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -X POST -d "{\"config_id\": $WINDOWS_CONFIG_ID}" \
    https://api.linode.com/v4/linode/instances/$LINODE_ID/reboot)

  if echo "$REBOOT_RESPONSE" | grep -q "Linode busy"; then
    RETRY_COUNT=$((RETRY_COUNT + 1))
    WAIT_TIME=$((WAIT_TIME * 2))
    echo "Linode busy, retrying in ${WAIT_TIME}s..."
  else
    echo "Reboot initiated successfully"
    break
  fi
done

# Fallback to forced reboot
echo "Forcing reboot in 10 seconds..."
/bin/busybox sleep 10
/bin/busybox reboot -f

# Wait indefinitely for reboot to complete (init must never exit)
echo "Waiting for reboot to complete..."
while true; do
  /bin/busybox sleep 60
done
INITEOF

  # Validate all required variables are set
  if [ -z "$VOLUME_ID" ]; then echo "ERROR: VOLUME_ID not set"; exit 1; fi
  if [ -z "$WINDOWS_CONFIG_ID" ]; then echo "ERROR: WINDOWS_CONFIG_ID not set"; exit 1; fi
  if [ -z "$LINODE_ID" ]; then echo "ERROR: LINODE_ID not set"; exit 1; fi
  if [ -z "$TOKEN" ]; then echo "ERROR: TOKEN not set"; exit 1; fi
  if [ -z "$CURRENT_IP" ]; then echo "ERROR: CURRENT_IP not set"; exit 1; fi
  if [ -z "$CURRENT_GW" ]; then echo "ERROR: CURRENT_GW not set"; exit 1; fi

  echo "Cleanup variables validated: VOLUME_ID=$VOLUME_ID LINODE_ID=$LINODE_ID WINDOWS_CONFIG_ID=$WINDOWS_CONFIG_ID"

  # Substitute placeholders with actual values
  sed -i "s|CURRENT_IP_PLACEHOLDER|$CURRENT_IP|g" /tmp/initramfs/init
  sed -i "s|CURRENT_GW_PLACEHOLDER|$CURRENT_GW|g" /tmp/initramfs/init
  sed -i "s|TOKEN_PLACEHOLDER|$TOKEN|g" /tmp/initramfs/init
  sed -i "s|LINODE_ID_PLACEHOLDER|$LINODE_ID|g" /tmp/initramfs/init
  sed -i "s|VOLUME_ID_PLACEHOLDER|$VOLUME_ID|g" /tmp/initramfs/init
  sed -i "s|WINDOWS_CONFIG_ID_PLACEHOLDER|$WINDOWS_CONFIG_ID|g" /tmp/initramfs/init

  chmod +x /tmp/initramfs/init

  # Pack initramfs
  echo "Packing initramfs..."
  cd /tmp/initramfs
  find . | cpio -o -H newc 2>/dev/null | gzip > /tmp/cleanup.cpio.gz
  cd /

  # Load kernel and initramfs with kexec
  echo "Loading cleanup environment with kexec..."

  # Extract only safe kernel parameters
  CONSOLE_PARAM=$(cat /proc/cmdline | grep -oE 'console=[^ ]+' || echo "console=ttyS0,19200n8")
  IFNAMES_PARAM=$(cat /proc/cmdline | grep -oE 'net\.ifnames=[^ ]+' || echo "net.ifnames=0")
  BIOSDEV_PARAM=$(cat /proc/cmdline | grep -oE 'biosdevname=[^ ]+' || echo "")

  KEXEC_CMDLINE="$CONSOLE_PARAM $IFNAMES_PARAM $BIOSDEV_PARAM quiet"
  echo "kexec cmdline: $KEXEC_CMDLINE"

  kexec -l /boot/vmlinuz-$(uname -r) \
    --initrd=/tmp/cleanup.cpio.gz \
    --append="$KEXEC_CMDLINE"

  # Execute kexec (this never returns)
  echo "Launching cleanup environment..."
  echo "Windows installation will continue automatically after cleanup."
  sleep 2
  kexec -e

  # Should never reach here
  echo "ERROR: kexec failed, attempting fallback direct reboot"
  sleep 5

  # Last resort: reboot to Windows config via API
  REBOOT_RESPONSE=$(curl -sH "Content-Type: application/json" \
      -H "Authorization: Bearer $TOKEN" \
      -X POST -d "{\"config_id\": $WINDOWS_CONFIG_ID}" \
      https://api.linode.com/v4/linode/instances/$LINODE_ID/reboot)

  echo "$REBOOT_RESPONSE" | jq

  # If that fails, force reboot without cleanup
  sleep 10
  reboot -f
}


createunattend() {
  if [ $INSTALL_WINDOWS_VERSION == "2k22" ]; then
cat > /root/autounattend.xml<<EOF
<?xml version="1.0" encoding="utf-8"?>
<!-- C:\Windows\Panther\unattend.xml -->
<unattend xmlns="urn:schemas-microsoft-com:unattend"
        xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <SetupUILanguage>
                <UILanguage>en-US</UILanguage>
            </SetupUILanguage>
			<InputLocale>en-US</InputLocale>
            <SystemLocale>en-US</SystemLocale>
            <UILanguage>en-US</UILanguage>
            <UserLocale>en-US</UserLocale>
        </component>
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <DiskConfiguration>
                <Disk wcm:action="add">
                    <ModifyPartitions>
                        <ModifyPartition wcm:action="add">
                            <Order>1</Order>
                            <PartitionID>2</PartitionID>
                            <Format>NTFS</Format>
                            <Label>System</Label>
                        </ModifyPartition>
                    </ModifyPartitions>
                    <DiskID>0</DiskID>
                    <WillWipeDisk>false</WillWipeDisk>
                </Disk>
            </DiskConfiguration>
            <ImageInstall>
                <OSImage>
                    <InstallFrom>
                        <MetaData wcm:action="add">
                            <Key>/IMAGE/NAME</Key>
                            <Value>Windows Server 2022 SERVERDATACENTER</Value>
                        </MetaData>
                    </InstallFrom>
                    <InstallTo>
                        <DiskID>0</DiskID>
                        <PartitionID>2</PartitionID>
                    </InstallTo>
                    <WillShowUI>OnError</WillShowUI>
                    <InstallToAvailablePartition>false</InstallToAvailablePartition>
                </OSImage>
            </ImageInstall>
            <UserData>
			    <AcceptEula>true</AcceptEula>
            </UserData>
        </component>
    </settings>
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <TimeZone>Pacific Standard Time</TimeZone>
        </component>
	<component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <fDenyTSConnections>false</fDenyTSConnections>
        </component>
        <component name="Networking-MPSSVC-Svc" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <FirewallGroups>
                <FirewallGroup wcm:action="add" wcm:keyValue="RemoteDesktop">
                    <Active>true</Active>
                    <Group>Remote Desktop</Group>
                    <Profile>all</Profile>
                </FirewallGroup>
            </FirewallGroups>
        </component>
        <component name="Microsoft-Windows-TerminalServices-RDP-WinStationExtensions" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <SecurityLayer>2</SecurityLayer>
            <UserAuthentication>1</UserAuthentication>
        </component>
	<component name="Microsoft-Windows-ServerManager-SvrMgrNc" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <DoNotOpenServerManagerAtLogon>true</DoNotOpenServerManagerAtLogon>
        </component>
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
           <RunSynchronous>
             <RunSynchronousCommand wcm:action="add">
               <Order>1</Order>
               <Path>cmd /c bcdedit /emssettings emsport:1 emsbaudrate:115200</Path>
               <Description>BCD 1</Description>
             </RunSynchronousCommand>
             <RunSynchronousCommand wcm:action="add">
               <Order>2</Order>
               <Path>cmd /c bcdedit /ems {default} on</Path>
               <Description>BCD 2</Description>
             </RunSynchronousCommand>
             <RunSynchronousCommand wcm:action="add">
               <Order>3</Order>
               <Path>cmd /c bcdedit /bootems yes</Path>
               <Description>BCD 3</Description>
             </RunSynchronousCommand>
             <RunSynchronousCommand wcm:action="add">
               <Order>4</Order>
               <Path>cmd /c bcdedit /set {emmsettings} bootems yes</Path>
               <Description>BCD 4</Description>
             </RunSynchronousCommand>
           </RunSynchronous>
         </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <AutoLogon>
                <Password>
                    <Value>$WINDOWS_PASSWORD</Value>
                    <PlainText>true</PlainText>
                </Password>
                <LogonCount>2</LogonCount>
                <Username>Administrator</Username>
                <Enabled>$AUTOLOGIN</Enabled>
            </AutoLogon>
            <UserAccounts>
                <AdministratorPassword>
                    <Value>$WINDOWS_PASSWORD</Value>
                    <PlainText>true</PlainText>
                </AdministratorPassword>
            </UserAccounts>
        </component>
    </settings>
    <cpi:offlineImage cpi:source="wim:c:/wims/install.wim#Windows Server 2022 SERVERDATACENTER" xmlns:cpi="urn:schemas-microsoft-com:cpi" />
</unattend>
EOF
  fi
  if [ $INSTALL_WINDOWS_VERSION == "w11" ]; then
cat > /root/autounattend.xml<<EOF
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <SetupUILanguage>
                <UILanguage>en-US</UILanguage>
            </SetupUILanguage>
            <InputLocale>en-US</InputLocale>
            <SystemLocale>en-US</SystemLocale>
            <UILanguage>en-US</UILanguage>
            <UILanguageFallback>en-US</UILanguageFallback>
            <UserLocale>en-US</UserLocale>
        </component>
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>reg add HKLM\System\Setup\LabConfig /v BypassTPMCheck /t reg_dword /d 0x00000001 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Path>reg add HKLM\System\Setup\LabConfig /v BypassSecureBootCheck /t reg_dword /d 0x00000001 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Path>reg add HKLM\System\Setup\LabConfig /v BypassRAMCheck /t reg_dword /d 0x00000001 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>5</Order>
                    <Path>reg add HKLM\System\Setup\LabConfig /v BypassCPUCheck /t reg_dword /d 0x00000001 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>4</Order>
                    <Path>reg add HKLM\System\Setup\LabConfig /v BypassStorageCheck /t reg_dword /d 0x00000001 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
            <DiskConfiguration>
                <Disk wcm:action="add">
                    <ModifyPartitions>
                        <ModifyPartition wcm:action="add">
                            <Order>1</Order>
                            <PartitionID>2</PartitionID>
                            <Format>NTFS</Format>
                            <Label>System</Label>
                        </ModifyPartition>
                    </ModifyPartitions>
                    <DiskID>0</DiskID>
                    <WillWipeDisk>false</WillWipeDisk>
                </Disk>
            </DiskConfiguration>
            <UserData>
                <AcceptEula>true</AcceptEula>
                <ProductKey>
                    <Key></Key>
                </ProductKey>
            </UserData>
            <ImageInstall>
                <OSImage>
                    <InstallFrom>
                        <MetaData wcm:action="add">
                            <Key>/IMAGE/INDEX</Key>
                            <Value>IMAGE_INDEX_PLACEHOLDER</Value>
                        </MetaData>
                    </InstallFrom>
                    <InstallTo>
                        <DiskID>0</DiskID>
                        <PartitionID>2</PartitionID>
                    </InstallTo>
                </OSImage>
            </ImageInstall>
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <InputLocale>en-US</InputLocale>
            <SystemLocale>en-US</SystemLocale>
            <UILanguage>en-US</UILanguage>
            <UILanguageFallback>en-US</UILanguageFallback>
            <UserLocale>en-US</UserLocale>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <AutoLogon>
                <Password>
                    <Value>$WINDOWS_PASSWORD</Value>
                    <PlainText>true</PlainText>
                </Password>
                <LogonCount>3</LogonCount>
                <Username>Administrator</Username>
                <Enabled>$AUTOLOGIN</Enabled>
            </AutoLogon>
            <UserAccounts>
                <AdministratorPassword>
                    <Value>$WINDOWS_PASSWORD</Value>
                    <PlainText>true</PlainText>
                </AdministratorPassword>
            </UserAccounts>
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Work</NetworkLocation>
                <ProtectYourPC>1</ProtectYourPC>
                <SkipUserOOBE>true</SkipUserOOBE>
                <SkipMachineOOBE>true</SkipMachineOOBE>
            </OOBE>
        </component>
    </settings>
    <settings pass="specialize">
        <component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <fDenyTSConnections>false</fDenyTSConnections>
        </component>
        <component name="Networking-MPSSVC-Svc" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <FirewallGroups>
                <FirewallGroup wcm:action="add" wcm:keyValue="RemoteDesktop">
                    <Active>true</Active>
                    <Group>Remote Desktop</Group>
                    <Profile>all</Profile>
                </FirewallGroup>
            </FirewallGroups>
        </component>
        <component name="Microsoft-Windows-TerminalServices-RDP-WinStationExtensions" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <SecurityLayer>2</SecurityLayer>
            <UserAuthentication>1</UserAuthentication>
        </component>
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Description>test</Description>
                    <Order>1</Order>
                    <Path>cmd /c echo Windows 11 Specialize &gt;&gt; C:\log.txt</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Description>Show File Extention</Description>
                    <Order>2</Order>
                    <Path>cmd /k reg add &quot;HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced&quot; /v HideFileExt /t REG_DWORD /d 0 /f &amp;&amp; exit</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Path>cmd /c reg load HKLM\DEFAULT c:\users\default\ntuser.dat &amp;&amp; reg add HKLM\DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced /v TaskbarMn  /t REG_DWORD /d 0 /f &amp;&amp; reg unload HKLM\DEFAULT &amp;&amp; exit</Path>
                    <Order>4</Order>
                    <Description>Hide Chat</Description>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Path>cmd /c reg load HKLM\DEFAULT c:\users\default\ntuser.dat &amp;&amp; reg add HKLM\DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced /v TaskbarDa  /t REG_DWORD /d 0 /f &amp;&amp; reg unload HKLM\DEFAULT &amp;&amp; exit</Path>
                    <Description>Hide Widget</Description>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
</unattend>
EOF
  fi
}

if [ $INSTALL_WINDOWS_VERSION == "2k22" ]; then
  echo "Installing Windows Server"
fi

if [ $INSTALL_WINDOWS_VERSION == "w11" ]; then
  echo "Installing Windows 11"
fi

if [ $STAGE == 1 ]; then
  createunattend
  stage1
fi
if [ $STAGE == 2 ]; then
  stage2
fi
if [ $STAGE == 3 ]; then
  createunattend
  stage3
fi

