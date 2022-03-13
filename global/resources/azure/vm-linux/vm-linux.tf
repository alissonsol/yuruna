resource "azurerm_virtual_network" "vm-vnet" {
  name                = "vm-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = var.resourceRegion
  resource_group_name = var.resourceGroup
}

resource "azurerm_subnet" "vm-subnet" {
  name                 = "internal"
  resource_group_name  = var.resourceGroup
  virtual_network_name = azurerm_virtual_network.vm-vnet.name
  address_prefixes     = ["10.0.2.0/24"]
}

resource "azurerm_network_interface" "vm-nic" {
  name                = "vm-nic"
  location            = var.resourceRegion
  resource_group_name = var.resourceGroup

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.vm-subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "vm-linux" {
  name                = var.machineName
  resource_group_name = var.resourceGroup
  location            = var.resourceRegion
  size                = var.nodeType
  admin_username      = var.adminUsername
  network_interface_ids = [
    azurerm_network_interface.vm-nic.id,
  ]

  admin_ssh_key {
    username = var.adminUsername
    public_key = file(var.sshPubFile)
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = var.imagePublisher
    offer     = var.imageOffer
    sku       = var.imageSku
    version   = var.imageVersion
  }
}