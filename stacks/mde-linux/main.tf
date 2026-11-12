# An Ubuntu VM running Microsoft Defender for Endpoint, configured by Ansible through an Azure
# Bastion tunnel that exists only for the length of the run. The VM has no public IP and nothing
# reaches it except SSH from the bastion subnet. Ansible signs in either with Entra ID (short-lived
# OpenSSH certificates for the CI identity) or with the admin account's SSH key, which Terraform
# generates ephemerally and keeps only in a firewalled key vault (never in plan or state).
locals {
  location = lookup(var.regions, var.loc, "uksouth")
  suffix   = "${var.short}-${var.loc}-${terraform.workspace}-001"

  rg_name      = "rg-mde-${local.suffix}"
  vnet_name    = "vnet-mde-${local.suffix}"
  nsg_name     = "nsg-mde-${local.suffix}"
  ng_name      = "ng-mde-${local.suffix}"
  pip_ng_name  = "pip-ng-mde-${local.suffix}"
  bas_name     = "bas-mde-${local.suffix}"
  pip_bas_name = "pip-bas-mde-${local.suffix}"
  vm_name      = "vm-mde-${local.suffix}"
  kv_name      = "kv-mde-${local.suffix}"
  ssh_key_name = "ssh-mde-${local.suffix}"
  subnet_vm    = "snet-vm-${local.vnet_name}"

  vm_subnet_prefix      = "10.20.1.0/24"
  bastion_subnet_prefix = "10.20.0.0/26"
}

data "azurerm_client_config" "current" {}

module "tags" {
  source  = "libre-devops/tags/azurerm"
  version = "~> 4.0"

  cost_centre     = "1888/67"
  owner           = "platform@example.com"
  deployed_branch = var.deployed_branch
  deployed_repo   = var.deployed_repo
  additional_tags = { Application = "azure-orchestration-mde-linux" }
}

module "rg" {
  source  = "libre-devops/rg/azurerm"
  version = "~> 4.0"

  resource_groups = [{ name = local.rg_name, location = local.location, tags = module.tags.tags }]
}

# The VM subnet, and the AzureBastionSubnet the access window's bastion uses (a subnet costs nothing,
# so it stays; only the bastion and its public IP come and go).
module "network" {
  source  = "libre-devops/network/azurerm"
  version = "~> 4.0"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  vnet_name     = local.vnet_name
  address_space = ["10.20.0.0/16"]
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
      description                = "SSH from the bastion subnet only (the access window's tunnel)."
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

# Egress for the VM subnet: Defender for Endpoint, the Entra ID login extension and the package
# repositories all need outbound HTTPS, and the network module's subnets have no implicit outbound
# access. This lives as long as the VM, because the agent talks to the Defender cloud continuously.
module "public_ip_nat" {
  source  = "libre-devops/public-ip/azurerm"
  version = "~> 4.0"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  public_ips = { (local.pip_ng_name) = {} }
}

module "nat_gateway" {
  source  = "libre-devops/nat-gateway/azurerm"
  version = "~> 4.0"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  name = local.ng_name

  public_ip_associations = { (local.pip_ng_name) = module.public_ip_nat.public_ip_ids[local.pip_ng_name] }
  subnet_associations    = { (local.subnet_vm) = module.network.subnet_ids[local.subnet_vm] }
}

# The vault for the admin account's SSH private key. Deny-by-default network ACL with nothing
# allow-listed between runs: every Terraform step goes through the terraform-azure action's key vault
# firewall dance and passes the runner in key_vault_ip_rules (see its description), and the
# bastion-ansible script opens the vault to itself only for the seconds it takes to fetch the key. Access policies rather than RBAC, so the
# deployer can write the key the moment the vault exists (a new role assignment takes minutes to
# apply). Purge protection is off so a destroy frees the globally unique name for the next run.
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
# the public half feeding the VM. Bump value_wo_version in the module call to rotate it.
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

# The Ubuntu VM. Its tags drive the bastion-ansible script: AnsibleGroups builds the inventory, and
# AnsibleUser plus AnsibleSshKeySecret say who to sign in as and where the key lives for --auth key.
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
      source_image_simple = "Ubuntu2404"
      subnet_id           = module.network.subnet_ids[local.subnet_vm]
      admin_ssh_keys = [{
        public_key = module.ssh_key.public_keys_openssh[local.ssh_key_name]
      }]
      tags = {
        AnsibleGroups       = "mde_linux"
        AnsibleUser         = "azureuser"
        AnsibleSshKeySecret = module.ssh_key.private_key_secret_versionless_ids[local.ssh_key_name]
      }
    }
  }

  # The Entra ID login extension installs packages on first boot, so the subnet needs its egress
  # before the VM exists.
  depends_on = [module.nat_gateway]
}

# Entra ID SSH on the VM (no device join on Linux), fed straight from the VM module's ids output.
module "vm_entra_login" {
  # Pinned to the GitHub tag until the module is published on the Terraform Registry; then switch to
  # source = "libre-devops/vm-entra-login/azurerm" with version = "~> 4.0".
  source = "git::https://github.com/libre-devops/terraform-azurerm-vm-entra-login.git?ref=4.0.1"

  tags = module.tags.tags

  linux_virtual_machine_ids = module.linux_vm.ids
}

# --- The access window: billable, so it exists only while access_enabled is true -----------------

module "public_ip_bastion" {
  source  = "libre-devops/public-ip/azurerm"
  version = "~> 4.0"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  public_ips = var.access_enabled ? { (local.pip_bas_name) = {} } : {}
}

# Standard is the lowest SKU with native client tunnelling (az network bastion tunnel); Developer is
# portal-only.
module "bastion" {
  source  = "libre-devops/bastion/azurerm"
  version = "~> 4.0"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  bastion_hosts = var.access_enabled ? {
    (local.bas_name) = {
      sku = "Standard"
      ip_configuration = {
        subnet_id            = module.network.subnet_ids["AzureBastionSubnet"]
        public_ip_address_id = module.public_ip_bastion.public_ip_ids[local.pip_bas_name]
      }
      scale_units       = 2
      tunneling_enabled = true
    }
  } : {}
}

# Entra ID sign-in for whoever runs Terraform (the CI service principal in the pipeline), with sudo,
# for the length of the window. Owner or Contributor alone does not grant sign-in.
module "role_assignment" {
  source  = "libre-devops/role-assignment/azurerm"
  version = "~> 4.0"

  role_assignments = var.access_enabled ? {
    runner_vm_admin_login = {
      scope         = module.rg.ids[local.rg_name]
      principal_ids = [data.azurerm_client_config.current.object_id]
      role_names    = [module.vm_entra_login.login_role_names.administrator]
    }
  } : {}
}
