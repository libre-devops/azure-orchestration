output "access_enabled" {
  description = "Whether the access window (bastion, its public IP and the runner's sign-in role) is open."
  value       = var.access_enabled
}

output "bastion_name" {
  description = "The bastion's name while the access window is open, otherwise null."
  value       = var.access_enabled ? local.bas_name : null
}

output "key_vault_name" {
  description = "The key vault holding the admin account's SSH key pair."
  value       = local.kv_name
}

output "resource_group_name" {
  description = "The resource group holding the stack, which the bastion-ansible script targets."
  value       = local.rg_name
}

output "virtual_machine_ids" {
  description = "Map of VM name to VM resource id."
  value       = module.linux_vm.ids
}
