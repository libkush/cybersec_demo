###############################################################################
#  Asset bucket
#
#  The site, the attack scripts and the monitoring config all live here and are
#  pulled down by cloud-init on each node. This keeps EC2 user_data tiny (it has
#  a hard 16 KiB ceiling) and means you can iterate on the demo content without
#  regenerating any HCL.
###############################################################################

resource "aws_s3_bucket" "assets" {
  bucket        = local.asset_bucket
  force_destroy = true

  tags = { Name = local.asset_bucket }
}

resource "aws_s3_bucket_public_access_block" "assets" {
  bucket = aws_s3_bucket.assets.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# --- Verbatim assets ---------------------------------------------------------
resource "aws_s3_object" "static" {
  for_each = local.static_assets

  bucket = aws_s3_bucket.assets.id
  key    = "${local.asset_prefix}/${each.key}"
  source = each.value
  etag   = filemd5(each.value)
}

# --- Rendered assets ---------------------------------------------------------
resource "aws_s3_object" "rendered" {
  for_each = local.rendered_assets

  bucket  = aws_s3_bucket.assets.id
  key     = "${local.asset_prefix}/${each.key}"
  content = each.value
  etag    = md5(each.value)
}

###############################################################################
#  Instance role
###############################################################################

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.project_name}-${var.lab_name}-node"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = { Name = "${var.lab_name}-node" }
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.project_name}-${var.lab_name}-node"
  role = aws_iam_role.node.name
}

# Read the lab assets. Nothing else in S3 is granted.
data "aws_iam_policy_document" "lab_access" {
  statement {
    sid       = "ReadLabAssets"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.assets.arn, "${aws_s3_bucket.assets.arn}/*"]
  }

  # Prometheus discovers scrape targets with its EC2 service discovery, which
  # needs DescribeInstances. Scoped to read-only Describe* calls.
  dynamic "statement" {
    for_each = var.deploy_observer ? [1] : []

    content {
      sid       = "PrometheusServiceDiscovery"
      effect    = "Allow"
      actions   = ["ec2:DescribeInstances", "ec2:DescribeAvailabilityZones", "ec2:DescribeTags"]
      resources = ["*"]
    }
  }
}

resource "aws_iam_role_policy" "lab_access" {
  name   = "${var.lab_name}-lab-access"
  role   = aws_iam_role.node.id
  policy = data.aws_iam_policy_document.lab_access.json
}

# Lets you use SSM Session Manager instead of SSH if you are behind a firewall.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
