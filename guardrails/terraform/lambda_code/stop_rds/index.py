"""
Nightly cost-guardrail Lambda.

Finds all RDS instances tagged auto_shutdown=true and stops the ones that are
currently running. RDS instances auto-restart after 7 days if left stopped, so
this is safe to run on a recurring schedule without needing a corresponding
"resume forever" safeguard.

Triggered by an EventBridge scheduled rule (see eventbridge.tf).
"""

import boto3

rds = boto3.client("rds")


def handler(event, context):
    stopped = []
    skipped = []

    paginator = rds.get_paginator("describe_db_instances")
    for page in paginator.paginate():
        for db in page["DBInstances"]:
            db_id = db["DBInstanceIdentifier"]
            db_arn = db["DBInstanceArn"]
            status = db["DBInstanceStatus"]

            tags = rds.list_tags_for_resource(ResourceName=db_arn)["TagList"]
            tag_map = {t["Key"]: t["Value"] for t in tags}

            if tag_map.get("auto_shutdown", "").lower() != "true":
                skipped.append({"id": db_id, "reason": "not tagged auto_shutdown=true"})
                continue

            if status != "available":
                skipped.append({"id": db_id, "reason": f"status is '{status}', not 'available'"})
                continue

            rds.stop_db_instance(DBInstanceIdentifier=db_id)
            stopped.append(db_id)

    print(f"Stopped: {stopped}")
    print(f"Skipped: {skipped}")

    return {"stopped": stopped, "skipped": skipped}
