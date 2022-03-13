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
