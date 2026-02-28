# Serverless Restaurant Analytics Platform

A production-ready, serverless data analytics pipeline for restaurant menu clickstream events, built on AWS. Captures events → processes through Kinesis → stores in S3 → queries with Athena → visualizes in QuickSight.

---

## Architecture

```
Restaurant Frontend / Simulator
        │  POST /events (JSON)
        ▼
  API Gateway (REST)  ←── API Key Auth
        │
        ▼
  Lambda: Ingestor (Python 3.12)
  • Validates schema
  • Enriches with server timestamp
  • Forwards to Firehose
        │
        ▼
  Kinesis Data Firehose
  • Buffer: 60s / 5MB
  • Hive-partitioned S3 output
        │
        ▼
  S3 Raw Data Lake
  clickstream/year=.../month=.../day=.../hour=...
        │
        ▼
  Glue Crawler (hourly)
  • Auto-discovers schema
  • Populates Glue Catalog
        │
        ▼
  Athena Workgroup
  • Partition-pruned SQL queries
  • 100MB scan limit per query
        │
        ▼
  QuickSight Dashboards
  • Popular items, Category trends
  • Hourly heatmap, Device breakdown
```

---

## Tech Stack

### AWS Services

| Service | Role |
|---|---|
| **API Gateway** | REST API endpoint with API key authentication |
| **Lambda** | Event ingestion, schema validation, Firehose forwarding |
| **Kinesis Data Firehose** | Buffered delivery to S3 with Hive-style partitioning |
| **S3** | Raw data lake storage, partitioned by year/month/day/hour |
| **Glue** | Crawler for schema discovery; Data Catalog as metastore |
| **Athena** | Serverless SQL queries over S3 data via Glue Catalog |
| **QuickSight** | Business intelligence dashboards and visualizations |
| **CloudWatch** | Lambda logs, metrics, and alarms |
| **IAM** | Least-privilege roles for each service |
| **CloudFormation** | Infrastructure-as-code for the full stack |

---

## Project Structure

```
serverless-restaurant-analytics/
├── cloudformation/
│   └── template.yaml          # Full CFN stack definition
├── lambda/
│   └── ingest/
│       └── handler.py         # Lambda ingestor function
├── athena/
│   └── queries/
│       ├── popular_items.sql       # Top viewed menu items
│       ├── category_trends.sql     # Views by category over time
│       ├── hourly_heatmap.sql      # Traffic by hour of day
│       └── device_breakdown.sql    # Sessions by device type
├── scripts/
│   ├── simulator.py           # Synthetic event generator
│   ├── deploy.sh              # One-command stack deployment
│   └── quicksight_setup.md    # Manual QuickSight setup guide
├── tasks/
│   ├── todo.md                # Implementation checklist
│   └── lessons.md             # Architecture decisions & lessons
├── .env.example               # Environment variable template
└── README.md                  # This file
```

---

## Prerequisites

- **AWS CLI** configured with appropriate permissions (`aws configure`)
- **Python 3.8+** for the event simulator
- **pip packages** for the simulator:
  ```bash
  pip install requests python-dotenv
  ```
- **AWS account** with QuickSight Enterprise subscription (required for Athena data source integration and dashboard sharing)
- **IAM permissions** sufficient to create: Lambda, API Gateway, Kinesis Firehose, S3, Glue, Athena, IAM roles, and CloudFormation stacks

---

## Quick Start

1. **Clone or download the project** into your working directory.

2. **Deploy the CloudFormation stack:**
   ```bash
   cd scripts
   chmod +x deploy.sh
   ./deploy.sh --stack-name restaurant-analytics --region us-east-1
   ```
   The script packages the Lambda function, uploads it to S3, and deploys the full stack. On completion it prints the API endpoint and instructions for retrieving the API key.

3. **Configure your environment:**
   ```bash
   cp .env.example .env
   ```
   Open `.env` and fill in the `API_ENDPOINT` and `API_KEY` values printed by the deploy script.

4. **Run the event simulator:**
   ```bash
   python scripts/simulator.py --events 500
   ```
   This sends 500 synthetic clickstream events to the API and prints a summary of HTTP response codes.

5. **Wait for Firehose to flush.** Firehose buffers for 60 seconds (or 5 MB). After 60–90 seconds, navigate to the S3 bucket in the AWS Console and verify that JSON files have appeared under the `clickstream/` prefix.

6. **Trigger the Glue Crawler:**
   - Open the AWS Console → Glue → Crawlers
   - Select the `restaurant-clickstream-crawler` and click **Run**
   - Wait for the crawler to finish (status: `Ready`)
   - Confirm the `clickstream` table appears in the Glue Data Catalog under the `restaurant_analytics` database

7. **Run Athena queries:**
   - Open the AWS Console → Athena → Query Editor
   - Select the `restaurant-analytics` workgroup and the `restaurant_analytics` database
   - Paste and run any query from `athena/queries/`

8. **Set up QuickSight dashboards:**
   - Follow the step-by-step guide in `scripts/quicksight_setup.md`

---

## Event Schema

Each event POSTed to the API must be a JSON object conforming to the following schema:

