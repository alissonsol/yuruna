# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 4251bbbb-61ad-4694-af71-66eb362b3d81
resource "aws_ecr_repository" "ecr" {
  name                     = var.uniqueName
  image_tag_mutability     = "MUTABLE"
  tags                     = { resourceTags = var.resourceTags }

  image_scanning_configuration {
    scan_on_push = true
  }
}

output "registryLocation" {
  value = aws_ecr_repository.ecr.repository_url
  description = "Repository URL"
}
