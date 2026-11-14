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
Ansible roles together, from a GitHub-hosted runner, against VMs nobody can reach from outside: one
Terraform apply builds the VMs and configures them through an Azure Bastion that exists only for
that apply.

[![CI](https://github.com/libre-devops/azure-orchestration/actions/workflows/ci.yml/badge.svg)](https://github.com/libre-devops/azure-orchestration/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/libre-devops/azure-orchestration)](./LICENSE)

---

## MDE Linux VM

[`stacks/mde-linux`](./stacks/mde-linux) builds an Ubuntu 24.04 VM and installs Microsoft Defender
for Endpoint on it with [`libre_devops.mde_linux`](https://github.com/libre-devops/ansible-role-mde-linux),
run from Terraform by [terraform-ansible-role](https://github.com/libre-devops/terraform-ansible-role)
after [`libre_devops.python`](https://github.com/libre-devops/ansible-role-python). The VM has no
public IP and the runner has no network path to it (no VPN, firewall or private endpoint).

### How the runner reaches the VM

Ansible runs on the GitHub-hosted runner and connects through a **bastion session** from the
[bastion-session](https://github.com/libre-devops/terraform-azurerm-bastion-session) module, which
exists only during an apply with `configure = true`. One apply does all of it:

| Step | What happens |
|---|---|
| Open | The module grants the identity running Terraform (the CI service principal) the Virtual Machine Administrator Login role on the VM, or fetches the vaulted SSH key, creates a Standard Azure Bastion with native client tunnelling and its public IP with `az`, and waits until SSH signs in through it. |
| Configure | Two terraform-ansible-role calls run through the session, chained with `depends_on`: `libre_devops.python`, then `libre_devops.mde_linux` on the `mde_linux` hosts. Their SSH connections go through the session's `ProxyCommand` and one `az network bastion tunnel` per VM. |
| Close | Once both calls have finished, the module deletes the bastion, its public IP and the role assignment, and removes the certificate or key. |
| Always | A failed role run stops the apply before the close step, so the deploy workflow then always runs the session's close script, which deletes whatever the apply left (and does nothing when the apply closed the session itself). |
| Sweep | An hourly workflow closes a session a hard-cancelled run left behind. It runs the same close script, only when it finds something the session created, and never under a run that is using it. |

The bastion is created and deleted with `az` from inside the apply rather than as a Terraform
resource, because Terraform cannot create and delete the same resource in one apply. That is what
the old pattern of two applies (open the window, run Ansible, apply again to close it) worked around,
and what the module replaces.

Everything billable or privileged lives only as long as the apply: the bastion and its public IP
(Standard bastions bill by the hour, unlike the free Developer SKU, which cannot tunnel), the
sign-in role, the runner's key vault firewall rule, the tunnels, and the certificate or fetched key.
What stays is what the VM needs to do its job: the VM, its NAT gateway (Defender for Endpoint talks
to its cloud continuously, and the network module's subnets have no implicit outbound access), the
network and the free `AzureBastionSubnet`. An apply with `configure = false` (the stack's default)
is an ordinary infrastructure apply and creates none of it.

### Signing in: `entra` or `key`

The deploy workflow's `ssh_auth` input (the stack's `ssh_auth` variable, passed to the session's
`auth`) picks one; both work against the same VM.

- **`entra` (default)**: [Entra ID SSH](https://learn.microsoft.com/entra/identity/devices/howto-vm-sign-in-azure-ad-linux)
  through the [vm-entra-login](https://github.com/libre-devops/terraform-azurerm-vm-entra-login)
  module. The runner's identity gets an OpenSSH certificate Entra ID issues on demand (`az ssh
  cert`), and the session's Virtual Machine Administrator Login role gives it the passwordless
  `sudo` the roles' `become` needs. No key exists to leak.
- **`key`**: the admin account's own key pair, which the
  [ssh-key](https://github.com/libre-devops/terraform-azurerm-ssh-key) module generates with an
  *ephemeral* `tls_private_key`, so the private key is never in the plan or state; both halves go
  into the stack's key vault write-only, and the public half becomes the VM's admin key. The
  session's target gives the user (`azureuser`) and the key's secret ID. `az network bastion tunnel`
  cannot read Key Vault itself, so the session fetches the key into a `0600` file in its working
  directory and deletes it when it closes. In the pipeline the runner is already on the vault's
  firewall for the apply (see below); anywhere else the session opens the firewall to the machine
  only for the fetch (LibreDevOpsHelpers' `Add-` and `Remove-LdoKeyVaultCurrentIpRule`). It is a
  standing credential, so it doubles as the break-glass key, rotated by bumping the module's
  `value_wo_version`.

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

Measured on live runs of the bastion-session module's examples in UK South (Standard bastion, one
Ubuntu VM), which use the same pieces as this stack:

| Phase | Time | Notes |
|---|---|---|
| Open the session | 11 to 13 minutes | Almost all of it the bastion's creation; the sign-in role (or key fetch), the certificate and the first SSH sign-in take seconds. |
| `libre_devops.python` through the session | 8 to 9s | Nothing to change on Ubuntu. |
| `libre_devops.mde_linux` through the same session | 1m 4s | First run: repository, keys, `mdatp` installed and started. |
| Close the session | About 8 minutes | The bastion's deletion; the sign-in role goes first, in seconds. |

So the bastion bills for roughly 20 minutes per run, inside one apply, and is gone the rest of the
time. An apply with `configure = false` takes as long as the infrastructure changes and no more.

### Modules and tools

| Piece | Used for |
|---|---|
| [`libre-devops/terraform-azure`](https://github.com/libre-devops/terraform-azure) action | Every Terraform run in the pipelines: OIDC sign-in, the state storage firewall dance, tflint, trivy and the naming policies. |
| tags, rg, network, nsg, public-ip, nat-gateway modules | The resource group, a VM subnet admitting SSH from the bastion subnet only, the `AzureBastionSubnet`, and NAT egress. |
| [linux-vm](https://github.com/libre-devops/terraform-azurerm-linux-vm) | The hardened Ubuntu VM (Trusted Launch, system-assigned identity). |
| [vm-entra-login](https://github.com/libre-devops/terraform-azurerm-vm-entra-login) | Entra ID SSH on the VM (sourced from its GitHub tag until it is published on the Terraform Registry). |
| [bastion-session](https://github.com/libre-devops/terraform-azurerm-bastion-session) | The bastion, its public IP and the sign-in role for the length of the apply, and the SSH connections through them (sourced from its GitHub commit until it is tagged and published on the Terraform Registry). |
| [terraform-ansible-role](https://github.com/libre-devops/terraform-ansible-role) | Runs each Ansible role from Terraform, through the session (sourced from its GitHub tag). |
| [keyvault](https://github.com/libre-devops/terraform-azurerm-keyvault), [ssh-key](https://github.com/libre-devops/terraform-azurerm-ssh-key) | The deny-by-default vault and the ephemerally generated admin key pair. |
| [LibreDevOpsHelpers](https://www.powershellgallery.com/packages/LibreDevOpsHelpers) | The runner's egress IP, and the key vault firewall dance for the `key` sign-in outside the pipeline. |
| [`libre_devops.python`](https://galaxy.ansible.com/ui/standalone/roles/libre_devops/python/documentation/) | Python on the VM, so the next role can gather facts on any image. |
| [`libre_devops.mde_linux`](https://galaxy.ansible.com/ui/standalone/roles/libre_devops/mde_linux/documentation/) | Defender for Endpoint: repository, package, onboarding and health checks. |

### Running it

**Deploy** with the `MDE Linux VM - deploy` workflow (`just deploy dev`, or `just deploy dev key` for the
vaulted key): pick the workspace and the sign-in, and tick
`destroy_after` for an end-to-end test that tears everything down at the end. **Destroy** with
`MDE Linux VM - destroy` (type the workspace name to confirm).

The pipelines use the org's existing `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID`
variables and `TFSTATE_*` secrets. Onboarding is optional:

| Name | Kind | Purpose |
|---|---|---|
| `MDE_ONBOARDING_JSON` | Secret | The content of `mdatp_onboard.json` from the Defender portal (Settings > Endpoints > Onboarding > Linux Server > "Your preferred Linux configuration management tool"). The workflow writes it to a `0600` temporary file, passes its path as the stack's `mde_onboarding_file`, and deletes it afterwards. Without it, the agent installs but is not onboarded. |
| `MDE_EXPECTED_ORG_ID` | Variable | Optional: the organisation ID the role checks the device onboarded to (the stack's `mde_expected_org_id`). |

To configure from your own machine, `az login` and apply the stack with `-var=configure=true` (your
identity needs the rights in "Requirements" below). If that apply fails partway, `just close` deletes
the bastion it left; the next apply would close it too, but the bastion bills by the hour until then.

### Requirements on the runner

Linux, the Azure CLI (the session adds its `bastion` and `ssh` extensions), `ansible-core`, bash,
`jq`, `python3`, OpenSSH, and for `ssh_auth = "key"` PowerShell 7 with LibreDevOpsHelpers (installed
from PSGallery if missing). GitHub's `ubuntu-latest` image has everything but Ansible, which the
workflow installs with pipx.

The identity running Terraform needs, on top of building the stack, to create and delete the
bastion, its public IP and (for `entra`) role assignments on the VM: the CI service principal has
these already.

## Developing

`just validate` runs what CI runs: `terraform fmt`, `validate` and `tflint` for every stack and a
`trivy config` scan. New builds go in their own `stacks/<name>` with their own workflows: a
bastion-session module call, terraform-ansible-role calls for the roles (each with
`count = var.configure ? 1 : 0` and listed in the session's `close_after`), and an always() close
step after the apply.

## Security scan exceptions

Waivers live in [`.trivyignore.yaml`](./.trivyignore.yaml), mirrored here so the reason is auditable.

| Trivy ID | Resource | Finding | Justification |
|----------|----------|---------|---------------|
| DS-0002 | `**/.terraform/modules/*/tests/e2e/image/Containerfile` | Container image runs as root | Not this repo's code: `terraform init` downloads [terraform-ansible-role](https://github.com/libre-devops/terraform-ansible-role) into the stacks' `.terraform/modules`, and with it its end-to-end test fixture, whose SSH hosts run systemd as PID 1 (which must be root). That repo waives the same finding for the same file. |
