locals {
  windows_pipeline_agent_name  = var.windows_pipeline_agent_name != "" ? "${lower(var.windows_pipeline_agent_name)}-${terraform.workspace}" : local.windows_vm_name
  windows_vm_name              = "${var.windows_vm_name_prefix}${substr(terraform.workspace,0,3)}${local.suffix}w"
}

resource azurerm_public_ip windows_pip {
  name                         = "${local.windows_vm_name}${count.index+1}-pip"
  location                     = data.azurerm_resource_group.pipeline_resource_group.location
  resource_group_name          = data.azurerm_resource_group.pipeline_resource_group.name
  allocation_method            = "Static"
  sku                          = "Standard"

  tags                         = local.tags
  count                        = var.windows_agent_count
}

resource azurerm_network_interface windows_nic {
  name                         = "${local.windows_vm_name}${count.index+1}-nic"
  location                     = data.azurerm_resource_group.pipeline_resource_group.location
  resource_group_name          = data.azurerm_resource_group.pipeline_resource_group.name

  ip_configuration {
    name                       = "ipconfig"
    subnet_id                  = data.azurerm_subnet.pipeline_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id       = azurerm_public_ip.windows_pip[count.index].id
  }
  enable_accelerated_networking = var.vm_accelerated_networking

  tags                         = local.tags
  count                        = var.windows_agent_count
}

resource azurerm_network_interface_security_group_association windows_nic_nsg {
  network_interface_id         = azurerm_network_interface.windows_nic[count.index].id
  network_security_group_id    = azurerm_network_security_group.nsg.id

  count                        = var.windows_agent_count
}

resource azurerm_storage_blob bootstrap_agent {
  name                         = "bootstrap_agent.ps1"
  storage_account_name         = azurerm_storage_account.automation_storage.name
  storage_container_name       = azurerm_storage_container.scripts.name

  type                         = "Block"
  source                       = "../scripts/agent/bootstrap_agent.ps1"

  count                        = var.windows_agent_count > 0 ? 1 : 0
}

resource azurerm_storage_blob install_agent {
  name                         = "install_agent.ps1"
  storage_account_name         = azurerm_storage_account.automation_storage.name
  storage_container_name       = azurerm_storage_container.scripts.name

  type                         = "Block"
  source                       = "../scripts/agent/install_agent.ps1"

  count                        = var.windows_agent_count > 0 ? 1 : 0
}

resource azurerm_windows_virtual_machine windows_agent {
  name                         = "${local.windows_vm_name}${count.index+1}"
  location                     = data.azurerm_resource_group.pipeline_resource_group.location
  resource_group_name          = data.azurerm_resource_group.pipeline_resource_group.name
  network_interface_ids        = [azurerm_network_interface.windows_nic[count.index].id]
  size                         = var.windows_vm_size
  admin_username               = var.user_name
  admin_password               = local.password

  os_disk {
    name                       = "${local.windows_vm_name}${count.index+1}-osdisk"
    caching                    = "ReadWrite"
    storage_account_type       = "Premium_LRS"
  }

  source_image_reference {
    publisher                  = var.windows_os_publisher
    offer                      = var.windows_os_offer
    sku                        = var.windows_os_sku
    version                    = "latest"
  }

  additional_unattend_content {
    setting                    = "AutoLogon"
    content                    = templatefile("../scripts/agent/AutoLogon.xml", { 
      count                    = 1, 
      username                 = var.user_name, 
      password                 = local.password
    })
  }
  additional_unattend_content {
    setting                    = "FirstLogonCommands"
    content                    = templatefile("../scripts/agent/FirstLogonCommands.xml", { 
      scripturl                = azurerm_storage_blob.bootstrap_agent.0.url
    })
  }

  # This is deserialized on the host by bootstrap_agent.ps1
  custom_data                  = base64encode(jsonencode(map(
    "agentname"                , "${local.windows_pipeline_agent_name}${count.index+1}",
    "agentscripturl"           , azurerm_storage_blob.install_agent.0.url,
    "agentpool"                , var.windows_pipeline_agent_pool,
    "organization"             , var.devops_org,
    "pat"                      , var.devops_pat,
    "username"                 , var.user_name
  )))

  # Required for AAD Login
  identity {
    type                       = "SystemAssigned"
  }

  tags                         = local.tags
  count                        = var.windows_agent_count

  depends_on                   = [azurerm_storage_blob.install_agent]
}