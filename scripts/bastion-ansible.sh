#!/usr/bin/env bash
# Run an Ansible playbook against private Azure VMs through an Azure Bastion tunnel, with Entra ID
# SSH sign-in, and leave nothing behind.
#
#   scripts/bastion-ansible.sh --resource-group <rg> --playbook <playbook.yml> [-- <ansible-playbook args>]
#
# What it does:
#   1. Finds the tunnelling (Standard or Premium, native client) bastion in the resource group.
#   2. Builds the inventory from the VMs' AnsibleGroups tag (comma-separated group names).
#   3. Opens one `az network bastion tunnel` per VM, each on its own localhost port.
#   4. Gets a short-lived Entra ID OpenSSH certificate for the signed-in Azure identity
#      (`az ssh config`), so no SSH key is stored or distributed anywhere.
#   5. Runs ansible-playbook, then ALWAYS closes the tunnels and deletes the certificate, keys,
#      inventory and known_hosts, whether the playbook passed or failed.
#
# Needs: a signed-in Azure CLI (az login, or azure/login in CI) with the bastion and ssh extensions,
# Reader on the VMs, their NICs and the bastion, and Virtual Machine Administrator Login on the VMs
# (the stack's access window grants both to the identity running Terraform); ansible-playbook.
set -euo pipefail

usage() {
  sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

resource_group=""
playbook=""
base_port=50022
ready_timeout=180
extra_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -g | --resource-group) resource_group="$2"; shift 2 ;;
    -p | --playbook) playbook="$2"; shift 2 ;;
    --base-port) base_port="$2"; shift 2 ;;
    --ready-timeout) ready_timeout="$2"; shift 2 ;;
    -h | --help) usage 0 ;;
    --) shift; extra_args=("$@"); break ;;
    *) echo "Unknown argument: $1" >&2; usage 2 ;;
  esac
done

[[ -n "$resource_group" && -n "$playbook" ]] || usage 2
[[ -f "$playbook" ]] || { echo "Playbook not found: $playbook" >&2; exit 2; }

log() { printf '[bastion-ansible] %s\n' "$*" >&2; }

# A tunnel is ready once its local port is listening. The CLI's own "Tunnel is ready" line is no use
# here: az runs Python in isolated mode, so PYTHONUNBUFFERED is ignored and the line sits in a buffer.
port_listening() {
  if command -v ss >/dev/null 2>&1; then
    ss -Hltn "sport = :$1" | grep -q .
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
  fi
}

workdir="$(mktemp -d)"
chmod 700 "$workdir"
tunnel_pids=()

# Each tunnel runs in its own process group (setsid), because `az` is a wrapper script around
# Python: killing only its PID leaves the Python tunnel running.
cleanup() {
  local rc=$? pid
  if [[ ${#tunnel_pids[@]} -gt 0 ]]; then
    log "Closing ${#tunnel_pids[@]} tunnel(s)."
    for pid in "${tunnel_pids[@]}"; do kill -- -"$pid" 2>/dev/null || true; done
    wait "${tunnel_pids[@]}" 2>/dev/null || true
  fi
  rm -rf "$workdir"
  log "Removed the certificate, keys, inventory and known_hosts."
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

az extension add --name bastion --only-show-errors >/dev/null 2>&1 || true
az extension add --name ssh --only-show-errors >/dev/null 2>&1 || true

bastion="$(az network bastion list --resource-group "$resource_group" \
  --query "[?enableTunneling] | [0].name" --output tsv --only-show-errors)"
if [[ -z "$bastion" ]]; then
  log "No bastion with native client tunnelling in $resource_group: open the access window first."
  exit 1
fi
log "Bastion: $bastion"

mapfile -t vms < <(az vm list --resource-group "$resource_group" \
  --query "[?tags.AnsibleGroups].[name, id, tags.AnsibleGroups]" --output tsv --only-show-errors)
if [[ ${#vms[@]} -eq 0 ]]; then
  log "No VMs tagged AnsibleGroups in $resource_group."
  exit 1
fi

# One short-lived certificate for the signed-in identity covers every tunnelled host (all 127.0.0.1).
# Host keys are pinned per VM name through HostKeyAlias in a known_hosts that lives only for this
# run: the tunnel already authenticates the target VM through Azure, so first-use acceptance is safe.
az ssh config --ip 127.0.0.1 --file "$workdir/ssh_config" \
  --keys-destination-folder "$workdir/keys" --overwrite --only-show-errors >/dev/null
# az writes the file without a trailing newline, so start the appended block on a fresh line.
cat >>"$workdir/ssh_config" <<EOF

Host *
  StrictHostKeyChecking accept-new
  UserKnownHostsFile $workdir/known_hosts
  ServerAliveInterval 30
EOF
log "Entra ID SSH certificate issued for $(awk '/^[[:space:]]*User /{print $2; exit}' "$workdir/ssh_config")."

declare -A groups=()
{
  echo "[bastion_tunnelled]"
  port="$base_port"
  for line in "${vms[@]}"; do
    IFS=$'\t' read -r name id tag_groups <<<"$line"

    setsid az network bastion tunnel --name "$bastion" --resource-group "$resource_group" \
      --target-resource-id "$id" --resource-port 22 --port "$port" --only-show-errors \
      >"$workdir/tunnel-$name.log" 2>&1 &
    tunnel_pids+=("$!")

    deadline=$((SECONDS + ready_timeout))
    until port_listening "$port"; do
      if ! kill -0 "${tunnel_pids[-1]}" 2>/dev/null || ((SECONDS > deadline)); then
        log "Tunnel to $name did not come up:"
        cat "$workdir/tunnel-$name.log" >&2
        exit 1
      fi
      sleep 2
    done
    log "Tunnel to $name is ready on 127.0.0.1:$port."

    echo "$name ansible_host=127.0.0.1 ansible_port=$port ansible_ssh_common_args='-F $workdir/ssh_config -o HostKeyAlias=$name'"
    IFS=',' read -r -a host_groups <<<"$tag_groups"
    for group in "${host_groups[@]}"; do
      group="${group// /}"
      [[ -n "$group" ]] && groups["$group"]+="$name"$'\n'
    done
    port=$((port + 1))
  done
  for group in "${!groups[@]}"; do
    printf '\n[%s]\n%s' "$group" "${groups[$group]}"
  done
} >"$workdir/inventory.ini"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ANSIBLE_CONFIG="${ANSIBLE_CONFIG:-$script_dir/../ansible/ansible.cfg}"

log "Running $playbook against ${#vms[@]} VM(s)."
ansible-playbook --inventory "$workdir/inventory.ini" "$playbook" "${extra_args[@]}"
