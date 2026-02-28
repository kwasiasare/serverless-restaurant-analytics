"""
Restaurant Analytics Data Simulator
=====================================
Simulates realistic restaurant clickstream events and sends them to the
serverless ingest API endpoint.

Dependencies (install before running):
    pip install requests python-dotenv

Usage:
    python simulator.py --endpoint https://your-api-id.execute-api.us-east-1.amazonaws.com/prod/events \
                        --api-key your-api-key \
                        --events 500 \
                        --rate 10 \
                        --restaurants 3

    Or configure via .env file:
        API_ENDPOINT=https://...
        API_KEY=your-api-key
"""

import argparse
import json
import os
import random
import time
import uuid
from datetime import datetime, timedelta, timezone

# --- Dependency imports (see top-of-file install instructions) ---
try:
    import requests
except ImportError:
    raise SystemExit(
        "ERROR: 'requests' is not installed.\n"
        "Run: pip install requests python-dotenv"
    )

try:
    from dotenv import load_dotenv
except ImportError:
    raise SystemExit(
        "ERROR: 'python-dotenv' is not installed.\n"
        "Run: pip install requests python-dotenv"
    )

# ---------------------------------------------------------------------------
# Configuration / menu data
# ---------------------------------------------------------------------------

RESTAURANTS = [
    {"id": "rest_001", "name": "The Burger Joint"},
    {"id": "rest_002", "name": "Pizza Palace"},
    {"id": "rest_003", "name": "Garden Greens"},
]

MENU = {
    "Burgers": [
        {"id": "burger_001", "name": "Classic Burger",  "price": 8.99},
        {"id": "burger_002", "name": "Bacon Burger",    "price": 12.99},
        {"id": "burger_003", "name": "Veggie Burger",   "price": 10.99},
        {"id": "burger_004", "name": "Double Smash",    "price": 15.99},
    ],
    "Pizza": [
        {"id": "pizza_001", "name": "Margherita",     "price": 13.99},
        {"id": "pizza_002", "name": "Pepperoni",       "price": 15.99},
        {"id": "pizza_003", "name": "BBQ Chicken",     "price": 16.99},
        {"id": "pizza_004", "name": "Veggie Supreme",  "price": 14.99},
    ],
    "Salads": [
        {"id": "salad_001", "name": "Caesar Salad", "price": 9.99},
        {"id": "salad_002", "name": "Greek Salad",  "price": 10.99},
        {"id": "salad_003", "name": "Cobb Salad",   "price": 12.99},
    ],
    "Drinks": [
        {"id": "drink_001", "name": "Cola",             "price": 2.99},
        {"id": "drink_002", "name": "Lemonade",         "price": 3.49},
        {"id": "drink_003", "name": "Iced Tea",         "price": 2.99},
        {"id": "drink_004", "name": "Sparkling Water",  "price": 2.49},
    ],
    "Desserts": [
        {"id": "dessert_001", "name": "Chocolate Cake", "price": 6.99},
        {"id": "dessert_002", "name": "Ice Cream",       "price": 4.99},
        {"id": "dessert_003", "name": "Brownie",         "price": 5.99},
    ],
}

# Flat list of all menu items for quick sampling
ALL_ITEMS = [
    {**item, "category": category}
    for category, items in MENU.items()
    for item in items
]

# Device type weights: mobile=50%, web=30%, kiosk=15%, tablet=5%
DEVICE_TYPES = ["mobile", "web", "kiosk", "tablet"]
DEVICE_WEIGHTS = [50, 30, 15, 5]

# Event funnel transition probabilities
PROB_CLICK_AFTER_VIEW = 0.60
PROB_ADD_TO_CART_AFTER_CLICK = 0.40
PROB_ORDER_AFTER_ADD_TO_CART = 0.50


# ---------------------------------------------------------------------------
# Argument parsing and config resolution
# ---------------------------------------------------------------------------

def parse_args():
    parser = argparse.ArgumentParser(
        description="Simulate restaurant clickstream events and POST them to an API.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--endpoint",    type=str, default=None,
                        help="API ingest endpoint URL")
    parser.add_argument("--api-key",     type=str, default=None,
                        help="API key for x-api-key header")
    parser.add_argument("--events",      type=int, default=500,
                        help="Total number of events to send")
    parser.add_argument("--rate",        type=float, default=10.0,
                        help="Events per second to send")
    parser.add_argument("--restaurants", type=int, default=3,
                        help="Number of restaurant simulations to use (max 3)")
    return parser.parse_args()