```json
{
  "event_id":    "string  — UUID v4, client-generated unique identifier",
  "event_type":  "string  — one of: view_item, add_to_cart, remove_from_cart, purchase",
  "timestamp":   "string  — ISO 8601 UTC, e.g. 2024-01-15T14:30:00Z",
  "session_id":  "string  — UUID v4, groups events within a browser session",
  "user_id":     "string  — anonymous user identifier (may be UUID or hashed)",
  "restaurant_id":"string — identifier for the restaurant location",
  "item_id":     "string  — menu item identifier",
  "item_name":   "string  — human-readable menu item name",
  "category":    "string  — menu category, e.g. Appetizers, Mains, Desserts, Drinks",
  "price":       "number  — item price in USD (decimal)",
  "device_type": "string  — one of: mobile, tablet, desktop",
  "platform":    "string  — one of: ios, android, web"
}
```

The Lambda ingestor enriches each event with a server-side `ingested_at` timestamp (ISO 8601 UTC) before forwarding to Firehose. This field is appended to every record stored in S3 and queryable in Athena.

**Validation:** The API returns `400 Bad Request` with an error message for any event missing required fields or containing values outside the allowed enumerations. Only valid events are forwarded to Firehose, ensuring data lake integrity.

---

## Athena Queries

All queries are located in `athena/queries/` and target the `clickstream` table in the `restaurant_analytics` Glue database. Each query uses partition pruning on `year`, `month`, `day`, and `hour` columns to minimize data scanned and cost.

| Query File | Description |
|---|---|
| `popular_items.sql` | Ranks menu items by total view count. Useful for identifying which dishes attract the most attention before purchase decisions. |
| `category_trends.sql` | Aggregates view events by menu category (e.g., Appetizers, Mains, Desserts) grouped by date, revealing which categories trend up or down over time. |
| `hourly_heatmap.sql` | Counts events by hour of day across the full dataset, producing a 24-point distribution suitable for rendering a traffic heatmap in QuickSight. |
| `device_breakdown.sql` | Breaks down session counts and view events by device type (mobile, tablet, desktop) and platform (ios, android, web), informing frontend optimization priorities. |

---

## Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| **Ingestion pattern** | API Gateway + Lambda + Firehose | Fully managed, scales to zero, no servers to maintain |
| **Buffering** | Firehose 60s / 5MB | Avoids S3 small-file problem while keeping latency under 2 minutes |
| **S3 partitioning** | Hive-style `year=/month=/day=/hour=` | Athena partition pruning dramatically reduces bytes scanned and cost |
| **Schema management** | Glue Crawler (hourly) | Auto-discovers new columns; decouples schema evolution from pipeline code |
| **Query engine** | Athena | Serverless, pay-per-query, native Glue Catalog integration |
| **Auth** | API key (API Gateway) | Simple and sufficient for a single ingestion endpoint; no user identity needed |
| **Scan limit** | Athena 100MB per query | Guards against accidental full-table scans burning unexpected cost |
| **Logging** | Structured JSON in Lambda | Enables CloudWatch Logs Insights queries without a separate log parser |
| **IaC** | CloudFormation | Native AWS, no additional tooling (Terraform/CDK) required |
| **QuickSight** | Manual setup | CFN support for QuickSight resources is incomplete; a guide is more reliable |

---

## Verification Checklist

Use this checklist after deployment to confirm end-to-end functionality:

```
- [ ] Stack deploys successfully
- [ ] API returns 200 for valid events
- [ ] API returns 400 for malformed events
- [ ] Files appear in S3 after 60-90s
- [ ] Glue Crawler discovers table schema
- [ ] Athena queries return rows
- [ ] QuickSight dashboard renders data
```

---

## Cost Estimate

Approximate monthly cost for moderate traffic (10,000 events/day, ~300,000 events/month):

| Service | Estimate | Notes |
|---|---|---|
| **Lambda** | ~$0 | Covered by AWS free tier (1M requests/month free) |
| **Kinesis Firehose** | ~$0.029/GB ingested | At ~1KB/event, 300k events = ~$0.009/month |
| **S3** | ~$0.023/GB/month | Storage cost depends on retention policy |
| **Glue Crawler** | ~$13/month | $0.44/DPU-hour, 1 DPU, running 1 hour/day |
| **Athena** | $5/TB scanned | Partition pruning keeps scans small; expect cents per day for typical queries |
| **QuickSight** | $18–24/user/month | Standard tier ($18) or Enterprise tier ($24, required for Athena) |

**Total estimated cost:** $15–40/month depending on QuickSight tier and query volume. At high event volumes (millions/day), Firehose and S3 costs scale linearly while Lambda remains near free tier.

---

## Troubleshooting

**No files in S3 after 90 seconds**
- Confirm the simulator printed HTTP 200 responses
- Check Lambda logs in CloudWatch Logs (`/aws/lambda/restaurant-ingestor`) for errors
- Verify the Firehose delivery stream is in `ACTIVE` state in the AWS Console

**Athena query returns "Table not found"**
- Run the Glue Crawler and wait for it to reach `Ready` status
- Confirm the database name in the query matches the Glue catalog (`restaurant_analytics`)
- Ensure the Athena workgroup is set to `restaurant-analytics`

**API returns 403**
- Confirm the `x-api-key` header is set in the simulator `.env` file
- Verify the API key is associated with the correct usage plan in API Gateway

**CloudFormation deploy fails with `ROLLBACK_COMPLETE`**
- Check the Events tab of the stack in the CloudFormation console for the specific resource that failed
- Common cause: S3 bucket name conflict (bucket names are globally unique); the template uses `AWS::AccountId` to avoid this

**QuickSight cannot connect to Athena**
- Ensure QuickSight has been granted access to the S3 results bucket and the raw data bucket in QuickSight → Manage QuickSight → Security & permissions
- Enterprise subscription is required for Athena data sources
