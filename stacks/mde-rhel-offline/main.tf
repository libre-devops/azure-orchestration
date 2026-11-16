# Microsoft Defender for Endpoint on RHEL VMs with no route to the internet, one VM for each release
# in rhel_releases (7, 8 and 9 by default), installed and tested from Terraform in one apply. Nothing
# reaches the VMs except SSH from the bastion subnet, and they reach nothing: no public IP, no NAT
# gateway, and the network module's subnets have no default outbound access. With configure = true:
#
#   1. download  libre_devops.rpm_repo_download, on the machine running Terraform (which has the
#                internet), fetches each release's mdatp RPM from packages.microsoft.com, checking
#                the repository's signature and every checksum on the way
#   2. open      the bastion-session module creates an Azure Bastion for the apply and fetches the
#                admin account's vaulted SSH key (Entra ID sign-in would need the VM to reach Entra)
#   3. python    libre_devops.python pushes a python-build-standalone build to RHEL 7 and 8, whose
#                own Pythons (2.7 and 3.6) current ansible-core cannot use; RHEL 9's 3.9 is kept
#   4. install   libre_devops.standalone_package_installer pushes the RPM through the bastion and
#                installs it from the file alone, its signature checked against Microsoft's keys,
#                then libre_devops.mde_linux starts the agent with real-time protection on,
#                without Microsoft's repository
#   5. test      libre_devops.mde_linux_checks tests the release the way an offline host can
#                (protection, the EICAR test, stability, a reboot, the system) and
#                libre_devops.test_results_report writes the report on the machine running
#                Terraform, one report for every release, failing the apply if the release fails
#   6. close     the bastion is deleted once the install and the tests have finished
#
# Onboarding needs the Defender cloud, so the agent is installed and started but not onboarded: the
# stack proves a release installs, protects and survives a reboot on a machine that cannot reach
# anything. The checks that need the cloud are in the report as skipped, with the reason.
locals {
  location = lookup(var.regions, var.loc, "uksouth")
  suffix   = "${var.short}-${var.loc}-${terraform.workspace}-001"

  # mdo: MDE offline. Short, because key vault names stop at 24 characters.
  rg_name      = "rg-mdo-${local.suffix}"
  vnet_name    = "vnet-mdo-${local.suffix}"
  nsg_name     = "nsg-mdo-${local.suffix}"
  bas_name     = "bas-mdo-${local.suffix}"
  kv_name      = "kv-mdo-${local.suffix}"
  ssh_key_name = "ssh-mdo-${local.suffix}"
  subnet_vm    = "snet-vm-${local.vnet_name}"

  # One VM per RHEL release. RHEL 7 is not on Azure's Trusted Launch list (8.6 and later are), so
  # its VM boots without secure boot and vTPM; its image, 7.9 from March 2023, is the last.
  releases = {
    for r in var.rhel_releases : r => {
      vm_name = "vm-mdo-rhel${r}-${local.suffix}"
      sku     = { "7" = "7lvm-gen2", "8" = "8-lvm-gen2", "9" = "9-lvm-gen2" }[r]
      trusted = r != "7"
    }
  }

  vm_subnet_prefix      = "10.30.1.0/24"
  bastion_subnet_prefix = "10.30.0.0/26"

  # Where the download puts the RPMs, and the tests their report, on the machine running Terraform:
  # a new directory each plan, so the install only sees this apply's packages and the report only
  # this apply's results.
  run_stamp        = formatdate("YYYYMMDDhhmmss", plantimestamp())
  packages_dir     = "${abspath(path.root)}/.terraform/mde-packages/${local.run_stamp}"
  test_results_dir = "${abspath(path.root)}/.terraform/test-results/${local.run_stamp}"
}

data "azurerm_client_config" "current" {}

module "tags" {
  source  = "libre-devops/tags/azurerm"
  version = "~> 4.0"

  cost_centre     = "1888/67"
  owner           = "platform@example.com"
  deployed_branch = var.deployed_branch
  deployed_repo   = var.deployed_repo
  additional_tags = { Application = "azure-orchestration-mde-rhel-offline" }
}

module "rg" {
  source  = "libre-devops/rg/azurerm"
  version = "~> 4.0"

  resource_groups = [{ name = local.rg_name, location = local.location, tags = module.tags.tags }]
}

# The VM subnet, and the AzureBastionSubnet the bastion session uses. Neither has default outbound
# access, and nothing gives the VM subnet any other way out.
module "network" {
  source  = "libre-devops/network/azurerm"
  version = "~> 4.0"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  vnet_name     = local.vnet_name
  address_space = ["10.30.0.0/16"]
  subnets = {
    (local.subnet_vm)    = { address_prefixes = [local.vm_subnet_prefix] }
    "AzureBastionSubnet" = { address_prefixes = [local.bastion_subnet_prefix] }
  }
}

