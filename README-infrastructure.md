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

- **No NAT gateway.** Every AWS API the tasks and the rotation function use is
  reached over PrivateLink endpoints, so the private subnets have no route to
  the internet.
- **One customer-managed KMS key** encrypts RDS, MQ, ECR, the log groups, the
  rotation function's environment and its dead letter queue.
- **No IAM users.** Tasks authenticate with task roles, per the `no-iam-users`
  policy.
- **No SSH anywhere.** Operators use ECS Exec, so nothing listens on port 22.
- **Signed Lambda artifacts.** The rotation package is signed with AWS Signer
  and the function enforces code signing, so an unsigned artifact is rejected
  at deploy time.

## Required input

`acm_certificate_arn` has no default. Supply the ARN of a certificate in the
same region covering the hostname that will point at the load balancer.

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

## Known scanner findings

`workspace_verify` reports 231 passing and 5 failing checkov checks. All five
are false positives and are listed here rather than suppressed in code, since
suppression comments are not permitted:

| Check | Resource | Why it is a false positive |
| --- | --- | --- |
| `CKV2_AWS_5` | `aws_security_group.alb` | Attached to the load balancer inside `module.alb`. Checkov does not resolve external modules, so it cannot see the edge. |
| `CKV2_AWS_5` | `aws_security_group.database` | Attached to the instance inside `module.postgresql`, same reason. |
| `CKV_AWS_111` | `aws_iam_policy_document.kms` | The `Resource: "*"` in a KMS **key policy** means "this key", not "all keys". It cannot name the key's own ARN, which does not exist until the key is created. |
| `CKV_AWS_356` | `aws_iam_policy_document.kms` | Same as above. |
| `CKV_AWS_109` | `aws_iam_policy_document.kms` | Same as above. The root-account statement is the AWS-recommended form; removing it makes the key unmanageable. |

The `CKV2_AWS_5` pair is demonstrably a resolution limit: the `service`, `mq`,
`mq_rotation` and `vpc_endpoints` groups pass the identical check, and the only
difference is that their consumers are local resources rather than module
internals.
