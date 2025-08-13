terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.1"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
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

# SQS queue for S3 notifications
resource "aws_sqs_queue" "thumbnail_queue" {
  name                      = "${var.project_name}-thumbnail-queue"
  message_retention_seconds = 1209600 # 14 days
  visibility_timeout_seconds = 300    # 5 minutes (should be >= Lambda timeout)
  
  # Configure redrive policy for DLQ
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.thumbnail_dlq.arn
    maxReceiveCount     = 3
  })
}

# Dead Letter Queue for failed messages
resource "aws_sqs_queue" "thumbnail_dlq" {
  name                      = "${var.project_name}-thumbnail-dlq"
  message_retention_seconds = 1209600 # 14 days
}

# SQS queue policy to allow S3 to send messages
resource "aws_sqs_queue_policy" "thumbnail_queue_policy" {
  queue_url = aws_sqs_queue.thumbnail_queue.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action = "sqs:SendMessage"
        Resource = aws_sqs_queue.thumbnail_queue.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_s3_bucket.thumbnail_bucket.arn
          }
        }
      }
    ]
  })
}

# Build Lambda deployment package with dependencies
resource "null_resource" "lambda_build" {
  triggers = {
    # Rebuild when function code or requirements change
    lambda_code  = filemd5("../lambda-function/lambda_function.py")
    requirements = filemd5("../lambda-function/requirements.txt")
  }

  provisioner "local-exec" {
    command = <<EOF
cd ../lambda-function
echo "Building Lambda deployment package..."

# Create clean deployment directory
rm -rf deployment
mkdir deployment

# Copy Lambda function
cp lambda_function.py deployment/

# Install dependencies using Docker for Linux compatibility
docker run --rm -v "$PWD":/var/task \
  public.ecr.aws/lambda/python:3.13 \
  /bin/bash -c "cd /var/task && pip install -r requirements.txt -t deployment/" 2>/dev/null || \
  python -m pip install -r requirements.txt -t deployment/ --upgrade

echo "Lambda package built successfully"
EOF
  }
}

# Create ZIP file of the complete Lambda package
data "archive_file" "lambda_package" {
  type        = "zip"
  source_dir  = "../lambda-function/deployment"
  output_path = "../lambda-function/lambda-deployment.zip"
  
  depends_on = [null_resource.lambda_build]
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

# IAM policy for Lambda to access SQS
resource "aws_iam_role_policy" "lambda_sqs_policy" {
  name = "${var.project_name}-lambda-sqs-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = [
          aws_sqs_queue.thumbnail_queue.arn,
          aws_sqs_queue.thumbnail_dlq.arn
        ]
      }
    ]
  })
}

# Lambda function
resource "aws_lambda_function" "thumbnail_generator" {
  filename      = data.archive_file.lambda_package.output_path
  function_name = "${var.project_name}-thumbnail-generator"
  role          = aws_iam_role.lambda_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.13"
  timeout       = 30
  memory_size   = 512

  # Detect code changes automatically
  source_code_hash = data.archive_file.lambda_package.output_base64sha256

  environment {
    variables = {
      S3_BUCKET = aws_s3_bucket.thumbnail_bucket.bucket
    }
  }

  depends_on = [
    aws_iam_role_policy.lambda_s3_policy,
    aws_iam_role_policy.lambda_sqs_policy,
    data.archive_file.lambda_package,
  ]
}

# Lambda event source mapping for SQS
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = aws_sqs_queue.thumbnail_queue.arn
  function_name    = aws_lambda_function.thumbnail_generator.arn
  batch_size       = 1
  enabled          = true
}

# S3 bucket notification to send to SQS
resource "aws_s3_bucket_notification" "thumbnail_trigger" {
  bucket = aws_s3_bucket.thumbnail_bucket.id

  queue {
    queue_arn     = aws_sqs_queue.thumbnail_queue.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "images/"
  }

  depends_on = [aws_sqs_queue_policy.thumbnail_queue_policy]
}

# Outputs
output "bucket_name" {
  description = "Name of the S3 bucket"
  value       = aws_s3_bucket.thumbnail_bucket.bucket
}

output "lambda_function_name" {
  description = "Name of the Lambda function"
  value       = aws_lambda_function.thumbnail_generator.function_name
}

output "sqs_queue_url" {
  description = "URL of the SQS queue"
  value       = aws_sqs_queue.thumbnail_queue.url
}

output "sqs_dlq_url" {
  description = "URL of the Dead Letter Queue"
  value       = aws_sqs_queue.thumbnail_dlq.url
}

output "deployment_info" {
  description = "Information about the deployment"
  value = {
    lambda_package_size = data.archive_file.lambda_package.output_size
    source_code_hash    = data.archive_file.lambda_package.output_base64sha256
  }
}