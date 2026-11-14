# Forwarded into the tags module for the DeployedBranch / DeployedRepo tags. The terraform-azure
# action fills these in CI via TF_VAR_deployed_branch / TF_VAR_deployed_repo; empty when run locally.
variable "deployed_branch" {
  description = "Git branch the deployment came from. Auto-filled in CI from TF_VAR_deployed_branch."
  type        = string
  default     = ""
}

variable "deployed_repo" {
  description = "Repository URL the deployment came from. Auto-filled in CI from TF_VAR_deployed_repo."
  type        = string
  default     = ""
}

variable "loc" {
  description = "Outfix: short Azure region code used in resource names (for example uks)."
  type        = string
  default     = "uks"
}

variable "regions" {
  description = "Map of short region codes to Azure region slugs."
  type        = map(string)
  default = {
    uks = "uksouth"
    ukw = "ukwest"
    eus = "eastus"
    euw = "westeurope"
  }
}

variable "short" {
  description = "Infix: short product code used in resource names."
  type        = string
  default     = "ldo"
}

variable "configure" {
  description = <<DESC
Configure the VM in this apply. When true, the bastion-session module creates a Standard Azure
Bastion with native client tunnelling (and, for ssh_auth = "entra", grants the identity running
Terraform the Virtual Machine Administrator Login role on the VM), libre_devops.python and then
libre_devops.mde_linux run through it, and the bastion and the role are removed once they finish:
one apply, nothing billable left behind. false (the default) is an ordinary infrastructure apply.
DESC

  type    = bool
  default = false
}

variable "mde_expected_org_id" {
  description = "Optional: the Defender for Endpoint organisation ID the role checks the device onboarded to. The deploy workflow passes the MDE_EXPECTED_ORG_ID variable."
  type        = string
  default     = ""
}

variable "mde_onboarding_file" {
  description = "Optional: path, on the machine running Terraform, to mdatp_onboard.json from the Defender portal. Empty installs the agent without onboarding. The deploy workflow writes the MDE_ONBOARDING_JSON secret to a 0600 temporary file and passes its path."
  type        = string
  default     = ""
}

variable "ssh_auth" {
  description = <<DESC
How Ansible signs in to the VM through the bastion: entra (a short-lived Entra ID OpenSSH
certificate for the identity running Terraform, with the sign-in role granted for the session) or
key (the admin account's SSH key, fetched from the key vault for the session).
DESC

  type    = string
  default = "entra"

  validation {
    condition     = contains(["entra", "key"], var.ssh_auth)
    error_message = "ssh_auth must be entra or key."
  }
}

variable "vm_size" {
  description = "Size of the Ubuntu VM. Defender for Endpoint needs at least 1 core and 1 GB of RAM."
  type        = string
  default     = "Standard_D2lds_v6"
}

variable "key_vault_ip_rules" {
  description = <<DESC
IPs or CIDRs Terraform keeps open on the key vault's firewall for the length of the run. The pipelines
pass the runner's egress IP on EVERY Terraform step: on a first run that lets the vault and the SSH
key be created in one apply (the terraform-azure action's key vault dance has nothing to open until
the vault exists), and on every run it stops Terraform revoking its own access mid-apply (an apply
that removed the dance's rule would have the later secret updates in the same apply refused). The
dance removes the rule after each step, so the vault is closed between runs. Empty (the default) for
anything else.
DESC

  type    = list(string)
  default = []
}
