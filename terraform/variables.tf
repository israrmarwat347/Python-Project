variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region"
}

variable "project" {
  type        = string
  default     = "devops-notes"
  description = "Project name prefix for all resources"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.20.1.0/24"
}

variable "availability_zone" {
  type    = string
  default = "us-east-1a"
}

variable "my_ip_cidr" {
  type        = string
  description = "Your public IP in CIDR form (e.g. 1.2.3.4/32) for SSH access"
}

variable "ssh_public_key" {
  type        = string
  description = "Contents of your SSH public key for EC2 access"
}

variable "jenkins_instance_type" {
  type    = string
  default = "t3.small"
}

variable "k8s_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "ami_id" {
  type        = string
  description = "Ubuntu 22.04 LTS AMI (us-east-1 default)."
  default     = "ami-0e86e20dae9224db8"
}
