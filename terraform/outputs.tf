output "app_url" {
  description = "Open this. The certificate is self-signed, so expect a browser warning."
  value       = "https://${local.ingress_host}"
}

output "ingress_host" {
  description = "Hostname the Ingress and the TLS certificate are issued for."
  value       = local.ingress_host
}

output "server_instance_id" {
  description = "Set this as the SERVER_INSTANCE_ID repository variable in GitHub."
  value       = aws_instance.server.id
}

output "github_deploy_role_arn" {
  description = "Set this as the AWS_DEPLOY_ROLE_ARN repository secret in GitHub."
  value       = var.github_repo == "" ? "(not created -- set var.github_repo)" : aws_iam_role.gha_deploy[0].arn
}

output "node_public_ips" {
  description = "All node IPs. The app answers on every one of them."
  value       = local.node_public_ips
}

output "ssh_private_key_path" {
  description = "Generated SSH key, written on apply."
  value       = local_sensitive_file.ssh.filename
}

output "kubeconfig_command" {
  description = "Fetch a kubeconfig and merge it into ~/.kube/config as context cgi-k3s."
  value       = "./scripts/get-kubeconfig.sh"
}

output "ssh_command" {
  description = "Shell on the server node."
  value       = "ssh -i ${local_sensitive_file.ssh.filename} ubuntu@${aws_eip.server.public_ip}"
}

output "server_public_ip" {
  description = "Elastic IP of the control plane node."
  value       = aws_eip.server.public_ip
}

output "estimated_cost_per_day_usd" {
  description = "Rough on-demand cost while running. Stopping the instances drops this to about 0.45."
  value       = "~2.10 (3 x ${var.instance_type} + 3 Elastic IPs + ${var.agent_count + 1} x ${var.root_volume_gb}GB gp3)"
}
