data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Shared join secret. This is the whole reason k3s beats kubeadm here: no
# two-phase token handoff, every node gets the same string at boot.
resource "random_string" "k3s_token" {
  length  = 48
  special = false
}

# --- Elastic IPs -----------------------------------------------------------
# Allocated before the instances so the TLS cert can name them (see tls.tf).
# Same hourly price as an auto-assigned public IPv4, and they survive a stop,
# so you can shut the cluster down overnight and keep the URL and certificate.

resource "aws_eip" "server" {
  domain = "vpc"
  tags   = { Name = "${var.project}-server" }
}

resource "aws_eip" "agent" {
  count = var.agent_count

  domain = "vpc"
  tags   = { Name = "${var.project}-agent-${count.index + 1}" }
}

# --- Nodes -----------------------------------------------------------------

resource "aws_instance" "server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.node.id]
  iam_instance_profile   = aws_iam_instance_profile.node.name
  key_name               = aws_key_pair.main.key_name

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_gb
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 only
  }

  # "standard" rather than the t3 default of "unlimited": burst CPU can never
  # turn into a surprise line item on the bill.
  credit_specification {
    cpu_credits = "standard"
  }

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/user-data/server.sh.tftpl", {
    k3s_channel      = var.k3s_channel
    k3s_token        = random_string.k3s_token.result
    node_external_ip = aws_eip.server.public_ip
    ingress_host     = local.ingress_host
    node_cidr        = var.vpc_cidr
    tls_crt_b64      = base64encode(tls_self_signed_cert.server.cert_pem)
    tls_key_b64      = base64encode(tls_private_key.server.private_key_pem)
  })

  tags = {
    Name = "${var.project}-server"
    Role = "server"
  }
}

resource "aws_instance" "agent" {
  count = var.agent_count

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.node.id]
  iam_instance_profile   = aws_iam_instance_profile.node.name
  key_name               = aws_key_pair.main.key_name

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_gb
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  credit_specification {
    cpu_credits = "standard"
  }

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/user-data/agent.sh.tftpl", {
    k3s_channel       = var.k3s_channel
    k3s_token         = random_string.k3s_token.result
    server_private_ip = aws_instance.server.private_ip
  })

  tags = {
    Name = "${var.project}-agent-${count.index + 1}"
    Role = "agent"
  }
}

resource "aws_eip_association" "server" {
  allocation_id = aws_eip.server.id
  instance_id   = aws_instance.server.id
}

resource "aws_eip_association" "agent" {
  count = var.agent_count

  allocation_id = aws_eip.agent[count.index].id
  instance_id   = aws_instance.agent[count.index].id
}
