# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 424c0796-77b5-4b1f-a291-157095512c07
variable "adminUsername"{
  description = "Administrator login account"
}

variable "adminPassword"{
  description = "Administrator login password"
}

variable "dbVersion" {
  description = "DB version"
}

variable "uniqueName" {
  description = "DB unique name for FQDN"
}

variable "resourceGroup" {
  description = "Resource group"
}

variable "resourceRegion" {
  description = "Resource region"
}

variable "resourceTags" {
  description = "Resource tags (dev, test, prod, etc.)"
}
