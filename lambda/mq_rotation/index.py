"""Secrets Manager rotation for the Amazon MQ (ActiveMQ) broker credential.

AWS publishes managed rotation templates for RDS, Redshift and DocumentDB but
not for Amazon MQ, so this implements the four-step rotation protocol directly
against the Amazon MQ control plane.

Steps, as invoked by Secrets Manager:

  createSecret  generate a new password and store it as AWSPENDING
  setSecret     apply the pending password to the broker user
  testSecret    confirm the broker accepted the change
  finishSecret  promote AWSPENDING to AWSCURRENT

Two operational caveats, documented in the stack README:

  * Amazon MQ applies ActiveMQ user changes on reboot, so setSecret reboots
    the broker. The broker is deployed ACTIVE_STANDBY_MULTI_AZ, so this is a
    failover rather than an outage, but clients will reconnect.
  * The accounting tasks read the credential at container start, so a rotation
    must be followed by an ECS service deployment before the new password is
    actually used.
"""

import json
import logging
import os

import boto3

LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

# Amazon MQ rejects commas, colons and equals signs in ActiveMQ passwords.
EXCLUDED_CHARACTERS = ",:=" + '"' + "'" + "\\/@"
PASSWORD_LENGTH = 32

BROKER_ID = os.environ["MQ_BROKER_ID"]


def lambda_handler(event, context):
    """Entry point for the Secrets Manager rotation invocation."""
    arn = event["SecretId"]
    token = event["ClientRequestToken"]
    step = event["Step"]

    secrets = boto3.client("secretsmanager")
    broker = boto3.client("mq")

    metadata = secrets.describe_secret(SecretId=arn)
    if not metadata.get("RotationEnabled"):
        raise ValueError("Secret %s is not enabled for rotation" % arn)

    stages = metadata["VersionIdsToStages"]
    if token not in stages:
        raise ValueError(
            "Version %s has no stage for rotation of secret %s" % (token, arn)
        )
    if "AWSCURRENT" in stages[token]:
        LOGGER.info("Version %s is already AWSCURRENT; nothing to do", token)
        return
    if "AWSPENDING" not in stages[token]:
        raise ValueError(
            "Version %s is not AWSPENDING for secret %s" % (token, arn)
        )

    handlers = {
        "createSecret": create_secret,
        "setSecret": set_secret,
        "testSecret": test_secret,
        "finishSecret": finish_secret,
    }

    if step not in handlers:
        raise ValueError("Unknown rotation step %s" % step)

    LOGGER.info("Running step %s for secret %s", step, arn)
    handlers[step](secrets, broker, arn, token)


def create_secret(secrets, broker, arn, token):
    """Generate the replacement password and store it as AWSPENDING."""
    current = _get_secret_dict(secrets, arn, "AWSCURRENT")

    try:
        _get_secret_dict(secrets, arn, "AWSPENDING", token)
        LOGGER.info("A pending secret already exists for version %s", token)
        return
    except secrets.exceptions.ResourceNotFoundException:
        pass

    new_password = secrets.get_random_password(
        PasswordLength=PASSWORD_LENGTH,
        ExcludeCharacters=EXCLUDED_CHARACTERS,
        RequireEachIncludedType=True,
    )["RandomPassword"]

    secrets.put_secret_value(
        SecretId=arn,
        ClientRequestToken=token,
        SecretString=json.dumps(
            {"username": current["username"], "password": new_password}
        ),
        VersionStages=["AWSPENDING"],
    )
    LOGGER.info("Stored a new pending password for version %s", token)


def set_secret(secrets, broker, arn, token):
    """Apply the pending password to the broker user, preserving its settings."""
    pending = _get_secret_dict(secrets, arn, "AWSPENDING", token)
    username = pending["username"]

    description = broker.describe_broker(BrokerId=BROKER_ID)
    usernames = [user["Username"] for user in description.get("Users", [])]
    if username not in usernames:
        raise ValueError(
            "User %s does not exist on broker %s; refusing to create it during "
            "rotation" % (username, BROKER_ID)
        )

    broker.update_user(
        BrokerId=BROKER_ID,
        Username=username,
        Password=pending["password"],
    )

    # Amazon MQ stages ActiveMQ user changes and applies them on reboot.
    state = description.get("BrokerState")
    if state == "RUNNING":
        broker.reboot_broker(BrokerId=BROKER_ID)
        LOGGER.info("Rebooted broker %s to apply the credential", BROKER_ID)
    else:
        LOGGER.warning(
            "Broker %s is in state %s; skipping reboot", BROKER_ID, state
        )


def test_secret(secrets, broker, arn, token):
    """Confirm the broker is healthy and the change is no longer pending."""
    pending = _get_secret_dict(secrets, arn, "AWSPENDING", token)
    username = pending["username"]

    description = broker.describe_broker(BrokerId=BROKER_ID)
    state = description.get("BrokerState")
    if state != "RUNNING":
        raise ValueError(
            "Broker %s is in state %s after the credential change"
            % (BROKER_ID, state)
        )

    usernames = [user["Username"] for user in description.get("Users", [])]
    if username not in usernames:
        raise ValueError(
            "User %s is not present on broker %s" % (username, BROKER_ID)
        )

    pending_changes = broker.describe_user(
        BrokerId=BROKER_ID, Username=username
    ).get("Pending")
    if pending_changes:
        raise ValueError(
            "Broker %s still has pending changes for user %s"
            % (BROKER_ID, username)
        )

    LOGGER.info("Broker %s accepted the credential for user %s", BROKER_ID, username)


def finish_secret(secrets, broker, arn, token):
    """Promote the pending version to AWSCURRENT."""
    metadata = secrets.describe_secret(SecretId=arn)

    current_version = None
    for version, version_stages in metadata["VersionIdsToStages"].items():
        if "AWSCURRENT" in version_stages:
            if version == token:
                LOGGER.info("Version %s is already current", version)
                return
            current_version = version
            break

    secrets.update_secret_version_stage(
        SecretId=arn,
        VersionStage="AWSCURRENT",
        MoveToVersionId=token,
        RemoveFromVersionId=current_version,
    )
    LOGGER.info("Promoted version %s to AWSCURRENT", token)


def _get_secret_dict(secrets, arn, stage, token=None):
    """Read a secret version and return it as a dict with the expected keys."""
    kwargs = {"SecretId": arn, "VersionStage": stage}
    if token:
        kwargs["VersionId"] = token

    payload = json.loads(secrets.get_secret_value(**kwargs)["SecretString"])

    for required in ("username", "password"):
        if required not in payload:
            raise KeyError(
                "Secret %s stage %s is missing the %s field" % (arn, stage, required)
            )
    return payload
