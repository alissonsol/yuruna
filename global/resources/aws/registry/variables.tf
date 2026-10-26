# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 42de985f-633b-4ebb-b74f-61c4916bb1ae
variable "registryName" {
  description = "Container registry name"
}

variable "uniqueName" {
  description = "Unique registry name"
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
