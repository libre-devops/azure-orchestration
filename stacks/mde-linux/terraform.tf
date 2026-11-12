terraform {
  # 1.11 floor: the ssh-key module generates the key ephemerally and vaults it write-only.
  required_version = ">= 1.11.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.23.0, < 5.0.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.1.0, < 5.0.0"
    }
  }

  backend "azurerm" {}
}
