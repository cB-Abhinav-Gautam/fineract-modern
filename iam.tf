# Roles only - the platform policy "no-iam-users" forbids IAM users and
# long-lived access keys, so the tasks authenticate through task roles.

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    sid     = "EcsTasksAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

# --- Execution role: used by the ECS agent to start the task --------------

resource "aws_iam_role" "task_execution" {
  name               = "${local.service_prefix}-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "task_execution_extra" {
  statement {
    sid    = "ReadRuntimeSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
    ]
    resources = [
      aws_secretsmanager_secret.mq.arn,
      module.postgresql.db_instance_master_user_secret_arn,
    ]
  }

  statement {
    sid    = "DecryptWithPlatformKey"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [module.kms.key_arn]
  }
}

resource "aws_iam_role_policy" "task_execution_extra" {
  name   = "${local.service_prefix}-task-execution-extra"
  role   = aws_iam_role.task_execution.id
  policy = data.aws_iam_policy_document.task_execution_extra.json
}

# --- Task role: used by the application itself ----------------------------

resource "aws_iam_role" "task" {
  name               = "${local.service_prefix}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json

  tags = local.common_tags
}

data "aws_iam_policy_document" "task" {
  statement {
    sid    = "KeyspacesDataAccess"
    effect = "Allow"
    actions = [
      "cassandra:Select",
      "cassandra:Modify",
      "cassandra:Create",
      "cassandra:Alter",
      "cassandra:Drop",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:cassandra:${var.aws_region}:${data.aws_caller_identity.current.account_id}:/keyspace/${aws_keyspaces_keyspace.main.name}/*",
      "arn:${data.aws_partition.current.partition}:cassandra:${var.aws_region}:${data.aws_caller_identity.current.account_id}:/keyspace/system*",
    ]
  }

  statement {
    sid    = "ReadRuntimeSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
    ]
    resources = [
      aws_secretsmanager_secret.mq.arn,
      module.postgresql.db_instance_master_user_secret_arn,
    ]
  }

  statement {
    sid    = "DecryptWithPlatformKey"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [module.kms.key_arn]
  }

  # ECS Exec, so operators can get a shell into a task without SSH.
  statement {
    sid    = "EcsExec"
    effect = "Allow"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "task" {
  name   = "${local.service_prefix}-task"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}
