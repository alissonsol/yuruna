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