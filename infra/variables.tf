###############################################################################
#  Deployment / identity
###############################################################################

variable "region" {
  description = "AWS region to deploy the lab into."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short project slug. Used for the S3 asset bucket and the SSH key pair name."
  type        = string
  default     = "ddos-lab"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}$", var.project_name))
    error_message = "project_name must be 2-31 characters of lowercase alphanumerics and hyphens."
  }
}

variable "lab_name" {
  description = "Unique name for this lab run. Tags every resource and scopes Prometheus EC2 service discovery."
  type        = string
  default     = "slowloris"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}$", var.lab_name))
    error_message = "lab_name must be 2-31 characters of lowercase alphanumerics and hyphens."
  }
}

variable "admin_cidr" {
  description = "CIDR allowed to SSH in and reach the site / Grafana / Prometheus UIs. Leave empty to auto-detect your current public IP."
  type        = string
  default     = ""

  validation {
    condition     = var.admin_cidr == "" || can(cidrnetmask(var.admin_cidr))
    error_message = "admin_cidr must be empty or a valid IPv4 CIDR such as 203.0.113.7/32."
  }
}

###############################################################################
#  Network
###############################################################################

variable "vpc_cidr" {
  description = "CIDR block for the dedicated lab VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block for the lab public subnet."
  type        = string
  default     = "10.42.1.0/24"
}

variable "availability_zone" {
  description = "Availability zone for the subnet. Empty = first AZ available in the region."
  type        = string
  default     = ""
}

###############################################################################
#  Instances
###############################################################################

variable "instance_type" {
  description = "EC2 instance type used for every lab node. The slowloris demo is connection-bound, not CPU-bound, so t3.micro is plenty."
  type        = string
  default     = "t3.micro"
}

variable "attacker_count" {
  description = "Number of attacker instances (this is what makes the demo 'distributed')."
  type        = number
  default     = 3

  validation {
    condition     = var.attacker_count >= 1 && var.attacker_count <= 10
    error_message = "Keep attacker_count between 1 and 10."
  }
}

variable "deploy_observer" {
  description = "Deploy a dedicated Prometheus + Grafana observer node. Set to false to stay at 4 nodes and run monitoring/docker-compose.yml on your own machine instead."
  type        = bool
  default     = true
}

variable "instance_volume_size_gb" {
  description = "Root EBS volume size (GiB) for each node."
  type        = number
  default     = 8
}

variable "ami_id" {
  description = "Explicit AMI ID to use. Empty = resolve the latest Amazon Linux 2023 x86_64 AMI via SSM."
  type        = string
  default     = ""
}

variable "ami_ssm_parameter" {
  description = "SSM public parameter used to resolve the AMI when ami_id is empty."
  type        = string
  default     = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

###############################################################################
#  SSH access
###############################################################################

variable "key_name" {
  description = "Existing EC2 key pair name to use. Empty = OpenTofu generates a fresh key pair for the lab."
  type        = string
  default     = ""
}

variable "ssh_private_key_path" {
  description = "Only used when key_name is set: local path to the matching private key, used by the helper scripts."
  type        = string
  default     = ""
}

variable "generated_key_dir" {
  description = "Directory (relative to the infra/ module) that the generated private key is written to."
  type        = string
  default     = "../generated"
}

###############################################################################
#  Attack parameters (baked into /etc/lab/attack.env on every attacker node)
###############################################################################

variable "attacker_sockets" {
  description = "Slowloris sockets opened per attacker node."
  type        = number
  default     = 150
}

variable "attacker_interval" {
  description = "Seconds between keep-alive headers per socket. Must stay well below Apache's Timeout (300s)."
  type        = number
  default     = 10
}

variable "attacker_timeout" {
  description = "Socket connect/write timeout (seconds) used by the attack script."
  type        = number
  default     = 4
}

###############################################################################
#  Monitoring stack
###############################################################################

variable "node_exporter_version" {
  description = "prometheus/node_exporter release version (no leading v)."
  type        = string
  default     = "1.12.1"
}

variable "apache_exporter_version" {
  description = "Lusitaniae/apache_exporter release version (no leading v)."
  type        = string
  default     = "1.1.1"
}

variable "blackbox_image" {
  description = "blackbox_exporter container image used by the observer for external HTTP probing."
  type        = string
  default     = "prom/blackbox-exporter:v0.29.0"
}

variable "prometheus_image" {
  description = "Prometheus container image used by the observer."
  type        = string
  default     = "prom/prometheus:v3.15.0"
}

variable "grafana_image" {
  description = "Grafana container image used by the observer."
  type        = string
  default     = "grafana/grafana:13.2.4"
}

variable "grafana_admin_password" {
  description = "Grafana admin password. Change this for anything beyond a throwaway lab."
  type        = string
  default     = "slowloris-demo"
  sensitive   = true

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]{8,64}$", var.grafana_admin_password))
    error_message = "grafana_admin_password must be 8-64 characters of A-Za-z0-9._- (it is embedded into cloud-init)."
  }
}

variable "prometheus_retention" {
  description = "Prometheus TSDB retention. Deliberately short because the observer has small disk."
  type        = string
  default     = "3d"
}

variable "tags" {
  description = "Extra tags merged onto every resource."
  type        = map(string)
  default     = {}
}
