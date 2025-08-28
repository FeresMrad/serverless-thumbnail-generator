# Some values are provided in terraform.tfvars, with defaults defined here.

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

# Lambda Configuration
variable "lambda_timeout" {
  description = "Lambda function timeout in seconds"
  type        = number
  default     = 60
}

variable "lambda_memory_size" {
  description = "Lambda function memory in MB"
  type        = number
  default     = 512
}

variable "lambda_runtime" {
  description = "Lambda runtime version"
  type        = string
  default     = "python3.13"
}

# SQS Configuration
variable "sqs_visibility_timeout" {
  description = "SQS visibility timeout in seconds (should be >= Lambda timeout)"
  type        = number
  default     = 300
}

variable "sqs_message_retention_days" {
  description = "SQS message retention in days"
  type        = number
  default     = 14
}

variable "sqs_max_receive_count" {
  description = "Max receive count before sending to DLQ"
  type        = number
  default     = 3
}

# Monitoring Configuration
variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 14
}

variable "error_rate_threshold" {
  description = "Number of errors to trigger alarm"
  type        = number
  default     = 5
}

variable "lambda_duration_threshold_ms" {
  description = "Lambda duration threshold for alarm in milliseconds"
  type        = number
  default     = 30000
}

# Image Processing Configuration
variable "thumbnail_max_size" {
  description = "Maximum thumbnail dimensions (width, height)"
  type        = object({
    width  = number
    height = number
  })
  default = {
    width  = 200
    height = 200
  }
}

variable "thumbnail_quality" {
  description = "JPEG quality for thumbnails (1-100)"
  type        = number
  default     = 85
}

# Feature Flags
variable "enable_xray_tracing" {
  description = "Enable X-Ray tracing for Lambda"
  type        = bool
  default     = true
}

variable "enable_versioning" {
  description = "Enable S3 bucket versioning"
  type        = bool
  default     = true
}