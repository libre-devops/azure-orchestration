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

variable "rhel_releases" {
  description = "The RHEL major releases to test, one VM each: any of 7, 8 and 9."
  type        = list(string)
  default     = ["7", "8", "9"]

  validation {
    condition     = length(var.rhel_releases) > 0 && alltrue([for r in var.rhel_releases : contains(["7", "8", "9"], r)])
    error_message = "rhel_releases is a non-empty list of 7, 8 and 9."
  }
}

variable "python_archive" {
  description = <<DESC
The python-build-standalone build libre_devops.python pushes to RHEL 7 and 8, whose own Pythons
(2.7 and 3.6) current ansible-core cannot use: an install_only archive's URL, which the machine
running Terraform downloads, and its SHA-256 from the release's SHA256SUMS. Those builds need glibc
2.17, which RHEL 7 has.
DESC
  type = object({
    url      = string
    checksum = string
  })
  default = {
    url      = "https://github.com/astral-sh/python-build-standalone/releases/download/20261026/cpython-3.12.16%2B20261026-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz"
    checksum = "sha256:ce4f6d0a6cfdb3bed6e44c2f9affd85943c76a42e25ad3a259002f31d6fb8a20"
  }
}

variable "mde_version" {
  description = "The mdatp version to download and install on every release, such as 101.26101.0000, or latest (the default) for the newest in each release's repository."
  type        = string
  default     = "latest"
}

variable "run_url" {
  description = "Optional: a link to the pipeline run, recorded in the test report. The deploy workflow passes its run's URL."
  type        = string
  default     = ""
}

variable "vm_sizes" {
  description = <<DESC
Sizes for particular RHEL releases, overriding vm_size. RHEL 7's image boots from SCSI only, and the
v6 sizes (such as vm_size's Standard_D2lds_v6) have NVMe disk controllers only, so RHEL 7 gets a v5
size, which has SCSI. Azure refuses the mismatch when it creates the VM, not at plan.
DESC
  type        = map(string)
  default     = { "7" = "Standard_D2lds_v5" }
}

variable "vm_size" {
  description = "Size of each RHEL VM unless vm_sizes names one for its release. Defender for Endpoint needs at least 1 core and 1 GB of RAM."
  type        = string
  default     = "Standard_D2lds_v6"
}