def resolve_config(args):
    """
    Resolve endpoint and API key using priority:
      1. CLI args
      2. .env file  (loaded via python-dotenv)
      3. OS environment variables
    """
    # Load .env into os.environ (won't override existing env vars by default,
    # but we check CLI args first so this ordering is safe).
    load_dotenv(override=False)

    endpoint = (
        args.endpoint
        or os.environ.get("API_ENDPOINT")
    )
    api_key = (
        args.api_key
        or os.environ.get("API_KEY")
    )

    if not endpoint:
        raise SystemExit(
            "ERROR: No API endpoint supplied.\n"
            "  Use --endpoint URL, set API_ENDPOINT in .env, or export API_ENDPOINT."
        )
    if not api_key:
        raise SystemExit(
            "ERROR: No API key supplied.\n"
            "  Use --api-key KEY, set API_KEY in .env, or export API_KEY."
        )

    return endpoint.rstrip("/"), api_key


# ---------------------------------------------------------------------------
# Timestamp generation
# ---------------------------------------------------------------------------

def random_recent_timestamp():
    """Return an ISO-8601 UTC timestamp somewhere within the last 24 hours.

    Includes milliseconds so the format is compatible with both
    from_iso8601_timestamp() and date_parse('%Y-%m-%dT%H:%i:%s.%fZ') in Athena.
    """
    now = datetime.now(timezone.utc)
    offset_seconds = random.uniform(0, 86400)  # up to 24 h in the past
    ts = now - timedelta(seconds=offset_seconds)
    ms = ts.microsecond // 1000
    return ts.strftime("%Y-%m-%dT%H:%M:%S.") + f"{ms:03d}Z"


# ---------------------------------------------------------------------------
# Session / event generation
# ---------------------------------------------------------------------------

def pick_device():
    return random.choices(DEVICE_TYPES, weights=DEVICE_WEIGHTS, k=1)[0]


def generate_session_events(restaurant_id, session_id, device_type):
    """
    Simulate a user session for one restaurant.

    The funnel:
      view  -> click (60% chance)
            -> add_to_cart (40% of clicks)
            -> order (50% of add_to_carts)

    A session may browse (view) multiple items; the funnel events
    (click, add_to_cart, order) apply to one chosen item per session.
    """
    events = []

    # How many items does this user browse? (1–5 views)
    items_browsed = random.randint(1, 5)
    browsed_items = random.sample(ALL_ITEMS, k=min(items_browsed, len(ALL_ITEMS)))

    # Emit a "view" event for each browsed item
    for item in browsed_items:
        events.append({
            "event_type": "view",
            "menu_item_id":   item["id"],
            "menu_item_name": item["name"],
            "category":       item["category"],
            "price":          item["price"],
        })

    # The funnel centres on the first browsed item (most-viewed)
    funnel_item = browsed_items[0]

    if random.random() < PROB_CLICK_AFTER_VIEW:
        events.append({
            "event_type": "click",
            "menu_item_id":   funnel_item["id"],
            "menu_item_name": funnel_item["name"],
            "category":       funnel_item["category"],
            "price":          funnel_item["price"],
        })

        if random.random() < PROB_ADD_TO_CART_AFTER_CLICK:
            events.append({
                "event_type": "add_to_cart",
                "menu_item_id":   funnel_item["id"],
                "menu_item_name": funnel_item["name"],
                "category":       funnel_item["category"],
                "price":          funnel_item["price"],
            })

            if random.random() < PROB_ORDER_AFTER_ADD_TO_CART:
                events.append({
                    "event_type": "order",
                    "menu_item_id":   funnel_item["id"],
                    "menu_item_name": funnel_item["name"],
                    "category":       funnel_item["category"],
                    "price":          funnel_item["price"],
                })

    # Attach common fields to every event in this session
    full_events = []
    for ev in events:
        full_events.append({
            "event_id":       str(uuid.uuid4()),
            "restaurant_id":  restaurant_id,
            "session_id":     session_id,
            "timestamp":      random_recent_timestamp(),
            "device_type":    device_type,
            **ev,
        })

    return full_events


def build_event_stream(total_events, num_restaurants):
    """
    Pre-build a list of events up to `total_events`.
    Sessions are generated continuously until the target count is reached.
    """
    restaurants = RESTAURANTS[:num_restaurants]
    events = []

    while len(events) < total_events:
        restaurant = random.choice(restaurants)
        session_id = str(uuid.uuid4())
        device_type = pick_device()
        session_events = generate_session_events(
            restaurant["id"], session_id, device_type
        )
        events.extend(session_events)

    # Trim to exactly total_events
    return events[:total_events]