# The VM subnet admits SSH from the bastion subnet only, on top of the module's explicit inbound deny.
module "nsg" {
  source  = "libre-devops/nsg/azurerm"
  version = "~> 4.0"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  name = local.nsg_name

  security_rules = {
    AllowBastionSshInbound = {
      priority                   = 200
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      description                = "SSH from the bastion subnet only (the bastion session's tunnels)."
      source_port_range          = "*"
      destination_port_range     = "22"
      source_address_prefix      = local.bastion_subnet_prefix
      destination_address_prefix = local.vm_subnet_prefix
    }
  }

  subnet_associations = {
    (local.subnet_vm) = module.network.subnet_ids[local.subnet_vm]
  }
}

# The vault for the admin account's SSH private key, as in the mde-linux stack: deny by default,
# with the machine running Terraform let in through key_vault_ip_rules for the length of the run
# (which is also what lets the bastion session fetch the key). Azure RBAC, granted below; purge
# protection off so a destroy frees the name.
module "keyvault" {
  source  = "libre-devops/keyvault/azurerm"
  version = "~> 4.0"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  key_vaults = {
    (local.kv_name) = {
      purge_protection_enabled   = false
      soft_delete_retention_days = 7
      network_acls = {
        default_action = "Deny"
        bypass         = "AzureServices"
        ip_rules       = var.key_vault_ip_rules
      }
    }
  }
}

# Azure RBAC on the vault (the keyvault module's default), not access policies: the identity running
# Terraform gets Key Vault Secrets Officer on this vault alone, to write the key (ssh-key module) and
# read it back for the bastion session. That identity therefore needs rights to create role
# assignments (Owner, User Access Administrator or Role Based Access Control Administrator).
module "keyvault_rbac" {
  source  = "libre-devops/role-assignment/azurerm"
  version = "~> 4.1"

  role_assignments = {
    deployer = {
      scope         = module.keyvault.ids[local.kv_name]
      principal_ids = [data.azurerm_client_config.current.object_id]
      role_names    = ["Key Vault Secrets Officer"]
      description   = "Terraform writes and reads the admin SSH key"
    }

    # Anyone who only needs to read the key, such as an operator or another pipeline: Key Vault
    # Secrets User reads secrets and nothing else.
    # readers = {
    #   scope         = module.keyvault.ids[local.kv_name]
    #   principal_ids = ["00000000-0000-0000-0000-000000000000"]
    #   role_names    = ["Key Vault Secrets User"]
    # }
  }
}

# A new role assignment takes a while to reach Key Vault's data plane, and the ssh-key module writes
# the key in this same apply, so it waits for the grant: without the wait a first apply can fail with
# 403 Forbidden on the write. Only the first apply waits.
resource "time_sleep" "keyvault_rbac" {
  create_duration = "180s"
  depends_on      = [module.keyvault_rbac]
}

# The admin account's key pair: generated ephemerally, both halves written to the vault write-only,
# the public half feeding the VM. Ansible signs in with it, because Entra ID sign-in needs the VM to
# reach Entra ID.
module "ssh_key" {
  source  = "libre-devops/ssh-key/azurerm"
  version = "~> 4.0"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  key_vault_id = module.keyvault.ids[local.kv_name]

  ssh_keys = {
    (local.ssh_key_name) = {}
  }

  # The deployer's Key Vault Secrets Officer must have applied before the key is written.
  depends_on = [time_sleep.keyvault_rbac]
}

# The RHEL VMs. Their Red Hat repositories (RHUI) are out of reach too, so everything they get
# comes through the bastion.
module "linux_vm" {
  source  = "libre-devops/linux-vm/azurerm"
  version = "~> 4.1"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  linux_virtual_machines = {
    for r, rel in local.releases : rel.vm_name => {
      size                   = var.vm_size
      admin_username         = "azureuser"
      source_image_reference = { publisher = "RedHat", offer = "RHEL", sku = rel.sku }
      secure_boot_enabled    = rel.trusted
      vtpm_enabled           = rel.trusted
      subnet_id              = module.network.subnet_ids[local.subnet_vm]
      admin_ssh_keys = [{
        public_key = module.ssh_key.public_keys_openssh[local.ssh_key_name]
      }]
    }
  }

  # The NSG must be on the subnet before the VM's first boot.
  depends_on = [module.nsg]
}

# --- Configuration: only in an apply with configure = true -----------------------------------------

# 1. The download, on the machine running Terraform. count, because terraform-ansible-role needs at
# least one host and the run is only wanted when configuring.
module "download" {
  # Pinned to the GitHub tag until the module is published on the Terraform Registry.
  source = "git::https://github.com/libre-devops/terraform-ansible-role.git?ref=4.0.0"
  count  = var.configure ? 1 : 0

  name  = "mde-download"
  roles = [{ name = "libre_devops.rpm_repo_download", version = "1.0.0" }]
  hosts = {
    localhost = { connection = "local", python_interpreter = "{{ ansible_playbook_python }}" }
  }

