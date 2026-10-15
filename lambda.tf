# ---------------------------------------------------------------------------
# Secrets Manager rotation for the Amazon MQ broker credential.
#
# AWS publishes managed rotation templates for RDS, Redshift and DocumentDB
# but not for Amazon MQ, so the four-step rotation protocol is implemented in
# lambda/mq_rotation/index.py and deployed here.
#
# The deployment package is signed with AWS Signer before it reaches Lambda:
#
#   archive_file -> S3 (versioned) -> signer job -> signed object -> Lambda
#
# The function's code signing config is set to Enforce, so Lambda rejects any
# package that is not signed by this profile.
#
# The function runs in the private subnets and reaches the Secrets Manager,
# KMS and Amazon MQ control planes over the PrivateLink endpoints in
# vpc_endpoints.tf, so it needs no route to the internet.
# ---------------------------------------------------------------------------

data "archive_file" "mq_rotation" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/mq_rotation"
  output_path = "${path.module}/.build/mq_rotation.zip"
}

# --- Signed artifact pipeline ----------------------------------------------

# AWS Signer reads the source object by version, so versioning is required
# here rather than optional. Signer writes with SSE-S3, so this bucket uses
# AES256 rather than the customer-managed key.
module "lambda_artifacts" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "4.2.2"

  bucket_prefix = "${local.service_prefix}-lambda-"

  force_destroy            = false
  control_object_ownership = true
  object_ownership         = "BucketOwnerEnforced"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  attach_deny_insecure_transport_policy = true

  versioning = {
    status = "Enabled"
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
      bucket_key_enabled = true
    }
  }

  lifecycle_rule = [
    {
      id     = "expire-superseded-artifacts"
      status = "Enabled"

      filter = {
        prefix = ""
      }

      noncurrent_version_expiration = {
        noncurrent_days = 30
      }
    },
  ]

  tags = local.common_tags
}

resource "aws_s3_object" "mq_rotation_src" {
  bucket = module.lambda_artifacts.s3_bucket_id
  key    = "unsigned/mq_rotation-${data.archive_file.mq_rotation.output_base64sha256}.zip"
  source = data.archive_file.mq_rotation.output_path
  etag   = data.archive_file.mq_rotation.output_md5

  tags = local.common_tags
}

resource "aws_signer_signing_profile" "lambda" {
  # Signer profile names allow alphanumerics and underscores only.
  name_prefix = "${replace(local.service_prefix, "-", "_")}_"
  platform_id = "AWSLambda-SHA384-ECDSA"

  signature_validity_period {
    value = 5
    type  = "YEARS"
  }

  tags = local.common_tags
}

resource "aws_signer_signing_job" "mq_rotation" {
  profile_name = aws_signer_signing_profile.lambda.name

  source {
    s3 {
      bucket  = module.lambda_artifacts.s3_bucket_id
      key     = aws_s3_object.mq_rotation_src.key
      version = aws_s3_object.mq_rotation_src.version_id
    }
  }

  destination {
    s3 {
      bucket = module.lambda_artifacts.s3_bucket_id
      prefix = "signed/"
    }
  }

  ignore_signing_job_failure = false
}

resource "aws_lambda_code_signing_config" "lambda" {
  description = "Only artifacts signed for ${local.service_prefix} may be deployed"

  allowed_publishers {
    signing_profile_version_arns = [aws_signer_signing_profile.lambda.version_arn]
  }

  policies {
    untrusted_artifact_on_deployment = "Enforce"
  }

  tags = local.common_tags
}

# --- Network ---------------------------------------------------------------

resource "aws_security_group" "mq_rotation" {
  name        = "${local.service_prefix}-mq-rotation"
  description = "Secrets Manager rotation function for the ActiveMQ credential"
  vpc_id      = module.vpc.vpc_id

  tags = merge(local.common_tags, { Name = "${local.service_prefix}-mq-rotation" })
}

resource "aws_vpc_security_group_egress_rule" "mq_rotation_https" {
  security_group_id            = aws_security_group.mq_rotation.id
  description                  = "HTTPS to the PrivateLink endpoints"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.vpc_endpoints.id

  tags = local.common_tags
}

# --- Failure handling ------------------------------------------------------

resource "aws_sqs_queue" "mq_rotation_dlq" {
  name = "${local.service_prefix}-mq-rotation-dlq"

  kms_master_key_id                 = module.kms.key_arn
  kms_data_key_reuse_period_seconds = 300
  sqs_managed_sse_enabled           = false
  message_retention_seconds         = 1209600

  tags = local.common_tags
}

