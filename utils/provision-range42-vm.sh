#!/bin/bash

VMID=100
NAME="range42-mcs"
STORAGE="local-lvm"
IMAGE="/var/lib/vz/template/iso/ubuntu-24.04-server-cloudimg-amd64.img"

# TODO: Think how to get cloud init to that location.
# TODO: Adapt script to consider the variable.
CLINIT_PATH="/var/lib/vz/snippets/range42-mcs.cloud-init.yml"
CLINIT_SNIPPET="snippets/$(basename "${CLINIT_PATH}")"
ENV_FILE="./.env"

# Fetch the cloud-init image if missing
if [ ! -f "${IMAGE}" ]; then
  wget https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img -O "${IMAGE}"
fi

# Create API token and update token secret in the existing env file on the PVE node.
# token_secret=$(pveum user token add root@pam range42_api_main --privsep 0 | awk -F': ' '/token secret/ {print $2}')
# sed -i.bak "s|^PROXMOX_API_TOKEN_SECRET=.*|PROXMOX_API_TOKEN_SECRET=\"${token_secret}\"|" "${ENV_FILE}"

# Inject SSH keys into cloud-init if there are multiple keys available
if [ -f /root/.ssh/authorized_keys ]; then
  key_count=$(wc -l < /root/.ssh/authorized_keys | tr -d ' ')
  if [ "${key_count}" -gt 1 ] && [ -f "${CLINIT_PATH}" ]; then
    awk '
      BEGIN { in_keys = 0 }
      /^    ssh_authorized_keys:/ {
        print
        while ((getline key < "/root/.ssh/authorized_keys") > 0) {
          if (key ~ /./) {
            print "      - " key
          }
        }
        close("/root/.ssh/authorized_keys")
        in_keys = 1
        next
      }
      in_keys && /^      - / { next }
      { in_keys = 0; print }
    ' "${CLINIT_PATH}" > "${CLINIT_PATH}.tmp" && mv "${CLINIT_PATH}.tmp" "${CLINIT_PATH}"
  fi
fi


# Create VM
qm create $VMID \
  --name $NAME \
  --memory 2048 \
  --cores 1 \
  --cpu x86-64-v2-AES \
  --net0 virtio,bridge=vmbr0,firewall=1 \
  --scsihw virtio-scsi-single \
  --ostype l26 \
  --agent 1

# Import and attach disk
qm importdisk $VMID $IMAGE $STORAGE
qm set $VMID --scsi0 $STORAGE:vm-$VMID-disk-0,discard=on,ssd=1,iothread=1
qm resize $VMID scsi0 32G

# Add cloud-init
qm set $VMID --ide2 $STORAGE:cloudinit
qm set $VMID --boot order=scsi0
qm set $VMID --sshkeys /root/.ssh/authorized_keys
qm set $VMID --ipconfig0 ip=dhcp
qm set $VMID --nameserver 8.8.8.8

# Add custom cloud-init with packages
qm set $VMID --cicustom "user=local:${CLINIT_SNIPPET}"

# Start VM
qm start $VMID

echo "VM $VMID created and started. Cloud-init will create range42-operator, install packages, and reboot after first boot."