  vars = {
    rpm_repo_download_repositories = [for r in var.rhel_releases : { path = "rhel/${r}/prod", label = "rhel${r}" }]
    rpm_repo_download_packages     = ["mdatp"]
    rpm_repo_download_version      = var.mde_version
    rpm_repo_download_dest         = local.packages_dir
  }

  become             = false
  wait_for_ssh       = false
  run_on_every_apply = true
}

# 2. The bastion session: a Standard bastion for the length of the apply, and the vaulted key.
module "bastion_session" {
  source  = "libre-devops/bastion-session/azurerm"
  version = "~> 4.0"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  name      = "mde-rhel-offline"
  configure = var.configure
  auth      = "key"

  bastion = {
    name      = local.bas_name
    subnet_id = module.network.subnet_ids["AzureBastionSubnet"]
  }

  targets = {
    for r, rel in local.releases : rel.vm_name => {
      id                = module.linux_vm.ids[rel.vm_name]
      groups            = ["rhel${r}"]
      user              = "azureuser"
      ssh_key_secret_id = module.ssh_key.private_key_secret_versionless_ids[local.ssh_key_name]
      triggers          = { vm_id = module.linux_vm.ids[rel.vm_name] }
    }
  }

  close_after = [module.mde[*].run_ids]
}

# 3, 4 and 5. Python, the install and the tests, through the session, one ansible-playbook per VM
# in parallel: a Python ansible-core can use (pushed to RHEL 7 and 8; facts are gathered once it is
# there); the release's RPM from the file alone (no repositories, so no dependency can come from
# anywhere else), its signature checked against Microsoft's keys, which libre_devops.mde_linux
# ships; then the agent started with real-time protection on and not onboarded; then the checks,
# offline, and the report. Each VM's run adds its results to the one report in
# local.test_results_dir, which fails the apply if a check that counts failed.
module "mde" {
  # Pinned to the GitHub tag until the module is published on the Terraform Registry.
  source = "git::https://github.com/libre-devops/terraform-ansible-role.git?ref=4.0.0"
  count  = var.configure ? 1 : 0

  name = "mde-rhel-offline"
  roles = [
    { name = "libre_devops.python", version = "1.0.0" },
    { name = "libre_devops.standalone_package_installer", version = "1.1.0" },
    { name = "libre_devops.mde_linux", version = "1.2.0" },
    { name = "libre_devops.mde_linux_checks", version = "1.1.0" },
    { name = "libre_devops.test_results_report", version = "1.0.0" },
  ]
  hosts        = module.bastion_session.ansible_hosts
  gather_facts = false

  # Each VM installs its own release's RPM, and is labelled by release in the report.
  host_vars = {
    for r, rel in local.releases : rel.vm_name => {
      standalone_package_installer_files = ["${local.packages_dir}/rhel${r}/mdatp-*.rpm"]
      test_results_report_host_label     = "rhel${r}-offline"
    }
  }

  vars = {
    # The archive comes down to the machine running Terraform, is checked, and is pushed.
    python_bootstrap_source           = "archive"
    python_bootstrap_archive          = var.python_archive.url
    python_bootstrap_archive_checksum = var.python_archive.checksum

    standalone_package_installer_use_repos = false
    standalone_package_installer_gpg_keys = [
      "{{ playbook_dir }}/roles/libre_devops.mde_linux/files/microsoft.asc",
      "{{ playbook_dir }}/roles/libre_devops.mde_linux/files/microsoft-2025.asc",
    ]
    mde_linux_manage_repository = false
    mde_linux_onboard           = false
    # Real-time protection on, so the checks test the protection rather than passive mode, and
    # cloud-delivered protection off, as a host with no route to Microsoft needs: with it on, every
    # lookup waits for the cloud to time out (on this stack's VM the EICAR detection took 40.5 s,
    # and 0.4 s with it off). mde_linux_checks' offline_cloud_protection check enforces it.
    mde_linux_managed_config = {
      antivirusEngine = { enforcementLevel = "real_time" }
      cloudService    = { enabled = false }
    }

    mde_linux_checks_online             = false
    mde_linux_checks_expected_version   = var.mde_version == "latest" ? "" : var.mde_version
    mde_linux_checks_evidence_dir       = "${local.test_results_dir}/evidence"
    test_results_report_dir             = local.test_results_dir
    test_results_report_title           = "mdatp ${var.mde_version} on RHEL ${join(", ", var.rhel_releases)} with no internet"
    test_results_report_expected_checks = ["real_time_protection", "eicar_detection", "service_survives_reboot"]
    test_results_report_properties = {
      stack     = "mde-rhel-offline"
      workspace = terraform.workspace
      repo      = var.deployed_repo
      branch    = var.deployed_branch
      run       = var.run_url
    }
  }

  wait_for_ssh       = false
  run_on_every_apply = true

  depends_on = [module.download]
}
