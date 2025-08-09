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

# IAM role for Lambda
resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# IAM policy for Lambda to access S3
resource "aws_iam_role_policy" "lambda_s3_policy" {
  name = "${var.project_name}-lambda-s3-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = [
          "${aws_s3_bucket.thumbnail_bucket.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# Lambda function
resource "aws_lambda_function" "thumbnail_generator" {
  filename         = "../lambda-function/lambda-function.zip"
  function_name    = "${var.project_name}-thumbnail-generator"
  role            = aws_iam_role.lambda_role.arn
  handler         = "lambda_function.lambda_handler"
  runtime         = "python3.13"
  timeout         = 30
  memory_size     = 512

  environment {
    variables = {
      S3_BUCKET = aws_s3_bucket.thumbnail_bucket.bucket
    }
  }

  depends_on = [
    aws_iam_role_policy.lambda_s3_policy,
  ]
}

# Output Lambda function name
output "lambda_function_name" {
  description = "Name of the Lambda function"
  value       = aws_lambda_function.thumbnail_generator.function_name
}

# Output bucket name for use in Lambda
output "bucket_name" {
  description = "Name of the S3 bucket"
  value       = aws_s3_bucket.thumbnail_bucket.bucket
}