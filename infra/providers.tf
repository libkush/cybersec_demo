provider "aws" {
  region = var.region

  default_tags {
    tags = local.base_tags
  }
}
