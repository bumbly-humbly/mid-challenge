# Self-signed TLS, generated at apply time. The brief explicitly permits a
# self-signed certificate, and forbids spending money on certificates.
#
# Ordering note: the cert needs the node IPs, and the server's user_data needs
# the cert. Allocating Elastic IPs as standalone resources breaks what would
# otherwise be a dependency cycle -- the addresses exist before any instance does.

resource "tls_private_key" "server" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "server" {
  private_key_pem = tls_private_key.server.private_key_pem

  subject {
    common_name  = local.ingress_host
    organization = "Cloud and DevOps Challenge"
  }

  dns_names             = local.cert_dns_names
  ip_addresses          = local.node_public_ips
  validity_period_hours = 8760

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

# SSH key generated here so the whole cluster is one `terraform apply` with no
# console prerequisites. The private key lands in this directory and is gitignored.
resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "main" {
  key_name   = "${var.project}-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "local_sensitive_file" "ssh" {
  content         = tls_private_key.ssh.private_key_openssh
  filename        = "${path.module}/${var.project}-key.pem"
  file_permission = "0600"
}
