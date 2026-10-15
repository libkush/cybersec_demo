###############################################################################
#  Security groups
#
#  Everything the lab exposes to the internet is gated on admin_cidr. The only
#  "dangerous" rule is attacker -> victim:80, which is exactly the traffic we
#  are demonstrating. Monitoring traffic is scoped to the observer SG so the
#  exporters are never reachable from the internet.
###############################################################################

# --- Observer (Prometheus / Grafana) -----------------------------------------
resource "aws_security_group" "observer" {
  name_prefix = "${var.lab_name}-observer-"
  description = "Monitoring node: Grafana + Prometheus UI"
  vpc_id      = aws_vpc.lab.id

  tags = { Name = "${var.lab_name}-observer" }

  ingress {
    description = "SSH from operator"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.admin_cidr]
  }

  ingress {
    description = "Grafana UI from operator"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [local.admin_cidr]
  }

  ingress {
    description = "Prometheus UI from operator"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = [local.admin_cidr]
  }

  egress {
    description = "Outbound to package repos, container registries and scrape targets"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# --- Attackers ---------------------------------------------------------------
resource "aws_security_group" "attacker" {
  name_prefix = "${var.lab_name}-attacker-"
  description = "Attack nodes: outbound flood only, no inbound services"
  vpc_id      = aws_vpc.lab.id

  tags = { Name = "${var.lab_name}-attacker" }

  ingress {
    description = "SSH from operator"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.admin_cidr]
  }

  ingress {
    description = "node_exporter scraped by the observer"
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    security_groups = [
      aws_security_group.observer.id,
    ]
  }

  egress {
    description = "Unrestricted outbound (the attack traffic itself)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# --- Victim ------------------------------------------------------------------
resource "aws_security_group" "victim" {
  name_prefix = "${var.lab_name}-victim-"
  description = "Victim web server running the deliberately vulnerable Apache"
  vpc_id      = aws_vpc.lab.id

  tags = { Name = "${var.lab_name}-victim" }

  ingress {
    description     = "HTTP from the attack nodes"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.attacker.id]
  }

  ingress {
    description     = "HTTP from blackbox_exporter on the observer (the synthetic end-user)"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.observer.id]
  }

  ingress {
    description = "HTTP from the operator (browser demo)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [local.admin_cidr]
  }

  ingress {
    description = "SSH from operator"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.admin_cidr]
  }

  ingress {
    description     = "node_exporter scraped by the observer"
    from_port       = 9100
    to_port         = 9100
    protocol        = "tcp"
    security_groups = [aws_security_group.observer.id]
  }

  ingress {
    description     = "apache_exporter scraped by the observer"
    from_port       = 9117
    to_port         = 9117
    protocol        = "tcp"
    security_groups = [aws_security_group.observer.id]
  }

  egress {
    description = "Outbound for package installs and pulling lab assets from S3"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}
