import os
import hmac

def handler(event, context):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}

    environment = headers.get("x-environment", "")
    student_id  = headers.get("x-student-id", "").strip()
    token       = headers.get("x-internal-token", "")
    expected    = os.environ["INTERNAL_TOKEN"]

    allowed = (
        environment == "dev"
        and bool(student_id)
        and hmac.compare_digest(token.encode(), expected.encode())
    )
    return {"isAuthorized": allowed, "context": {"studentId": student_id}}