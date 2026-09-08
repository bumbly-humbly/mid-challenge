terraform {
  required_version = ">= 1.5"

  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.40" }
    tls    = { source = "hashicorp/tls", version = "~> 4.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
    local  = { source = "hashicorp/local", version = "~> 2.5" }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Every node runs the Traefik ingress via k3s' built-in ServiceLB, so the app
  # answers on all three public IPs. The cert covers all of them; the server IP
  # is the canonical URL we hand out.
  node_public_ips = concat([aws_eip.server.public_ip], aws_eip.agent[*].public_ip)

  # nip.io resolves <ip>.nip.io -> <ip>. A free hostname, so the self-signed
  # cert can carry a real DNS SAN without buying a domain.
  cert_dns_names = [for ip in local.node_public_ips : "${ip}.nip.io"]
  ingress_host   = "${aws_eip.server.public_ip}.nip.io"
}
