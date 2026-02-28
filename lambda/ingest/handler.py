"""
Lambda Ingestor for Restaurant Analytics Platform
--------------------------------------------------
Validates incoming clickstream events, enriches them with an ingested_at
timestamp, and delivers them to Kinesis Firehose for downstream processing.

Supports both:
  - API Gateway Lambda Proxy integration (event["body"] is a JSON string)
  - Direct Lambda invocation (event is already a dict with the payload fields)
"""

import json
import logging
import os
from datetime import datetime, timezone

import boto3
from botocore.exceptions import BotoCoreError, ClientError

# ---------------------------------------------------------------------------
# Structured JSON logger
# ---------------------------------------------------------------------------

class StructuredLogger:
    """Emit every log line as a single-line JSON object."""

    LEVELS = {
        "DEBUG": logging.DEBUG,
        "INFO": logging.INFO,
        "WARNING": logging.WARNING,
        "ERROR": logging.ERROR,
        "CRITICAL": logging.CRITICAL,
    }

    def __init__(self, name: str) -> None:
        self._logger = logging.getLogger(name)
        # Lambda sets up a root handler; avoid duplicate output.
        self._logger.propagate = False
        if not self._logger.handlers:
            handler = logging.StreamHandler()
            handler.setFormatter(logging.Formatter("%(message)s"))
            self._logger.addHandler(handler)
        self._logger.setLevel(logging.DEBUG)

    def _emit(self, level: str, message: str, **context) -> None:
        record = {"level": level, "message": message, **context}
        self._logger.log(self.LEVELS[level], json.dumps(record, default=str))

    def debug(self, message: str, **context) -> None:
        self._emit("DEBUG", message, **context)

    def info(self, message: str, **context) -> None:
        self._emit("INFO", message, **context)

    def warning(self, message: str, **context) -> None:
        self._emit("WARNING", message, **context)

    def error(self, message: str, **context) -> None:
        self._emit("ERROR", message, **context)

    def critical(self, message: str, **context) -> None:
        self._emit("CRITICAL", message, **context)


log = StructuredLogger(__name__)

# ---------------------------------------------------------------------------
# Firehose client — initialised once per container for connection reuse
# ---------------------------------------------------------------------------

FIREHOSE_STREAM_NAME: str = os.environ["FIREHOSE_STREAM_NAME"]

_firehose = boto3.client("firehose")

# ---------------------------------------------------------------------------
# Validation constants
# ---------------------------------------------------------------------------

REQUIRED_FIELDS: tuple[str, ...] = (
    "event_id",
    "restaurant_id",
    "session_id",
    "timestamp",
    "event_type",
    "menu_item_id",
    "menu_item_name",
    "category",
    "price",
    "device_type",
)

VALID_EVENT_TYPES: frozenset[str] = frozenset({"view", "click", "add_to_cart", "order"})
VALID_CATEGORIES: frozenset[str] = frozenset({"Burgers", "Pizza", "Salads", "Drinks", "Desserts"})
VALID_DEVICE_TYPES: frozenset[str] = frozenset({"mobile", "tablet", "kiosk", "web"})

# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------

class ValidationError(Exception):
    """Raised when an event fails schema validation."""

    def __init__(self, message: str, field: str) -> None:
        super().__init__(message)
        self.field = field


def _validate_event(body: dict) -> None:
    """
    Validate all required fields and domain constraints.
    Raises ValidationError with a descriptive message and the offending field
    name on the first failure encountered.
    """

    # 1. Required fields presence
    for field in REQUIRED_FIELDS:
        if field not in body:
            raise ValidationError(f"Missing required field: '{field}'", field)
        value = body[field]
        # Reject None and empty string for every required field
        if value is None or (isinstance(value, str) and value.strip() == ""):
            raise ValidationError(
                f"Required field '{field}' must not be null or empty", field
            )

    # 2. event_type
    event_type = body["event_type"]
    if event_type not in VALID_EVENT_TYPES:
        raise ValidationError(
            f"Invalid event_type '{event_type}'. "
            f"Must be one of: {sorted(VALID_EVENT_TYPES)}",
            "event_type",
        )

    # 3. category
    category = body["category"]
    if category not in VALID_CATEGORIES:
        raise ValidationError(
            f"Invalid category '{category}'. "
            f"Must be one of: {sorted(VALID_CATEGORIES)}",
            "category",
        )

    # 4. device_type
    device_type = body["device_type"]
    if device_type not in VALID_DEVICE_TYPES:
        raise ValidationError(
            f"Invalid device_type '{device_type}'. "
            f"Must be one of: {sorted(VALID_DEVICE_TYPES)}",
            "device_type",
        )

    # 5. price — must be numeric and positive
    price = body["price"]
    try:
        price_float = float(price)
    except (TypeError, ValueError):
        raise ValidationError(
            f"Field 'price' must be a numeric value, got: {type(price).__name__}",
            "price",
        )
    if price_float <= 0:
        raise ValidationError(
            f"Field 'price' must be a positive number, got: {price_float}",
            "price",
        )


