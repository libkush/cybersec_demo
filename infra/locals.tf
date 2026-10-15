data "aws_caller_identity" "current" {}

# Only needed when admin_cidr is left empty, so the lab can lock itself down to
# whoever is running `tofu apply` without hard-coding an IP.
data "http" "myip" {
  count = var.admin_cidr == "" ? 1 : 0
  url   = "https://checkip.amazonaws.com"
}

# Only needed when ami_id is left empty.
data "aws_ssm_parameter" "al2023" {
  count = var.ami_id == "" ? 1 : 0
  name  = var.ami_ssm_parameter
}

locals {
  account_id = data.aws_caller_identity.current.account_id

  admin_cidr = var.admin_cidr != "" ? var.admin_cidr : local.detected_admin_cidr

  # try() keeps this safe when the data source has count == 0.
  detected_admin_cidr = try("${chomp(data.http.myip[0].response_body)}/32", "")

  ami_id = var.ami_id != "" ? var.ami_id : try(data.aws_ssm_parameter.al2023[0].value, "")

  # ---------------------------------------------------------------------------
  #  SSH key material
  # ---------------------------------------------------------------------------
  use_generated_key = var.key_name == ""
  key_name          = local.use_generated_key ? "${var.project_name}-${var.lab_name}" : var.key_name
  private_key_path  = local.use_generated_key ? abspath("${path.module}/${var.generated_key_dir}/${var.lab_name}-key.pem") : var.ssh_private_key_path

  # ---------------------------------------------------------------------------
  #  Asset distribution (site + attack scripts + monitoring config)
  # ---------------------------------------------------------------------------
  asset_bucket = "${var.project_name}-assets-${local.account_id}-${var.region}"
  asset_prefix = var.lab_name

  # ---------------------------------------------------------------------------
  #  Tags
  # ---------------------------------------------------------------------------
  base_tags = merge(
    {
      Project   = var.project_name
      LabName   = var.lab_name
      ManagedBy = "opentofu"
      Purpose   = "cybersecurity-training"
    },
    var.tags,
  )

  # ---------------------------------------------------------------------------
  #  Static assets: mirrored verbatim into S3 and pulled down by cloud-init.
  #  Keeping them in S3 (rather than in EC2 user_data) avoids the 16 KiB
  #  user_data limit and lets you edit the site/attacks without touching HCL.
  # ---------------------------------------------------------------------------
  static_assets = {
    "site/index.html" = "${path.module}/../site/index.html"
    "site/style.css"  = "${path.module}/../site/style.css"
    "site/app.js"     = "${path.module}/../site/app.js"

    "attack/slowloris.py"  = "${path.module}/../attack/slowloris.py"
    "attack/http_flood.py" = "${path.module}/../attack/http_flood.py"

    "monitoring/blackbox.yml" = "${path.module}/../monitoring/blackbox/blackbox.yml"

    "monitoring/grafana/provisioning/datasources/prometheus.yml" = "${path.module}/../monitoring/grafana/provisioning/datasources/prometheus.yml"
    "monitoring/grafana/provisioning/dashboards/dashboards.yml"  = "${path.module}/../monitoring/grafana/provisioning/dashboards/dashboards.yml"
    "monitoring/grafana/dashboards/slowloris-demo.json"          = "${path.module}/../monitoring/grafana/dashboards/slowloris-demo.json"

    "systemd/node_exporter.service"   = "${path.module}/../monitoring/systemd/node_exporter.service"
    "systemd/apache_exporter.service" = "${path.module}/../monitoring/systemd/apache_exporter.service"
    "systemd/lab-slowloris.service"   = "${path.module}/../monitoring/systemd/lab-slowloris.service"
  }

  # Rendered by OpenTofu (never interpolated from user data).
  rendered_assets = {
    "config/victim-apache.conf" = file("${path.module}/templates/victim_apache.conf")

    "monitoring/prometheus.yml" = templatefile("${path.module}/templates/prometheus.yml.tftpl", {
      region   = var.region
      lab_name = var.lab_name
    })
  }

  # Convenience: the two node counts, used by outputs and the summary.
  node_count = 1 + var.attacker_count + (var.deploy_observer ? 1 : 0)
}
