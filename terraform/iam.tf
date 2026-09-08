# --- Node instance profile -------------------------------------------------
# SSM only. This is what lets GitHub Actions reach the cluster without any
# inbound port and without a kubeconfig stored as a GitHub secret.

data "aws_iam_policy_document" "ec2_assume" {
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
  name               = "${var.project}-node"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "node_ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.project}-node"
  role = aws_iam_role.node.name
}

# --- GitHub Actions OIDC ---------------------------------------------------
# Short-lived credentials federated from GitHub. No AWS access keys exist
# anywhere in this project.

resource "aws_iam_openid_connect_provider" "github" {
  count = var.github_repo != "" && var.create_github_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.github_repo != "" && !var.create_github_oidc_provider ? 1 : 0

  url = "https://token.actions.githubusercontent.com"
}

locals {
  github_oidc_arn = var.github_repo == "" ? "" : (
    var.create_github_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
    : data.aws_iam_openid_connect_provider.github[0].arn
  )
}

data "aws_iam_policy_document" "gha_assume" {
  count = var.github_repo == "" ? 0 : 1

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Scoped to this repository. Any other repo presenting a valid GitHub
    # token is still refused.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:*"]
    }
  }
}

data "aws_iam_policy_document" "gha_deploy" {
  count = var.github_repo == "" ? 0 : 1

  # Run a shell script on the server node -- and only the server node.
  statement {
    effect    = "Allow"
    actions   = ["ssm:SendCommand"]
    resources = [aws_instance.server.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:${var.region}::document/AWS-RunShellScript"]
  }

  # Read back the result so the workflow can fail on a failed rollout.
  statement {
    effect    = "Allow"
    actions   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "gha_deploy" {
  count = var.github_repo == "" ? 0 : 1

  name               = "${var.project}-github-deploy"
  assume_role_policy = data.aws_iam_policy_document.gha_assume[0].json
}

resource "aws_iam_role_policy" "gha_deploy" {
  count = var.github_repo == "" ? 0 : 1

  name   = "ssm-deploy"
  role   = aws_iam_role.gha_deploy[0].id
  policy = data.aws_iam_policy_document.gha_deploy[0].json
}
