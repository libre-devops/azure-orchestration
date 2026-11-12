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

variable "access_enabled" {
  description = <<DESC
Open the access window: a Standard Azure Bastion with native client tunnelling, its public IP, and
the Virtual Machine Administrator Login role for the identity running Terraform (the CI service
principal in the pipeline). The deploy workflow applies with this true just long enough for Ansible
to run through the bastion, then always applies again with it false, so the billable bastion and the
sign-in grant exist only while they are in use. false (the default) is the steady state.
DESC

  type    = bool
  default = false
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
