variable "resourceGroup" {
  description = "Resource group"
}

variable "resourceRegion" {
  description = "Resource region"
}

variable "resourceTags" {
  description = "Resource tags (dev, test, prod, etc.)"
}

variable "nodeType" {
  description = "VM node type (machine size)"
}

variable "machineName" {
  description = "Machine name"
}

variable "imagePublisher" {
  description = "VM image publisher"
}

variable "imageOffer" {
  description = "VM image offer"
}

variable "imageSku" {
  description = "VM image SKU"
}

variable "imageVersion" {
  description = "VM image version"
}

variable "adminUsername" {
  description = "Administrator login account"
}

variable "sshPubFile" {
  description = "ssh key par public file path"
}
