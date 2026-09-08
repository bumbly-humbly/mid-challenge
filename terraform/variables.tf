variable "project" {
  description = "Name prefix for every resource."
  type        = string
  default     = "cgi-k3s"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-central-1"
}

variable "admin_cidr" {
  description = "Your public IP as a /32. Gates SSH (22) and the Kubernetes API (6443). Find it with: curl -s https://checkip.amazonaws.com"
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && var.admin_cidr != "0.0.0.0/0"
    error_message = "admin_cidr must be a valid CIDR and must not be 0.0.0.0/0."
  }
}

variable "instance_type" {
  description = "Instance type for all three nodes."
  type        = string
  default     = "t3.small"
}

variable "agent_count" {
  description = "Number of k3s agents. 2 gives 3 Ready nodes, comfortably above the 'at least two' the brief asks for."
  type        = number
  default     = 2
}

variable "root_volume_gb" {
  description = "Root volume size per node. 8 GB is the Ubuntu AMI minimum and plenty for k3s."
  type        = number
  default     = 8
}

variable "k3s_channel" {
  description = "k3s release channel. A channel rather than a pinned patch: reproducible to a minor version and guaranteed to resolve."
  type        = string
  default     = "v1.31"
}

variable "vpc_cidr" {
  description = "VPC CIDR. Must not overlap k3s' defaults (pods 10.42.0.0/16, services 10.43.0.0/16)."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "Public subnet CIDR."
  type        = string
  default     = "10.0.1.0/24"
}

variable "github_repo" {
  description = "owner/repo that may assume the deploy role via OIDC. Leave empty to skip creating CI IAM entirely."
  type        = string
  default     = ""
}

variable "create_github_oidc_provider" {
  description = "Set false if this AWS account already has the GitHub Actions OIDC provider."
  type        = bool
  default     = true
}
