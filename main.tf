resource "aws_s3_bucket" "bucket" {
  bucket = var.bucket_name
  acl    = "private"

  force_destroy = var.bucket_force_destroy

  versioning {
    enabled = var.bucket_versioning
  }

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }


  lifecycle_rule {
    id      = "log"
    enabled = var.log_auto_clean

    prefix = "logs/"

    tags = {
      rule      = "log"
      autoclean = var.log_auto_clean
    }

    transition {
      days          = var.log_standard_ia_days
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = var.log_glacier_days
      storage_class = "GLACIER"
    }

    expiration {
      days = var.log_expiry_days
    }
  }

  tags = merge(var.tags)

  dynamic "logging" {
    for_each = length(keys(var.bucket_logging)) == 0 ? [] : [var.bucket_logging]

    content {
      target_bucket = logging.value.target_bucket
      target_prefix = lookup(logging.value, "target_prefix", null)
    }
  }
}

resource "aws_s3_bucket_policy" "github_bucket_policy" {
  bucket = var.bucket_name
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowReadWriteAccess",
      "Effect": "Allow",
      "Principal": {
        "AWS": "${var.service_user_arn}"
      },
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket",
        "s3:DeleteObject",
        "s3:DeleteObjectVersion"
      ],
      "Resource": [
        "${aws_s3_bucket.bucket.arn}",
        "${aws_s3_bucket.bucket.arn}/*"
      ]
    }
  ]
}
EOF
}

##
resource "aws_s3_bucket_object" "bucket_public_keys_readme" {
  bucket  = aws_s3_bucket.bucket.id
  key     = "public-keys/README.txt"
  content = "Drop here the ssh public keys of the instances you want to control"
}

resource "aws_s3_bucket_public_access_block" "bucket_public_block" {
  bucket = aws_s3_bucket.bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_security_group" "bastion_host_security_group" {
  count       = var.bastion_security_group_id == "" ? 1 : 0
  description = "Enable SSH access to the bastion host from external via SSH port"
  name        = "${local.name_prefix}-host"
  vpc_id      = var.vpc_id

  tags = merge(var.tags)
}

resource "aws_security_group_rule" "ingress_bastion" {
  count       = var.bastion_security_group_id == "" ? 1 : 0
  description = "Incoming traffic to bastion"
  type        = "ingress"
  from_port   = var.public_ssh_port
  to_port     = var.public_ssh_port
  protocol    = "TCP"
  cidr_blocks = concat(data.aws_subnet.subnets.*.cidr_block, var.cidrs)

  security_group_id = local.security_group
}

resource "aws_security_group_rule" "egress_bastion" {
  count       = var.bastion_security_group_id == "" ? 1 : 0
  description = "Outgoing traffic from bastion to instances"
  type        = "egress"
  from_port   = "0"
  to_port     = "65535"
  protocol    = "-1"
  cidr_blocks = ["0.0.0.0/0"]

  security_group_id = local.security_group
}

resource "aws_security_group" "private_instances_security_group" {
  description = "Enable SSH access to the Private instances from the bastion via SSH port"
  name        = "${local.name_prefix}-priv-instances"
  vpc_id      = var.vpc_id

  tags = merge(var.tags)
}

resource "aws_security_group_rule" "ingress_instances" {
  description = "Incoming traffic from bastion"
  type        = "ingress"
  from_port   = var.private_ssh_port
  to_port     = var.private_ssh_port
  protocol    = "TCP"

  source_security_group_id = local.security_group

  security_group_id = aws_security_group.private_instances_security_group.id
}

