variable "resource_group_name" {
  type    = string
  default = "petclinic-rg"
}

variable "location" {
  type    = string
  default = "westus3"
}

variable "admin_password" {
  type      = string
  sensitive = true
}