data "aws_iam_policy_document" "mq_rotation_dlq" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["sqs:*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    resources = [aws_sqs_queue.mq_rotation_dlq.arn]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "mq_rotation_dlq" {
  queue_url = aws_sqs_queue.mq_rotation_dlq.id
  policy    = data.aws_iam_policy_document.mq_rotation_dlq.json
}

resource "aws_cloudwatch_log_group" "mq_rotation" {
  name              = "/aws/lambda/${local.service_prefix}-mq-rotation"
  retention_in_days = var.log_retention_in_days
  kms_key_id        = module.kms.key_arn

  tags = local.common_tags
}

# --- Role ------------------------------------------------------------------

data "aws_iam_policy_document" "mq_rotation_assume" {
  statement {
    sid     = "LambdaAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "mq_rotation" {
  name               = "${local.service_prefix}-mq-rotation"
  assume_role_policy = data.aws_iam_policy_document.mq_rotation_assume.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "mq_rotation_vpc" {
  role       = aws_iam_role.mq_rotation.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "mq_rotation" {
  statement {
    sid    = "RotateTheBrokerSecret"
    effect = "Allow"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
      "secretsmanager:PutSecretValue",
      "secretsmanager:UpdateSecretVersionStage",
    ]
    resources = [aws_secretsmanager_secret.mq.arn]
  }

  statement {
    sid       = "GenerateReplacementPasswords"
    effect    = "Allow"
    actions   = ["secretsmanager:GetRandomPassword"]
    resources = ["*"]
  }

  statement {
    sid    = "ApplyTheCredentialToTheBroker"
    effect = "Allow"
    actions = [
      "mq:DescribeBroker",
      "mq:DescribeUser",
      "mq:UpdateUser",
      "mq:RebootBroker",
    ]
    resources = [aws_mq_broker.fineract.arn]
  }

  statement {
    sid    = "UseThePlatformKey"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey",
    ]
    resources = [module.kms.key_arn]
  }

  statement {
    sid       = "ReportFailures"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.mq_rotation_dlq.arn]
  }

  statement {
    sid    = "WriteItsOwnLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.mq_rotation.arn}:*"]
  }

  statement {
    sid    = "EmitTraces"
    effect = "Allow"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "mq_rotation" {
  name   = "${local.service_prefix}-mq-rotation"
  role   = aws_iam_role.mq_rotation.id
  policy = data.aws_iam_policy_document.mq_rotation.json
}

# --- Function --------------------------------------------------------------

resource "aws_lambda_function" "mq_rotation" {
  function_name = "${local.service_prefix}-mq-rotation"
  description   = "Rotates the ActiveMQ broker credential held in Secrets Manager"
  role          = aws_iam_role.mq_rotation.arn

  # The signed artifact produced by the signer job, not the raw zip.
  s3_bucket = module.lambda_artifacts.s3_bucket_id
  s3_key    = aws_signer_signing_job.mq_rotation.signed_object[0].s3[0].key

  code_signing_config_arn = aws_lambda_code_signing_config.lambda.arn

  handler       = "index.lambda_handler"
  runtime       = "python3.12"
  architectures = ["x86_64"]
  timeout       = 300
  memory_size   = 256

  # Rotation is serial by design: concurrent runs would fight over the broker.
  reserved_concurrent_executions = 1

  # Environment variables are encrypted with the customer-managed key.
  kms_key_arn = module.kms.key_arn

  environment {
    variables = {
      MQ_BROKER_ID = aws_mq_broker.fineract.id
    }
  }

  vpc_config {
    subnet_ids         = module.vpc.private_subnets
    security_group_ids = [aws_security_group.mq_rotation.id]
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.mq_rotation_dlq.arn
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [
    aws_cloudwatch_log_group.mq_rotation,
    aws_iam_role_policy.mq_rotation,
    aws_iam_role_policy_attachment.mq_rotation_vpc,
  ]

  tags = local.common_tags
}

resource "aws_lambda_permission" "mq_rotation" {
  statement_id  = "AllowSecretsManagerInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.mq_rotation.function_name
  principal     = "secretsmanager.amazonaws.com"
  source_arn    = aws_secretsmanager_secret.mq.arn
}

resource "aws_secretsmanager_secret_rotation" "mq" {
  secret_id           = aws_secretsmanager_secret.mq.id
  rotation_lambda_arn = aws_lambda_function.mq_rotation.arn

  rotation_rules {
    automatically_after_days = var.mq_secret_rotation_days
  }

  depends_on = [
    aws_lambda_permission.mq_rotation,
    aws_secretsmanager_secret_version.mq,
  ]
}
