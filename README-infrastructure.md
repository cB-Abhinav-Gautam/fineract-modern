# Infrastructure for the Fineract CN accounting service

This directory provisions the AWS footprint for the Apache Fineract CN
accounting service built from this repository.

## What the application needs

Read from `service/src/main/resources/application.yml`, `service/build.gradle`
and the `Dockerfile`:

| Application dependency | AWS service | Notes |
| --- | --- | --- |
| PostgreSQL, database `seshat` | RDS PostgreSQL | Tenant/meta database. Master credential generated and rotated by RDS in Secrets Manager. |
| Cassandra, keyspace `seshat` | Amazon Keyspaces | Managed CQL. Tables are created by the service's own migrations at first start. |
| JMS broker | Amazon MQ (ActiveMQ) | `ACTIVE_STANDBY_MULTI_AZ`. Credential rotated by the function in `lambda/mq_rotation`. |
| Container, port 2025, `/accounting/v1` | ECS Fargate + ALB | TLS terminates at the load balancer; there is no plain-HTTP listener. |
| Container image | ECR | Immutable tags, scan on push, KMS encrypted. |

Eureka and Spring Cloud Config are disabled in `application.yml`, so no
discovery or config server is provisioned. Service-to-service addressing is
handled by the load balancer.

## Design decisions

- **The load balancer is internal.** There is no internet-facing entry point.
  Callers must already be on the VPC, on a peered network, or arriving over a
  VPN or Direct Connect.
- **No NAT gateway.** Every AWS API the tasks and the rotation function use is
  reached over PrivateLink endpoints, so the private subnets have no route to
  the internet.
- **One customer-managed KMS key** (`module.kms`) encrypts RDS, MQ, ECR, the
  log groups, the rotation function's environment and its dead letter queue.
- **No IAM users.** Tasks authenticate with task roles, per the `no-iam-users`
  policy.
- **No SSH anywhere.** Operators use ECS Exec, so nothing listens on port 22.
- **Signed Lambda artifacts.** The rotation package is signed with AWS Signer
  and the function enforces code signing, so an unsigned artifact is rejected
  at deploy time.
- **Registry modules where one exists.** The VPC, ALB, RDS, ECR, ACM, KMS, S3
  and security-group resources come from the Apex-approved
  `terraform-aws-modules` registry entries, pinned to explicit versions.

## Region

`aws_region` defaults to **`us-east-2`**, matching the region the Apex AWS
connection is scoped to. The stack registration in Apex is currently set to
`us-east-1`. These must agree before an apply: a credential scoped to one
region cannot provision into another. Confirm which region is intended and
align the stack setting with this default, or override `aws_region`.

## Required input

The HTTPS listener needs a certificate, and there are two ways to supply one:

- **Let the stack issue it (default).** Set `domain_name` and
  `route53_zone_name`. The stack requests an ACM certificate, validates it by
  DNS against the public Route 53 zone, and creates an alias record pointing
  the hostname at the load balancer.
- **Bring your own.** Set `acm_certificate_arn` to an existing certificate in
  the same region. `domain_name` is then optional; without it, clients address
  the load balancer by its generated DNS name.

A precondition fails the plan with an explicit message if neither option is
fully specified, rather than failing partway through an apply.

Note that the zone used for validation is a *public* hosted zone while the
load balancer is *internal*, so the record publishes private addresses in
public DNS. That is a workable and common arrangement, but if it is not
acceptable here, move the record to a private zone and supply the certificate
via `acm_certificate_arn`.

## MQ credential rotation

`lambda/mq_rotation/index.py` implements the four-step Secrets Manager
protocol. Two operational caveats:

- Amazon MQ applies ActiveMQ user changes on reboot, so `setSecret` reboots the
  broker. The broker is multi-AZ, so this is a failover rather than an outage,
  but clients reconnect.
- The accounting tasks read the credential at container start, so a rotation
  should be followed by an ECS service deployment before the new password is
  actually in use.

This function has not yet been exercised against a live broker. Run one
rotation manually in a non-production environment before relying on the
schedule.

## Verification status

`workspace_verify` passes all four stages:

| Stage | Result |
| --- | --- |
| `fmt` | pass |
| `tflint` | pass |
| `trivy` | pass — 0 misconfigurations in this configuration |
| `checkov` | pass — 211 passed, 0 failed, 0 skipped |

No suppression comments are used anywhere in this configuration, and none are
needed.

Trivy additionally reports two LOW advisory findings (`AWS-0089`, "bucket has
logging disabled") inside the vendored `terraform-aws-modules/s3-bucket`
module, for the ALB access-log bucket and the Lambda artifact bucket. These are
reported against the module's own source rather than this configuration and do
not fail the stage. Enabling access logging on a bucket whose only purpose is
to receive access logs would require a further bucket to log into; the finding
is recorded here rather than suppressed.

Checkov is run without `--download-external-modules`, so it cannot see inside
registry modules and logs a warning for each one it skips. Enabling that flag
was evaluated and rejected: it surfaces roughly ten findings located in vendor
module source that cannot be fixed from this repository.

## Unused public subnets

The VPC creates three public subnets and an internet gateway, but nothing is
placed in them — the load balancer is internal and sits in the private tier.
They cost nothing. If no internet-facing component is ever intended here,
removing `public_subnets` from the VPC module would eliminate the only
internet-facing path in the account, and is worth deciding on deliberately.
