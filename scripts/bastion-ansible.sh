#!/usr/bin/env bash
# Run an Ansible playbook against private Azure VMs through an Azure Bastion tunnel, and leave
# nothing behind.
#
#   scripts/bastion-ansible.sh --resource-group <rg> --playbook <playbook.yml> [--auth entra|key]
#                              [-- <ansible-playbook args>]
#
# What it does:
#   1. Finds the tunnelling (Standard or Premium, native client) bastion in the resource group.
#   2. Builds the inventory from the VMs' AnsibleGroups tag (comma-separated group names).
#   3. Opens one `az network bastion tunnel` per VM, each on its own localhost port.
#   4. Signs in one of two ways:
#      --auth entra (default): a short-lived Entra ID OpenSSH certificate for the signed-in Azure
#        identity (`az ssh config`). No key is stored anywhere.
#      --auth key: the private key named by each VM's AnsibleSshKeySecret tag (a key vault secret
#        id), as the user in its AnsibleUser tag. The tunnel cannot read Key Vault itself, so the
#        script fetches the key to a 0600 file, opening the vault's firewall to this machine only for
#        the fetch with the LibreDevOpsHelpers key vault dance (Add-/Remove-LdoKeyVaultCurrentIpRule).
#   5. Runs ansible-playbook, then ALWAYS closes the tunnels, closes any vault firewall rule it
#      opened, and deletes the certificate, keys, inventory and known_hosts, pass or fail.
#
# Needs: a signed-in Azure CLI (az login, or azure/login in CI) with the bastion and ssh extensions,
# Reader on the VMs, their NICs and the bastion, and ansible-playbook. --auth entra also needs
# Virtual Machine Administrator Login on the VMs (the stack's access window grants it to the identity
# running Terraform); --auth key needs Get on the vault's secrets, the right to change its network
# rules (the deployer has both), and PowerShell 7 for LibreDevOpsHelpers (installed if missing).
set -euo pipefail

usage() {
  sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

resource_group=""
playbook=""
auth="entra"
base_port=50022
ready_timeout=180
extra_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -g | --resource-group) resource_group="$2"; shift 2 ;;
    -p | --playbook) playbook="$2"; shift 2 ;;
    -a | --auth) auth="$2"; shift 2 ;;
    --base-port) base_port="$2"; shift 2 ;;
    --ready-timeout) ready_timeout="$2"; shift 2 ;;
    -h | --help) usage 0 ;;
    --) shift; extra_args=("$@"); break ;;
    *) echo "Unknown argument: $1" >&2; usage 2 ;;
  esac
done

[[ -n "$resource_group" && -n "$playbook" ]] || usage 2
[[ -f "$playbook" ]] || { echo "Playbook not found: $playbook" >&2; exit 2; }
[[ "$auth" == "entra" || "$auth" == "key" ]] || { echo "--auth must be entra or key" >&2; exit 2; }

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
opened_vaults=()

# Run a LibreDevOpsHelpers command in PowerShell 7 (the same engine the terraform-azure action runs),
# installing the module from PSGallery first when it is missing.
ldo() {
  pwsh -NoProfile -NonInteractive -Command "\$ErrorActionPreference = 'Stop'
    if (-not (Get-Module -ListAvailable LibreDevOpsHelpers)) { Install-Module LibreDevOpsHelpers -Scope CurrentUser -Force -AllowClobber }
    Import-Module LibreDevOpsHelpers
    Set-LdoLogFormat -Format Text
    $1" >&2
}

# Close the firewall rule the dance opened. -RuleOnly removes just this machine's IP rule and leaves
# the vault's network configuration (deny-by-default) to Terraform, which owns it. Each entry is
# "<resource group>/<vault>".
close_vault() {
  ldo "Remove-LdoKeyVaultCurrentIpRule -ResourceGroup '${1%%/*}' -KeyVaultName '${1#*/}' -RuleOnly" ||
    log "Could not close the ${1#*/} firewall: remove this machine's IP rule by hand."
}

