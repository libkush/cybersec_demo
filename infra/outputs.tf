output "admin_cidr" {
  description = "CIDR that is allowed to reach the lab UIs and SSH."
  value       = local.admin_cidr
}

###############################################################################
#  Victim
###############################################################################

output "victim_public_ip" {
  description = "Public IP of the victim web server."
  value       = aws_instance.victim.public_ip
}

output "victim_private_ip" {
  description = "Private IP of the victim -- this is the actual attack target."
  value       = aws_instance.victim.private_ip
}

output "victim_site_url" {
  description = "Open this in a browser to show the demo site (and watch it die)."
  value       = "http://${aws_instance.victim.public_ip}/"
}

###############################################################################
#  Attackers
###############################################################################

output "attacker_public_ips" {
  description = "Public IPs of the attack nodes."
  value       = aws_instance.attacker[*].public_ip
}

output "attacker_private_ips" {
  description = "Private IPs of the attack nodes."
  value       = aws_instance.attacker[*].private_ip
}

###############################################################################
#  Observer
###############################################################################

output "observer_public_ip" {
  description = "Public IP of the monitoring node (null when deploy_observer = false)."
  value       = one(aws_instance.observer[*].public_ip)
}

output "grafana_url" {
  description = "Grafana URL. Log in with admin / <grafana_admin_password>."
  value       = var.deploy_observer ? "http://${one(aws_instance.observer[*].public_ip)}:3000/" : null
}

output "prometheus_url" {
  description = "Prometheus URL (useful for ad-hoc PromQL in front of the class)."
  value       = var.deploy_observer ? "http://${one(aws_instance.observer[*].public_ip)}:9090/" : null
}

output "grafana_admin_password" {
  description = "Grafana admin password."
  value       = var.grafana_admin_password
  sensitive   = true
}

###############################################################################
#  Access / ergonomics
###############################################################################

output "ssh_private_key_path" {
  description = "Private key the helper scripts use."
  value       = local.private_key_path
}

output "ssh_commands" {
  description = "Copy-paste SSH commands for every node."
  value = merge(
    {
      victim = "ssh -i ${local.private_key_path} ec2-user@${aws_instance.victim.public_ip}"
    },
    { for i, ip in aws_instance.attacker[*].public_ip :
      "attacker-${i + 1}" => "ssh -i ${local.private_key_path} ec2-user@${ip}"
    },
    var.deploy_observer ? {
      observer = "ssh -i ${local.private_key_path} ec2-user@${one(aws_instance.observer[*].public_ip)}"
    } : {},
  )
}

###############################################################################
#  Summary
###############################################################################

output "summary" {
  description = "Human-readable recap printed after apply."
  value = join("\n", compact([
    "",
    "  Lab '${var.lab_name}' is up in ${var.region}  (${local.node_count} nodes, ${var.instance_type})",
    "",
    "  Victim site      : http://${aws_instance.victim.public_ip}/",
    "  Victim (internal): http://${aws_instance.victim.private_ip}/",
    "  Attackers        : ${join(", ", aws_instance.attacker[*].public_ip)}",
    var.deploy_observer ? "  Grafana          : http://${one(aws_instance.observer[*].public_ip)}:3000/  (admin / run: tofu output -raw grafana_admin_password)" : "  Observer         : not deployed -- run monitoring/docker-compose.yml locally",
    var.deploy_observer ? "  Prometheus       : http://${one(aws_instance.observer[*].public_ip)}:9090/" : "",
    "",
    "  Start the attack : ./scripts/attack.sh start",
    "  Stop the attack  : ./scripts/attack.sh stop",
    "  Node status      : ./scripts/status.sh",
    "  Tear it all down : ./scripts/down.sh",
    "",
  ]))
}
