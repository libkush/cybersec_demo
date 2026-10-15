###############################################################################
#  SSH key material
###############################################################################

resource "tls_private_key" "lab" {
  count = local.use_generated_key ? 1 : 0

  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "lab" {
  count = local.use_generated_key ? 1 : 0

  key_name   = local.key_name
  public_key = tls_private_key.lab[0].public_key_openssh

  tags = { Name = local.key_name }
}

# NOTE: the private key ends up in the OpenTofu state file as well as on disk.
# That is fine for a disposable training lab -- use `var.key_name` to bring your
# own key if your state backend is not somewhere you trust.
resource "local_file" "private_key" {
  count = local.use_generated_key ? 1 : 0

  content         = tls_private_key.lab[0].private_key_pem
  filename        = local.private_key_path
  file_permission = "0600"
}

###############################################################################
#  Victim -- deliberately vulnerable Apache (slowloris target)
###############################################################################

resource "aws_instance" "victim" {
  ami                         = local.ami_id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.victim.id]
  key_name                    = local.key_name
  iam_instance_profile        = aws_iam_instance_profile.node.name
  associate_public_ip_address = true
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/userdata_victim.sh.tftpl", {
    asset_bucket            = aws_s3_bucket.assets.id
    asset_prefix            = local.asset_prefix
    region                  = var.region
    lab_name                = var.lab_name
    node_exporter_version   = var.node_exporter_version
    apache_exporter_version = var.apache_exporter_version
  })

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = var.instance_volume_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${var.lab_name}-victim"
    Role = "victim"
  }

  depends_on = [
    aws_key_pair.lab,
    aws_s3_object.static,
    aws_s3_object.rendered,
    aws_iam_role_policy.lab_access,
  ]
}

###############################################################################
#  Attackers -- the distributed half of the DDoS
###############################################################################

resource "aws_instance" "attacker" {
  count = var.attacker_count

  ami                         = local.ami_id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.attacker.id]
  key_name                    = local.key_name
  iam_instance_profile        = aws_iam_instance_profile.node.name
  associate_public_ip_address = true
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/userdata_attacker.sh.tftpl", {
    asset_bucket          = aws_s3_bucket.assets.id
    asset_prefix          = local.asset_prefix
    region                = var.region
    lab_name              = var.lab_name
    node_exporter_version = var.node_exporter_version

    attack_target   = aws_instance.victim.private_ip
    attack_port     = 80
    attack_sockets  = var.attacker_sockets
    attack_interval = var.attacker_interval
    attack_timeout  = var.attacker_timeout
  })

  # node_exporter only -- no inbound attack surface on these boxes.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = var.instance_volume_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${var.lab_name}-attacker-${count.index + 1}"
    Role = "attacker"
  }

  depends_on = [
    aws_key_pair.lab,
    aws_s3_object.static,
    aws_iam_role_policy.lab_access,
  ]
}

###############################################################################
#  Observer -- Prometheus + Grafana + blackbox_exporter
###############################################################################

resource "aws_instance" "observer" {
  count = var.deploy_observer ? 1 : 0

  ami                         = local.ami_id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.observer.id]
  key_name                    = local.key_name
  iam_instance_profile        = aws_iam_instance_profile.node.name
  associate_public_ip_address = true
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/userdata_observer.sh.tftpl", {
    asset_bucket           = aws_s3_bucket.assets.id
    asset_prefix           = local.asset_prefix
    region                 = var.region
    lab_name               = var.lab_name
    blackbox_image         = var.blackbox_image
    prometheus_image       = var.prometheus_image
    grafana_image          = var.grafana_image
    grafana_admin_password = var.grafana_admin_password
    prometheus_retention   = var.prometheus_retention
  })

  # Prometheus runs in Docker and needs IMDS to federate the instance role for
  # EC2 service discovery, so the container hop limit must be 2 (not the usual 1).
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = var.instance_volume_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${var.lab_name}-observer"
    Role = "observer"
  }

  depends_on = [
    aws_key_pair.lab,
    aws_s3_object.static,
    aws_s3_object.rendered,
    aws_iam_role_policy.lab_access,
  ]
}