# Each tunnel runs in its own process group (setsid), because `az` is a wrapper script around
# Python: killing only its PID leaves the Python tunnel running.
cleanup() {
  local rc=$? pid
  if [[ ${#tunnel_pids[@]} -gt 0 ]]; then
    log "Closing ${#tunnel_pids[@]} tunnel(s)."
    for pid in "${tunnel_pids[@]}"; do kill -- -"$pid" 2>/dev/null || true; done
    wait "${tunnel_pids[@]}" 2>/dev/null || true
  fi
  local vault
  for vault in "${opened_vaults[@]}"; do close_vault "$vault"; done
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
  --query "[?tags.AnsibleGroups].[name, id, tags.AnsibleGroups, tags.AnsibleUser || '', tags.AnsibleSshKeySecret || '']" \
  --output tsv --only-show-errors)
if [[ ${#vms[@]} -eq 0 ]]; then
  log "No VMs tagged AnsibleGroups in $resource_group."
  exit 1
fi

# Fetch one VM's private key from the key vault secret id in its AnsibleSshKeySecret tag. The vault
# firewall is opened to this machine only when it is not already, and closed again straight after.
fetch_key() {
  local name="$1" secret_id="$2" vault vault_rg target attempt
  vault="${secret_id#https://}"
  vault="${vault%%.*}"
  vault_rg="$(az keyvault show --name "$vault" --query resourceGroup --output tsv --only-show-errors)"
  target="$vault_rg/$vault"
  ldo "Add-LdoKeyVaultCurrentIpRule -ResourceGroup '$vault_rg' -KeyVaultName '$vault'"
  opened_vaults+=("$target")
  # A new network rule can take a little while to apply, so retry the read.
  for attempt in $(seq 1 18); do
    if az keyvault secret show --id "$secret_id" --query value --output tsv --only-show-errors \
      >"$workdir/keys/$name" 2>/dev/null && [[ -s "$workdir/keys/$name" ]]; then
      chmod 600 "$workdir/keys/$name"
      break
    fi
    if ((attempt == 18)); then
      log "Could not read $secret_id."
      return 1
    fi
    sleep 5
  done
  close_vault "$target"
  local keep=() opened
  for opened in "${opened_vaults[@]}"; do
    if [[ "$opened" != "$target" ]]; then keep+=("$opened"); fi
  done
  opened_vaults=("${keep[@]}")
  log "Fetched the SSH key for $name from $vault."
}

mkdir -m 700 "$workdir/keys"
if [[ "$auth" == "entra" ]]; then
  # One short-lived certificate for the signed-in identity covers every tunnelled host (all
  # 127.0.0.1).
  az ssh config --ip 127.0.0.1 --file "$workdir/ssh_config" \
    --keys-destination-folder "$workdir/keys" --overwrite --only-show-errors >/dev/null
  log "Entra ID SSH certificate issued for $(awk '/^[[:space:]]*User /{print $2; exit}' "$workdir/ssh_config")."
fi

# Host keys are pinned per VM name through HostKeyAlias in a known_hosts that lives only for this
# run: the tunnel already authenticates the target VM through Azure, so first-use acceptance is safe.
# az writes its file without a trailing newline, so start the appended block on a fresh line.
cat >>"$workdir/ssh_config" <<EOF

Host *
  StrictHostKeyChecking accept-new
  UserKnownHostsFile $workdir/known_hosts
  ServerAliveInterval 30
EOF

declare -A groups=()
{
  echo "[bastion_tunnelled]"
  port="$base_port"
  for line in "${vms[@]}"; do
    IFS=$'\t' read -r name id tag_groups tag_user tag_secret <<<"$line"

    host_auth=""
    if [[ "$auth" == "key" ]]; then
      [[ -n "$tag_user" && -n "$tag_secret" ]] ||
        { log "$name has no AnsibleUser and AnsibleSshKeySecret tags for --auth key."; exit 1; }
      fetch_key "$name" "$tag_secret"
      host_auth=" ansible_user=$tag_user ansible_ssh_private_key_file=$workdir/keys/$name"
    fi

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

    echo "$name ansible_host=127.0.0.1 ansible_port=$port${host_auth} ansible_ssh_common_args='-F $workdir/ssh_config -o HostKeyAlias=$name -o IdentitiesOnly=yes'"
    IFS=',' read -r -a host_groups <<<"$tag_groups"
    for group in "${host_groups[@]}"; do
      group="${group// /}"
      if [[ -n "$group" ]]; then groups["$group"]+="$name"$'\n'; fi
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
