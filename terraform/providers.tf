terraform {
  required_version = ">= 1.6.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id                = var.subscription_id
  resource_providers_to_register = ["Microsoft.App", "Microsoft.ContainerRegistry"]
}

provider "azapi" {
  subscription_id = var.subscription_id
}
