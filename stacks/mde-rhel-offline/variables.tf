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

variable "configure" {
  description = <<DESC
Install Defender for Endpoint in this apply. When true, the mdatp RPM is downloaded on the machine
running Terraform, the bastion-session module creates a Standard Azure Bastion with native client
tunnelling and fetches the admin key, the RPM is pushed through it and installed, and the bastion
is deleted once that finishes: one apply, nothing billable left behind. false (the default) is an
ordinary infrastructure apply.
DESC

  type    = bool
  default = false
}

variable "mde_version" {
  description = "The mdatp version to download and install, such as 101.26101.0000, or latest (the default) for the newest in Microsoft's RHEL 9 repository."
  type        = string
  default     = "latest"
}

variable "vm_size" {
  description = "Size of the RHEL 9 VM. Defender for Endpoint needs at least 1 core and 1 GB of RAM."
  type        = string
  default     = "Standard_D2lds_v6"
}
