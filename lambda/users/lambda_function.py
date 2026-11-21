import json

def handler(event, context):
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"users": [{"id": 1, "name": "Ebtihal"}, {"id": 2, "name": "Hassan"}]}),
    }