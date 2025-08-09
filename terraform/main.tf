terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "thumbnail-generator"
}

# S3 bucket for images and thumbnails
resource "aws_s3_bucket" "thumbnail_bucket" {
  bucket = "${var.project_name}-bucket-${random_string.bucket_suffix.result}"
}

resource "random_string" "bucket_suffix" {
  length  = 8
  special = false
  upper   = false
}

# S3 bucket versioning
resource "aws_s3_bucket_versioning" "thumbnail_bucket" {
  bucket = aws_s3_bucket.thumbnail_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Output bucket name for use in Lambda
output "bucket_name" {
  description = "Name of the S3 bucket"
  value       = aws_s3_bucket.thumbnail_bucket.bucket
}