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
The VM has no public IP, the runner has no network path to it (no VPN, firewall or private endpoint),
and no SSH key exists anywhere.

### How the runner reaches the VM

Ansible runs on the GitHub-hosted runner and connects through an **access window** that is open only
while it runs:

| Step | What happens |
|---|---|
| 1. Open | `terraform apply -var=access_enabled=true` adds a Standard Azure Bastion with native client tunnelling, its public IP, and the Virtual Machine Administrator Login role for the identity running Terraform (the CI service principal). |
| 2. Configure | [`scripts/bastion-ansible.sh`](./scripts/bastion-ansible.sh) finds the bastion and the VMs tagged `AnsibleGroups`, opens one `az network bastion tunnel` per VM on its own localhost port, gets a short-lived Entra ID OpenSSH certificate for the runner's identity (`az ssh config`), and runs the playbook against `127.0.0.1:<port>`. |
| 3. Close | `terraform apply -var=access_enabled=false` runs **always**, even when step 1 or 2 failed, and removes the bastion, its public IP and the sign-in role. |
| Sweep | An hourly workflow closes any window a hard-cancelled run left open (it only runs Terraform when a bastion is actually there, and never under a run that is using it). |

Everything billable or privileged in the window lives only as long as the run: the bastion and its
public IP (Standard bastions bill by the hour, unlike the free Developer SKU, which cannot tunnel),
the sign-in role, the tunnels (closed when the script exits), and the certificate, keys, inventory and
known_hosts (in a temporary directory deleted when the script exits, pass or fail). What stays is what
the VM needs to do its job: the VM, its NAT gateway (Defender for Endpoint talks to its cloud
continuously, and the network module's subnets have no implicit outbound access), the network and the
free `AzureBastionSubnet`.

Sign-in uses [Entra ID SSH](https://learn.microsoft.com/entra/identity/devices/howto-vm-sign-in-azure-ad-linux)
through the [vm-entra-login](https://github.com/libre-devops/terraform-azurerm-vm-entra-login)
module: the CI service principal signs in with an OpenSSH certificate Entra ID issues on demand, and
the Virtual Machine Administrator Login role gives it the passwordless `sudo` the role's `become`
needs. The VM's admin account only carries a placeholder public key nobody holds.

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
| [`libre_devops.mde_linux`](https://galaxy.ansible.com/ui/standalone/roles/libre_devops/mde_linux/documentation/) | Defender for Endpoint: repository, package, onboarding and health checks. |

### Running it

**Deploy** with the `MDE Linux VM - deploy` workflow (`just deploy dev`): pick the workspace, and tick
`destroy_after` for an end-to-end test that tears everything down at the end instead of closing the
window. **Destroy** with `MDE Linux VM - destroy` (type the workspace name to confirm).

The pipelines use the org's existing `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID`
variables and `TFSTATE_*` secrets. Onboarding is optional:

| Name | Kind | Purpose |
|---|---|---|
| `MDE_ONBOARDING_JSON` | Secret | The content of `mdatp_onboard.json` from the Defender portal (Settings > Endpoints > Onboarding > Linux Server > "Your preferred Linux configuration management tool"). The workflow writes it to a `0600` temporary file for the role and deletes it afterwards. Without it, the agent installs but is not onboarded. |
| `MDE_EXPECTED_ORG_ID` | Variable | Optional: the organisation ID the role checks the device onboarded to. |

To run the Ansible step yourself against a stack whose window is open: `az login`, then
`just configure rg-mde-ldo-uks-dev-001`. Your identity needs the Virtual Machine Administrator Login
role on the resource group (the window grants it to whoever runs Terraform).

### Requirements on the runner

The Azure CLI with the `bastion` and `ssh` extensions (the script adds them), `ansible-core`, and
bash. GitHub's `ubuntu-latest` image has everything but Ansible, which the workflow installs with
pipx.

## Developing

`just validate` runs what CI runs: `terraform fmt`, `validate` and `tflint` for every stack, a
`trivy config` scan, `shellcheck`, and an Ansible syntax check of every playbook. New builds go in
their own `stacks/<name>` with a playbook in `ansible/playbooks` and their own workflows, following the
same open, configure, close shape.

## Security scan exceptions

None. Waivers would live in [`.trivyignore.yaml`](./.trivyignore.yaml) with a matching row here.