# ---------------------------------------------------------------------------
# HTTP sending
# ---------------------------------------------------------------------------

def send_event(session, endpoint, api_key, event):
    """
    POST a single event JSON to the endpoint.
    Returns True on success, False on any error.
    """
    headers = {
        "Content-Type": "application/json",
        "x-api-key": api_key,
    }
    try:
        response = session.post(
            endpoint,
            headers=headers,
            data=json.dumps(event),
            timeout=10,
        )
        response.raise_for_status()
        return True
    except requests.exceptions.HTTPError as exc:
        print(f"  [HTTP ERROR] {exc} — event_id={event.get('event_id')}")
        return False
    except requests.exceptions.ConnectionError as exc:
        print(f"  [CONNECTION ERROR] {exc} — event_id={event.get('event_id')}")
        return False
    except requests.exceptions.Timeout:
        print(f"  [TIMEOUT] Request timed out — event_id={event.get('event_id')}")
        return False
    except Exception as exc:
        print(f"  [UNEXPECTED ERROR] {exc} — event_id={event.get('event_id')}")
        return False


# ---------------------------------------------------------------------------
# Summary reporting
# ---------------------------------------------------------------------------

def print_summary(
    total, successful, failed, duration,
    type_counts, restaurant_counts, device_counts
):
    avg_rate = total / duration if duration > 0 else 0.0

    print("\n=== Simulation Complete ===")
    print(f"{'Total Events Sent:':<24}{total:>6}")
    print(f"{'Successful:':<24}{successful:>6}")
    print(f"{'Failed:':<24}{failed:>6}")
    print(f"{'Duration:':<24}{duration:>9.1f}s")
    print(f"{'Avg Rate:':<24}{avg_rate:>8.1f} events/sec")

    print("\nEvents by Type:")
    for event_type in ["view", "click", "add_to_cart", "order"]:
        count = type_counts.get(event_type, 0)
        print(f"  {event_type:<16}{count:>6}")

    print("\nEvents by Restaurant:")
    for rest in RESTAURANTS:
        count = restaurant_counts.get(rest["id"], 0)
        print(f"  {rest['id']:<16}{count:>6}")

    print("\nEvents by Device:")
    for device in DEVICE_TYPES:
        count = device_counts.get(device, 0)
        print(f"  {device:<16}{count:>6}")

    failure_rate = (failed / total * 100) if total > 0 else 0.0
    if failure_rate > 10.0:
        print(
            f"\nWARNING: High failure rate detected ({failure_rate:.1f}%). "
            "Check your endpoint and API key."
        )


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

def main():
    args = parse_args()
    endpoint, api_key = resolve_config(args)

    total_events  = args.events
    rate          = args.rate
    num_restaurants = min(args.restaurants, len(RESTAURANTS))

    sleep_interval = 1.0 / rate if rate > 0 else 0.0

    print(f"Restaurant Analytics Simulator")
    print(f"  Endpoint:    {endpoint}")
    print(f"  Events:      {total_events}")
    print(f"  Rate:        {rate} events/sec")
    print(f"  Restaurants: {num_restaurants}")
    print()
    print("Building event stream...")
    events = build_event_stream(total_events, num_restaurants)
    print(f"  {len(events)} events queued. Starting transmission...\n")

    # Counters
    successful = 0
    failed = 0
    type_counts       = {}
    restaurant_counts = {}
    device_counts     = {}

    start_time = time.time()

    with requests.Session() as http_session:
        for idx, event in enumerate(events, start=1):
            ok = send_event(http_session, endpoint, api_key, event)

            if ok:
                successful += 1
            else:
                failed += 1

            # Tally distributions
            et = event.get("event_type", "unknown")
            ri = event.get("restaurant_id", "unknown")
            dt = event.get("device_type", "unknown")
            type_counts[et]       = type_counts.get(et, 0) + 1
            restaurant_counts[ri] = restaurant_counts.get(ri, 0) + 1
            device_counts[dt]     = device_counts.get(dt, 0) + 1

            # Progress report every 50 events
            if idx % 50 == 0:
                elapsed = time.time() - start_time
                print(f"  Sent {idx}/{total_events} events... "
                      f"({elapsed:.1f}s elapsed, "
                      f"{failed} failures so far)")

            # Rate limiting
            if sleep_interval > 0:
                time.sleep(sleep_interval)

    duration = time.time() - start_time
    print_summary(
        total_events, successful, failed, duration,
        type_counts, restaurant_counts, device_counts
    )


if __name__ == "__main__":
    main()
