<div align="center">
  <a href="https://libredevops.org">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://libredevops.org/assets/libre-devops-white.png">
      <img alt="Libre DevOps" src="https://libredevops.org/assets/libre-devops-black.png" width="300">
    </picture>
  </a>
</div>

# Azure Orchestration

End-to-end builds that put the Libre DevOps Terraform modules, the `terraform-azure` action and the
Ansible roles together, from a GitHub-hosted runner, against VMs nobody can reach from outside.

[![CI](https://github.com/libre-devops/azure-orchestration/actions/workflows/ci.yml/badge.svg)](https://github.com/libre-devops/azure-orchestration/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/libre-devops/azure-orchestration)](./LICENSE)

---

## MDE Linux VM

[`stacks/mde-linux`](./stacks/mde-linux) builds an Ubuntu 24.04 VM and
[`ansible/playbooks/mde-linux.yml`](./ansible/playbooks/mde-linux.yml) installs Microsoft Defender for
Endpoint on it with [`libre_devops.mde_linux`](https://github.com/libre-devops/ansible-role-mde-linux).
The VM has no public IP and the runner has no network path to it (no VPN, firewall or private
endpoint).

### How the runner reaches the VM

Ansible runs on the GitHub-hosted runner and connects through an **access window** that is open only
while it runs:

| Step | What happens |
|---|---|
| 1. Open | `terraform apply -var=access_enabled=true` adds a Standard Azure Bastion with native client tunnelling, its public IP, and the Virtual Machine Administrator Login role for the identity running Terraform (the CI service principal). |
| 2. Configure | [`scripts/bastion-ansible.sh`](./scripts/bastion-ansible.sh) finds the bastion and the VMs tagged `AnsibleGroups`, opens one `az network bastion tunnel` per VM on its own localhost port, signs in (see below), and runs the playbook against `127.0.0.1:<port>`. |
| 3. Close | `terraform apply -var=access_enabled=false` runs **always**, even when step 1 or 2 failed, and removes the bastion, its public IP and the sign-in role. |
| Sweep | An hourly workflow closes any window a hard-cancelled run left open (it only runs Terraform when a bastion is actually there, and never under a run that is using it). |

Everything billable or privileged in the window lives only as long as the run: the bastion and its
public IP (Standard bastions bill by the hour, unlike the free Developer SKU, which cannot tunnel),
the sign-in role, the runner's key vault firewall rule, the tunnels (closed when the script exits),
and the certificate or fetched key, inventory and known_hosts (in a temporary directory deleted when
the script exits, pass or fail). What stays is what
the VM needs to do its job: the VM, its NAT gateway (Defender for Endpoint talks to its cloud
continuously, and the network module's subnets have no implicit outbound access), the network and the
free `AzureBastionSubnet`.

### Signing in: `entra` or `key`

The deploy workflow's `ssh_auth` input (the script's `--auth`) picks one; both work against the same
VM.

- **`entra` (default)**: [Entra ID SSH](https://learn.microsoft.com/entra/identity/devices/howto-vm-sign-in-azure-ad-linux)
  through the [vm-entra-login](https://github.com/libre-devops/terraform-azurerm-vm-entra-login)
  module. The runner's identity gets an OpenSSH certificate Entra ID issues on demand (`az ssh
  config`), and the window's Virtual Machine Administrator Login role gives it the passwordless
  `sudo` the role's `become` needs. No key exists to leak.
- **`key`**: the admin account's own key pair, which the
  [ssh-key](https://github.com/libre-devops/terraform-azurerm-ssh-key) module generates with an
  *ephemeral* `tls_private_key`, so the private key is never in the plan or state; both halves go
  into the stack's key vault write-only, and the public half becomes the VM's admin key. The VM's
  `AnsibleUser` and `AnsibleSshKeySecret` tags tell the script who to sign in as and where the key
  is. `az network bastion tunnel` cannot read Key Vault itself, so the script fetches the key into a
  `0600` file in its temporary directory, opening the vault's firewall to the runner only for the
  fetch (LibreDevOpsHelpers' `Add-` and `Remove-LdoKeyVaultCurrentIpRule`, the same dance the
  terraform-azure action does), and deletes it on exit. It is a standing credential, so it doubles
  as the break-glass key, rotated by bumping the module's `value_wo_version`.

The key vault is deny-by-default with nothing allow-listed between runs. Every Terraform step goes
through the terraform-azure action's key vault dance and also passes the runner's IP as
`key_vault_ip_rules`: on a first run there is no vault yet for the dance to open, so that is what lets
the vault and the key be created in one apply, and on every run it stops Terraform revoking its own
access mid-apply (a closing apply that removed the rule had its later secret updates refused, found on
a live run). The dance removes the rule after each step. It uses access
policies (a new RBAC assignment takes minutes to apply, too slow for a first run), and purge
protection is off so a destroy frees its globally unique name (Trivy reports AZU-0016 as MEDIUM, by
design).

### What a run costs in time

Measured on a live run in UK South (Standard bastion, one VM):

| Phase | Time | Notes |
|---|---|---|
| Open the window (first run, whole stack) | 12m 16s | Almost all of it the bastion (11m 25s); the VM took 48s. |
| Ansible through the tunnel, first run | 56s | Tunnel ready in about a second; repository, keys, `mdatp` installed and started. |
| Ansible through the tunnel, rerun | 17s | `changed=0`. |
| Close the window | 6m 59s | The bastion's deletion (5m 49s); the sign-in role goes in 2s. |

So the bastion bills for roughly 20 minutes per run, and is gone the rest of the time.

### Modules and tools

| Piece | Used for |
|---|---|
| [`libre-devops/terraform-azure`](https://github.com/libre-devops/terraform-azure) action | Every Terraform run in the pipelines: OIDC sign-in, the state storage firewall dance, tflint, trivy and the naming policies. |
| tags, rg, network, nsg, public-ip, nat-gateway modules | The resource group, a VM subnet admitting SSH from the bastion subnet only, the `AzureBastionSubnet`, and NAT egress. |
| [linux-vm](https://github.com/libre-devops/terraform-azurerm-linux-vm) | The hardened Ubuntu VM (Trusted Launch, system-assigned identity). |
| [vm-entra-login](https://github.com/libre-devops/terraform-azurerm-vm-entra-login) | Entra ID SSH on the VM (sourced from its GitHub tag until it is published on the Terraform Registry). |
| [bastion](https://github.com/libre-devops/terraform-azurerm-bastion), [role-assignment](https://github.com/libre-devops/terraform-azurerm-role-assignment) | The access window. |
| [keyvault](https://github.com/libre-devops/terraform-azurerm-keyvault), [ssh-key](https://github.com/libre-devops/terraform-azurerm-ssh-key) | The deny-by-default vault and the ephemerally generated admin key pair. |
| [LibreDevOpsHelpers](https://www.powershellgallery.com/packages/LibreDevOpsHelpers) | The runner's egress IP and the key vault firewall dance for the `key` sign-in. |
| [`libre_devops.mde_linux`](https://galaxy.ansible.com/ui/standalone/roles/libre_devops/mde_linux/documentation/) | Defender for Endpoint: repository, package, onboarding and health checks. |

### Running it

**Deploy** with the `MDE Linux VM - deploy` workflow (`just deploy dev`, or `just deploy dev key` for the
vaulted key): pick the workspace and the sign-in, and tick
`destroy_after` for an end-to-end test that tears everything down at the end instead of closing the
window. **Destroy** with `MDE Linux VM - destroy` (type the workspace name to confirm).

The pipelines use the org's existing `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID`
variables and `TFSTATE_*` secrets. Onboarding is optional:

| Name | Kind | Purpose |
|---|---|---|
| `MDE_ONBOARDING_JSON` | Secret | The content of `mdatp_onboard.json` from the Defender portal (Settings > Endpoints > Onboarding > Linux Server > "Your preferred Linux configuration management tool"). The workflow writes it to a `0600` temporary file for the role and deletes it afterwards. Without it, the agent installs but is not onboarded. |
| `MDE_EXPECTED_ORG_ID` | Variable | Optional: the organisation ID the role checks the device onboarded to. |

To run the Ansible step yourself against a stack whose window is open: `az login`, then
`just configure rg-mde-ldo-uks-dev-001` (Entra ID sign-in; your identity needs the Virtual Machine
Administrator Login role on the resource group, which the window grants to whoever runs Terraform),
or `just configure rg-mde-ldo-uks-dev-001 key` for the vaulted key.

### Requirements on the runner

The Azure CLI with the `bastion` and `ssh` extensions (the script adds them), `ansible-core`, bash,
and for `--auth key` PowerShell 7 with LibreDevOpsHelpers (the script installs the module from
PSGallery if it is missing). GitHub's `ubuntu-latest` image has everything but Ansible, which the
workflow installs with pipx.

## Developing

`just validate` runs what CI runs: `terraform fmt`, `validate` and `tflint` for every stack, a
`trivy config` scan, `shellcheck`, and an Ansible syntax check of every playbook. New builds go in
their own `stacks/<name>` with a playbook in `ansible/playbooks` and their own workflows, following the
same open, configure, close shape.

## Security scan exceptions

None. Waivers would live in [`.trivyignore.yaml`](./.trivyignore.yaml) with a matching row here.
