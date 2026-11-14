output "bastion_name" {
  description = "The name the bastion session's bastion has while an apply with configure = true runs."
  value       = module.bastion_session.bastion_name
}

output "bastion_session_working_directory" {
  description = "The bastion session's working directory: scripts/close.sh <this> closes a session a failed apply left open."
  value       = module.bastion_session.working_directory
}

output "configured" {
  description = "Whether this apply configured the VM through a bastion session (the configure input)."
  value       = var.configure
}

output "key_vault_name" {
  description = "The key vault holding the admin account's SSH key pair."
  value       = local.kv_name
}

output "resource_group_name" {
  description = "The resource group holding the stack."
  value       = local.rg_name
}

output "virtual_machine_ids" {
  description = "Map of VM name to VM resource id."
  value       = module.linux_vm.ids
}
