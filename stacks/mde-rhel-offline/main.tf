# Microsoft Defender for Endpoint on a RHEL 9 VM with no route to the internet, installed and
# tested from Terraform in one apply. Nothing reaches the VM except SSH from the bastion subnet, and
# the VM reaches nothing: no public IP, no NAT gateway, and the network module's subnets have no
# default outbound access. With configure = true:
#
#   1. download  libre_devops.rpm_repo_download, on the machine running Terraform (which has the
#                internet), fetches the mdatp RPM from packages.microsoft.com, checking the
#                repository's signature and every checksum on the way
#   2. open      the bastion-session module creates an Azure Bastion for the apply and fetches the
#                admin account's vaulted SSH key (Entra ID sign-in would need the VM to reach Entra)
#   3. install   libre_devops.standalone_package_installer pushes the RPM through the bastion and
#                installs it from the file alone, its signature checked against Microsoft's keys,
#                then libre_devops.mde_linux starts the agent with real-time protection on,
#                without Microsoft's repository
#   4. test      libre_devops.mde_linux_checks tests the release the way an offline host can
#                (protection, the EICAR test, stability, a reboot, the system) and
#                libre_devops.test_results_report writes the report on the machine running
#                Terraform, failing the apply if the release fails
#   5. close     the bastion is deleted once the install and the tests have finished
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
  vm_name      = "vm-mdo-${local.suffix}"
  kv_name      = "kv-mdo-${local.suffix}"
  ssh_key_name = "ssh-mdo-${local.suffix}"
  subnet_vm    = "snet-vm-${local.vnet_name}"

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
# (which is also what lets the bastion session fetch the key). Access policies, so the deployer can
# write the key the moment the vault exists; purge protection off so a destroy frees the name.
module "keyvault" {
  source  = "libre-devops/keyvault/azurerm"
  version = "~> 4.0"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  key_vaults = {
    (local.kv_name) = {
      rbac_authorization_enabled = false
      purge_protection_enabled   = false
      soft_delete_retention_days = 7
      network_acls = {
        default_action = "Deny"
        bypass         = "AzureServices"
        ip_rules       = var.key_vault_ip_rules
      }
      access_policies = [
        {
          object_id          = data.azurerm_client_config.current.object_id
          secret_permissions = ["Get", "List", "Set", "Delete", "Recover", "Purge"]
        }
      ]
    }
  }
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
}

# The RHEL 9 VM. Its Red Hat repositories (RHUI) are out of reach too, so everything it gets comes
# through the bastion.
module "linux_vm" {
  source  = "libre-devops/linux-vm/azurerm"
  version = "~> 4.1"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  linux_virtual_machines = {
    (local.vm_name) = {
      size                = var.vm_size
      admin_username      = "azureuser"
      source_image_simple = "RHEL9"
      subnet_id           = module.network.subnet_ids[local.subnet_vm]
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
    rpm_repo_download_repositories = [{ path = "rhel/9/prod", label = "rhel9" }]
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
    (local.vm_name) = {
      id                = module.linux_vm.ids[local.vm_name]
      groups            = ["rhel9"]
      user              = "azureuser"
      ssh_key_secret_id = module.ssh_key.private_key_secret_versionless_ids[local.ssh_key_name]
      triggers          = { vm_id = module.linux_vm.ids[local.vm_name] }
    }
  }

  close_after = [module.mde[*].run_ids]
}

# 3 and 4. The install and the tests, through the session: the RPM from the file alone (no
# repositories, so no dependency can come from anywhere else), its signature checked against
# Microsoft's keys, which libre_devops.mde_linux ships; then the agent started with real-time
# protection on and not onboarded; then the checks, offline, and the report, which fails the apply
# if a check that counts failed. The report and the evidence stay in local.test_results_dir.
module "mde" {
  # Pinned to the GitHub tag until the module is published on the Terraform Registry.
  source = "git::https://github.com/libre-devops/terraform-ansible-role.git?ref=4.0.0"
  count  = var.configure ? 1 : 0

  name = "mde-rhel-offline"
  roles = [
    { name = "libre_devops.standalone_package_installer", version = "1.0.0" },
    { name = "libre_devops.mde_linux", version = "1.1.1" },
    { name = "libre_devops.mde_linux_checks", version = "1.0.1" },
    { name = "libre_devops.test_results_report", version = "1.0.0" },
  ]
  hosts = module.bastion_session.ansible_hosts

  vars = {
    standalone_package_installer_files     = ["${local.packages_dir}/rhel9/mdatp-*.rpm"]
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
    test_results_report_title           = "mdatp ${var.mde_version} on RHEL 9 with no internet"
    test_results_report_host_label      = "rhel9-offline"
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
