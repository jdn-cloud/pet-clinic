variable "resource_group_name" {
  type    = string
  default = "petclinic-rg"
}

variable "location" {
  type    = string
  default = "westus3"
}

variable "vnet_name" {
  type    = string
  default = "petclinic-vnet"
}

variable "admin_password" {
  type      = string
  sensitive = true
}
