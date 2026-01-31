############################################
# RESOURCE GROUP
############################################
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

############################################
# RANDOM SUFFIX (ARM uniqueString equivalent)
############################################
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  suffix = random_string.suffix.result
}

############################################
# NETWORKING
############################################
resource "azurerm_virtual_network" "vnet" {
  name                = var.vnet_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "app_subnet" {
  name                 = "AppSubnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "db_subnet" {
  name                 = "DbSubnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/24"]

  delegation {
    name = "postgres-delegation"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "apim_subnet" {
  name                 = "ApimSubnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.3.0/24"]
}

############################################
# NSG FOR APIM
############################################
resource "azurerm_network_security_group" "apim_nsg" {
  name                = "apim-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "AllowApimManagement"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3443"
    source_address_prefix      = "ApiManagement"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "AllowHttps"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "Internet"
    destination_address_prefix = "VirtualNetwork"
  }
}

resource "azurerm_subnet_network_security_group_association" "apim_nsg_assoc" {
  subnet_id                 = azurerm_subnet.apim_subnet.id
  network_security_group_id = azurerm_network_security_group.apim_nsg.id
}

############################################
# NAT GATEWAY
############################################
resource "azurerm_public_ip" "nat_pip" {
  name                = "nat-ip-${local.suffix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_nat_gateway" "nat_gw" {
  name                = "nat-${local.suffix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku_name            = "Standard"
}

resource "azurerm_nat_gateway_public_ip_association" "nat_assoc" {
  nat_gateway_id       = azurerm_nat_gateway.nat_gw.id
  public_ip_address_id = azurerm_public_ip.nat_pip.id
}

resource "azurerm_subnet_nat_gateway_association" "app_nat_assoc" {
  subnet_id      = azurerm_subnet.app_subnet.id
  nat_gateway_id = azurerm_nat_gateway.nat_gw.id
}

############################################
# PRIVATE DNS + POSTGRES
############################################
resource "azurerm_private_dns_zone" "postgres_dns" {
  name                = "${local.suffix}.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "dns_link" {
  name                  = "dns-link"
  private_dns_zone_name = azurerm_private_dns_zone.postgres_dns.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  resource_group_name   = azurerm_resource_group.rg.name
}

resource "azurerm_postgresql_flexible_server" "db" {
  name                   = "db-${local.suffix}"
  resource_group_name    = azurerm_resource_group.rg.name
  location               = azurerm_resource_group.rg.location
  version                = "14"
  delegated_subnet_id    = azurerm_subnet.db_subnet.id
  private_dns_zone_id    = azurerm_private_dns_zone.postgres_dns.id
  administrator_login    = "petadmin"
  administrator_password = var.admin_password
  sku_name               = "B_Standard_B1ms"
  storage_mb             = 32768
  public_network_access_enabled = false

  depends_on = [azurerm_private_dns_zone_virtual_network_link.dns_link]
}

resource "azurerm_postgresql_flexible_server_database" "petclinic" {
  name      = "petclinic"
  server_id = azurerm_postgresql_flexible_server.db.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

############################################
# INTERNAL LOAD BALANCER
############################################
resource "azurerm_lb" "lb" {
  name                = "lb-${local.suffix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                          = "frontend"
    subnet_id                     = azurerm_subnet.app_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.1.100"
  }
}

resource "azurerm_lb_backend_address_pool" "pool" {
  name            = "backend-pool"
  loadbalancer_id = azurerm_lb.lb.id
}

resource "azurerm_lb_probe" "probe" {
  name                = "tcp-probe"
  loadbalancer_id     = azurerm_lb.lb.id
  protocol            = "Tcp"
  port                = 9966
  interval_in_seconds = 5
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "rule" {
  name                           = "http-rule"
  loadbalancer_id                = azurerm_lb.lb.id
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 9966
  frontend_ip_configuration_name = "frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.pool.id]
  probe_id                       = azurerm_lb_probe.probe.id
}

############################################
# VM SCALE SET
############################################
resource "azurerm_linux_virtual_machine_scale_set" "vmss" {
  name                = "vmss-${local.suffix}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Standard_D2s_v3"
  instances           = 1
  admin_username      = "azureuser"
  admin_password      = var.admin_password
  disable_password_authentication = false

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  os_disk {
    storage_account_type = "Premium_LRS"
    caching              = "ReadWrite"
  }

  network_interface {
    name    = "nic"
    primary = true

    ip_configuration {
      name      = "ipconfig"
      primary   = true
      subnet_id = azurerm_subnet.app_subnet.id
      load_balancer_backend_address_pool_ids = [
        azurerm_lb_backend_address_pool.pool.id
      ]
    }
  }

  depends_on = [
    azurerm_postgresql_flexible_server_database.petclinic,
    azurerm_lb_rule.rule
  ]
}

############################################
# CUSTOM SCRIPT (PETCLINIC)
############################################
resource "azurerm_virtual_machine_scale_set_extension" "petclinic" {
  name                         = "install-petclinic"
  virtual_machine_scale_set_id = azurerm_linux_virtual_machine_scale_set.vmss.id
  publisher                    = "Microsoft.Azure.Extensions"
  type                         = "CustomScript"
  type_handler_version         = "2.1"

  settings = jsonencode({
    commandToExecute = "apt-get update && apt-get install -y docker.io && docker run -d --restart always -p 9966:9966 -e SPRING_PROFILES_ACTIVE=postgres,spring-data-jpa -e SPRING_DATASOURCE_URL=jdbc:postgresql://${azurerm_postgresql_flexible_server.db.name}.postgres.database.azure.com:5432/petclinic -e SPRING_DATASOURCE_USERNAME=petadmin -e SPRING_DATASOURCE_PASSWORD=${var.admin_password} springcommunity/spring-petclinic-rest"
  })
}

############################################
# API MANAGEMENT
############################################
resource "azurerm_api_management" "apim" {
  name                = "apim-${local.suffix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  publisher_name      = "PetClinic"
  publisher_email     = "admin@contoso.com"
  sku_name            = "Developer_1"
  virtual_network_type = "External"

  virtual_network_configuration {
    subnet_id = azurerm_subnet.apim_subnet.id
  }

  depends_on = [
    azurerm_subnet_network_security_group_association.apim_nsg_assoc
  ]
}

resource "azurerm_api_management_api" "petclinic_api" {
  name                = "petclinic-rest"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  revision            = "1"
  display_name        = "Spring PetClinic REST"
  path                = ""
  protocols           = ["https"]
  service_url         = "http://10.0.1.100/petclinic/api"

  import {
    content_format = "openapi-link"
    content_value  = "https://raw.githubusercontent.com/spring-petclinic/spring-petclinic-rest/master/src/main/resources/openapi.yml"
  }
}