data "aws_iam_policy_document" "assume_policy_document" {
  statement {
    actions = [
      "sts:AssumeRole"
    ]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "bastion_host_role" {
  path               = "/"
  assume_role_policy = data.aws_iam_policy_document.assume_policy_document.json
}

data "aws_iam_policy_document" "bastion_host_policy_document" {

  statement {
    actions = [
      "s3:PutObject",
      "s3:PutObjectAcl"
    ]
    resources = ["${aws_s3_bucket.bucket.arn}/logs/*"]
  }

  statement {
    actions = [
      "s3:GetObject"
    ]
    resources = ["${aws_s3_bucket.bucket.arn}/public-keys/*"]
  }

  statement {
    actions = [
      "s3:ListBucket"
    ]
    resources = [
    aws_s3_bucket.bucket.arn]

    condition {
      test     = "ForAnyValue:StringEquals"
      values   = ["public-keys/"]
      variable = "s3:prefix"
    }
  }

  statement {
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "kms:Encrypt",
      "kms:Decrypt"
    ]
    resources = ["${aws_s3_bucket.bucket.arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["AES256"]
    }
  }

}

resource "aws_iam_policy" "bastion_host_policy" {
  name_prefix = var.bastion_iam_policy_name
  policy      = data.aws_iam_policy_document.bastion_host_policy_document.json
}

resource "aws_iam_role_policy_attachment" "bastion_host" {
  policy_arn = aws_iam_policy.bastion_host_policy.arn
  role       = aws_iam_role.bastion_host_role.name
}

resource "aws_route53_record" "bastion_record_name" {
  name    = var.bastion_record_name
  zone_id = var.hosted_zone_id
  type    = "A"
  count   = var.create_dns_record ? 1 : 0

  alias {
    evaluate_target_health = true
    name                   = aws_lb.bastion_lb.dns_name
    zone_id                = aws_lb.bastion_lb.zone_id
  }
}

resource "aws_lb" "bastion_lb" {
  internal = var.is_lb_private
  name     = "${local.name_prefix}-lb"

  subnets = var.elb_subnets

  load_balancer_type               = "network"
  enable_cross_zone_load_balancing = var.cross_zone_lb
  tags                             = merge(var.tags)
}

resource "aws_lb_target_group" "bastion_lb_target_group" {
  name        = "${local.name_prefix}-lb-target"
  port        = var.public_ssh_port
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    port     = "traffic-port"
    protocol = "TCP"
  }

  tags = merge(var.tags)
}

resource "aws_lb_listener" "bastion_lb_listener_22" {
  default_action {
    target_group_arn = aws_lb_target_group.bastion_lb_target_group.arn
    type             = "forward"
  }

  load_balancer_arn = aws_lb.bastion_lb.arn
  port              = var.public_ssh_port
  protocol          = "TCP"
}

resource "aws_iam_instance_profile" "bastion_host_profile" {
  role = aws_iam_role.bastion_host_role.name
  path = "/"
}

resource "aws_launch_template" "bastion_launch_template" {
  name_prefix   = local.name_prefix
  image_id      = var.bastion_ami != "" ? var.bastion_ami : data.aws_ami.amazon-linux-2.id
  instance_type = var.instance_type

  monitoring {
    enabled = true
  }

  network_interfaces {
    associate_public_ip_address = var.associate_public_ip_address
    security_groups             = concat([local.security_group], var.bastion_additional_security_groups)
    delete_on_termination       = true
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.bastion_host_profile.name
  }

  key_name = var.bastion_host_key_pair

  user_data = base64encode(templatefile("${path.module}/user_data.sh", {
    aws_region              = data.aws_region.current.name
    bucket_name             = var.bucket_name
    extra_user_data_content = var.extra_user_data_content
    allow_ssh_commands      = var.allow_ssh_commands
    public_ssh_port         = var.public_ssh_port
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = merge({ Name = var.bastion_launch_template_name }, merge(var.tags))
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge({ Name = var.bastion_launch_template_name }, merge(var.tags))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "bastion_auto_scaling_group" {
  name_prefix = "ASG-${local.name_prefix}"

  launch_template {
    id      = aws_launch_template.bastion_launch_template.id
    version = "$Latest"
  }

  max_size         = var.bastion_instance_count
  min_size         = var.bastion_instance_count
  desired_capacity = var.bastion_instance_count

  vpc_zone_identifier = var.auto_scaling_group_subnets

  default_cooldown          = 180
  health_check_grace_period = 180
  health_check_type         = "EC2"

  target_group_arns = [
    aws_lb_target_group.bastion_lb_target_group.arn,
  ]

  termination_policies = [
    "OldestLaunchConfiguration",
  ]

  max_instance_lifetime = var.max_instance_lifetime

  dynamic "tag" {
    for_each = var.tags

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  tag {
    key                 = "Name"
    value               = "ASG-${local.name_prefix}"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [aws_s3_bucket.bucket]
}
