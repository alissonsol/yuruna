# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 42bf5be0-81d6-4a8c-9140-a6bf2923397a
variable "storageAccountName" {
  description = "Storage account name"
}

variable "storageShareName" {
  description = "Storage share name"
}

variable "storageQuota" {
  description = "Storage quota"
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
