mock_provider "azurerm" {
  mock_data "azurerm_resource_group" {
    defaults = {
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg"
      name     = "test-rg"
      location = "northeurope"
    }
  }
}

mock_provider "azapi" {}

variables {
  subscription_id        = "00000000-0000-0000-0000-000000000000"
  resource_group_name    = "test-rg"
  location               = "northeurope"
  alert_email            = "operator@example.com"
  vm_admin_password      = "<offline-test-placeholder>"
  enable_stage_a         = true
  enable_stage_b         = false
  enable_stage_c         = false
  enable_stage_d         = false
  enable_stage_e         = false
  enable_stage_ai        = false
  enable_stage_sre_agent = false
}

run "foundation_without_console" {
  command = plan

  assert {
    condition     = length(terraform_data.console_ready) == 0
    error_message = "Stage A alone must not publish or provision the Web App console."
  }
}

run "workloads_include_console" {
  command = plan

  variables {
    enable_stage_b = true
  }

  assert {
    condition     = length(terraform_data.console_ready) == 1
    error_message = "Stage B must include the automatic console completion hook."
  }

  assert {
    condition     = terraform_data.console_ready[0].triggers_replace.resource_group == data.azurerm_resource_group.lab.id
    error_message = "Console completion must target the selected lab resource group."
  }

  assert {
    condition     = !jsondecode(terraform_data.console_ready[0].triggers_replace.integrations).stage_e
    error_message = "Stage A+B must keep optional Stage E completion disabled."
  }
}

run "stage_e_refreshes_optional_completion" {
  command = plan

  variables {
    enable_stage_b = true
    enable_stage_e = true
  }

  assert {
    condition     = jsondecode(terraform_data.console_ready[0].triggers_replace.integrations).stage_e
    error_message = "Changing Stage E must refresh the selected optional completion work."
  }
}

run "optional_agents_refresh_console" {
  command = plan

  variables {
    enable_stage_b         = true
    enable_stage_ai        = true
    enable_stage_sre_agent = true
  }

  assert {
    condition     = jsondecode(terraform_data.console_ready[0].triggers_replace.integrations).ai && jsondecode(terraform_data.console_ready[0].triggers_replace.integrations).sre
    error_message = "Changes to both optional agent stages must refresh console setup."
  }
}

run "reject_invalid_operator" {
  command = plan

  variables {
    console_operator_object_ids = ["00000000-0000-0000-0000-000000000000"]
  }

  expect_failures = [var.console_operator_object_ids]
}