# ---------------------------------------------------------------------------
# Response helpers
# ---------------------------------------------------------------------------

def _response(status_code: int, body: dict) -> dict:
    """Build an API Gateway-compatible Lambda proxy response."""
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


# ---------------------------------------------------------------------------
# Handler
# ---------------------------------------------------------------------------

def handler(event: dict, context) -> dict:
    """
    Lambda entry point.

    Accepts:
      - API Gateway Lambda proxy format  → event["body"] is a JSON string
      - Direct invocation format         → event keys are the payload fields

    Returns an API Gateway proxy-compatible response dict in all cases.
    """

    # ------------------------------------------------------------------
    # 1. Parse the incoming payload
    # ------------------------------------------------------------------
    raw_body = event.get("body")

    if raw_body is None:
        # Direct invocation — treat the whole event as the payload.
        body = event
    elif isinstance(raw_body, dict):
        # Body was already parsed (some test harnesses do this).
        body = raw_body
    else:
        # API Gateway passes body as a JSON string.
        try:
            body = json.loads(raw_body)
        except (json.JSONDecodeError, TypeError) as exc:
            log.error(
                "Failed to parse request body",
                error=str(exc),
                raw_body=str(raw_body)[:200],
            )
            return _response(400, {"error": "Request body is not valid JSON", "field": "body"})

    if not isinstance(body, dict):
        log.error("Parsed body is not a JSON object", body_type=type(body).__name__)
        return _response(400, {"error": "Request body must be a JSON object", "field": "body"})

    # ------------------------------------------------------------------
    # 2. Validate
    # ------------------------------------------------------------------
    try:
        _validate_event(body)
    except ValidationError as exc:
        log.warning(
            "Event failed schema validation",
            error=str(exc),
            field=exc.field,
            event_id=body.get("event_id"),
            restaurant_id=body.get("restaurant_id"),
        )
        return _response(400, {"error": str(exc), "field": exc.field})

    # ------------------------------------------------------------------
    # 3. Enrich
    # ------------------------------------------------------------------
    ingested_at = datetime.now(timezone.utc).isoformat()
    enriched = {**body, "ingested_at": ingested_at}

    # ------------------------------------------------------------------
    # 4. Deliver to Firehose
    # ------------------------------------------------------------------
    record_data = json.dumps(enriched, default=str) + "\n"

    try:
        _firehose.put_record(
            DeliveryStreamName=FIREHOSE_STREAM_NAME,
            Record={"Data": record_data.encode("utf-8")},
        )
    except (BotoCoreError, ClientError) as exc:
        log.error(
            "Firehose delivery failed",
            error=str(exc),
            event_id=body.get("event_id"),
            restaurant_id=body.get("restaurant_id"),
            stream=FIREHOSE_STREAM_NAME,
        )
        return _response(500, {"error": "Firehose delivery failed"})

    # ------------------------------------------------------------------
    # 5. Success
    # ------------------------------------------------------------------
    log.info(
        "Event ingested",
        event_id=body["event_id"],
        restaurant_id=body["restaurant_id"],
        event_type=body["event_type"],
        category=body["category"],
        device_type=body["device_type"],
        ingested_at=ingested_at,
        stream=FIREHOSE_STREAM_NAME,
    )

    return _response(200, {"status": "ok", "event_id": body["event_id"]})
