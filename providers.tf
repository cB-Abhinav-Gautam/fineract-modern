provider "aws" {
  region = var.aws_region

  # Every taggable resource inherits the owner/environment tags the
  # tagging-standard policy requires.
  default_tags {
    tags = {
      owner       = var.owner
      environment = var.environment
      service     = var.service_name
      managed_by  = "apex-opentofu"
    }
  }
}
