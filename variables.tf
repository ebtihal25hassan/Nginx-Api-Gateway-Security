variable "region" {
  default = "us-east-1"
}

variable "student_id" {
  type = string
}

variable "internal_token" {
  type      = string
  sensitive = true
}

variable "my_ip_cidr" {
  type        = string
  description = "197.38.203.243/32"
}