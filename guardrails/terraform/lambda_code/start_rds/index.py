"""
Morning cost-guardrail Lambda — counterpart to stop_rds.
 
Finds all RDS instances tagged auto_shutdown=true and starts the ones that are
currently stopped, so you have a working environment when you sit down to work
without needing to remember to start it manually.
 
Triggered by an EventBridge scheduled rule (see eventbridge.tf).
"""
 
import boto3
 
rds = boto3.client("rds")
 
 
def handler(event, context):
    started = []
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
 
            if status != "stopped":
                skipped.append({"id": db_id, "reason": f"status is '{status}', not 'stopped'"})
                continue
 
            rds.start_db_instance(DBInstanceIdentifier=db_id)
            started.append(db_id)
 
    print(f"Started: {started}")
    print(f"Skipped: {skipped}")
 
    return {"started": started, "skipped": skipped}