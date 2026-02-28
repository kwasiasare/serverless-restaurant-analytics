# QuickSight Dashboard Setup Guide

Amazon QuickSight cannot be fully provisioned via CloudFormation, so this guide walks you through the manual steps to connect QuickSight to your Athena data and build the four analytics dashboards.

---

## Prerequisites

Before starting, ensure:

1. **Stack is deployed** — `./scripts/deploy.sh` completed successfully
2. **Data is in S3** — at least one Firehose flush has occurred (run the simulator and wait 60–90s)
3. **Glue Crawler has run** — the `clickstream` table exists in your Glue database
4. **Athena queries work** — run `athena/queries/popular_items.sql` in the Athena console and verify it returns rows
5. **QuickSight account** — Enterprise edition required for row-level security and scheduled refresh; Standard edition works for basic dashboards

---

## Step 1: Grant QuickSight Access to AWS Resources

QuickSight runs under its own IAM service role and needs explicit access to your S3 buckets and Athena workgroup.

### 1a. QuickSight → Manage QuickSight → Security & Permissions

1. In the AWS Console, open **QuickSight** (top-right user menu → **Manage QuickSight**)
2. Click **Security & permissions**
3. Under **QuickSight access to AWS services**, click **Manage**
4. Enable:
   - **Amazon Athena** — checked
   - **Amazon S3** — click **Select S3 buckets**, then add:
     - `restaurant-analytics-raw-data-{your-account-id}`
     - `restaurant-analytics-athena-results-{your-account-id}`
5. Click **Save**

### 1b. Verify Athena Workgroup Access

In the **Athena console** → **Workgroups**, select `restaurant-analytics-workgroup` and confirm:
- Output location is set to `s3://restaurant-analytics-athena-results-{account-id}/`
- The QuickSight IAM role has `athena:GetWorkGroup`, `athena:StartQueryExecution`, `athena:GetQueryResults` on the workgroup ARN

---

## Step 2: Create the Athena Data Source

1. In QuickSight, click **Datasets** in the left nav → **New dataset**
2. Select **Athena** as the data source type
3. Fill in:
   - **Data source name:** `restaurant-clickstream-athena`
   - **Athena workgroup:** `restaurant-analytics-workgroup`
4. Click **Validate connection** — you should see a green checkmark
5. Click **Create data source**

---

## Step 3: Create the Primary Dataset

1. After creating the data source, QuickSight asks you to choose a table:
   - **Catalog:** `AwsDataCatalog`
   - **Database:** `restaurant_analytics_db` (or your `ProjectName_db`)
   - **Table:** `clickstream`
2. Click **Select**
3. Choose **Direct Query** (recommended for near-real-time data — avoids SPICE import lag)
   > **Note:** SPICE gives faster dashboard renders but requires scheduled refresh. For this pipeline where data arrives continuously, Direct Query is more accurate.
4. Click **Visualize** to proceed to analysis, or **Edit/Preview data** first to inspect columns

### Optional: Add Calculated Fields

In the dataset editor, add these calculated fields for richer analysis:

| Field Name | Formula | Description |
|---|---|---|
| `is_order` | `ifelse(event_type = "order", 1, 0)` | Binary flag for orders |
| `is_view` | `ifelse(event_type = "view", 1, 0)` | Binary flag for views |
| `hour_of_day` | `extract("HH", parseDate(timestamp, "yyyy-MM-dd'T'HH:mm:ss'Z'"))` | Hour 0-23 |
| `day_of_week` | `extract("E", parseDate(timestamp, "yyyy-MM-dd'T'HH:mm:ss'Z'"))` | Mon-Sun |
| `revenue` | `ifelse(event_type = "order", price, 0)` | Revenue (orders only) |

---

## Step 4: Analysis 1 — Popular Items Dashboard

1. Click **New analysis** → select the `restaurant-clickstream-athena` dataset → **Create analysis**
2. **Visual 1 — Top Items Bar Chart:**
   - Visual type: **Horizontal bar chart**
   - Y-axis: `menu_item_name`
   - Value: `COUNT(event_id)` (aggregation: Count)
   - Color: `category`
   - Add filter: `event_type` IN `[order, add_to_cart]`
   - Sort: descending by count
   - Title: **"Top Menu Items by Interactions"**
3. **Visual 2 — Revenue by Item:**
   - Visual type: **Horizontal bar chart**
   - Y-axis: `menu_item_name`
   - Value: `SUM(revenue)` (using calculated field)
   - Filter: `event_type` = `order`
   - Title: **"Revenue by Menu Item"**
4. Add a **date range filter** at the analysis level: `timestamp` → last 7 days

---

## Step 5: Analysis 2 — Hourly Heatmap

For this analysis, use a **custom SQL dataset** based on `hourly_trends.sql`:

1. **Datasets** → **New dataset** → **Athena** → select same data source
2. Click **Use custom SQL** instead of picking a table
3. Paste the contents of `athena/queries/hourly_trends.sql` (replace `YOUR_DATABASE` with your actual database name)
4. Name it: `hourly-trends-dataset`
5. Back in the analysis, create a new visual:
   - Visual type: **Heat map**
   - Rows: `hour_of_day`
   - Columns: `day_of_week`
   - Values: `SUM(event_count)`
   - Color gradient: low (white/light blue) to high (dark blue/purple)
   - Title: **"Event Volume Heatmap — Hour x Day"**

---

## Step 6: Analysis 3 — Category Analysis

1. Create a new analysis using the primary `clickstream` dataset
2. **Visual 1 — Category Donut:**
   - Visual type: **Donut chart**
   - Group/color: `category`
   - Value: `COUNT(event_id)`
   - Title: **"Events by Category"**
3. **Visual 2 — Category x Event Type Stacked Bar:**
   - Visual type: **Stacked bar chart**
   - X-axis: `category`
   - Value: `COUNT(event_id)`
   - Group/color: `event_type`
   - Title: **"Category Breakdown by Event Type"**
4. **Visual 3 — Revenue KPI:**
   - Visual type: **KPI**
   - Value: `SUM(revenue)`
   - Title: **"Total Revenue"**
   - Comparison: period-over-period (last 7 days vs. prior 7 days)

---

## Step 7: Analysis 4 — Device Breakdown

1. Create a new analysis using the primary `clickstream` dataset
2. **Visual 1 — Device Distribution Pie:**
   - Visual type: **Pie chart**
   - Group/color: `device_type`
   - Value: `COUNT(event_id)`
   - Title: **"Events by Device Type"**
3. **Visual 2 — Restaurant x Device Pivot Table:**
   - Visual type: **Pivot table**
   - Rows: `restaurant_id`
   - Columns: `device_type`
   - Values: `COUNT(event_id)` and `COUNT_DISTINCT(session_id)`
   - Title: **"Device Usage per Restaurant"**
4. **Visual 3 — Device Trends Over Time:**
   - Visual type: **Line chart**
   - X-axis: `timestamp` (aggregated by Day)
   - Value: `COUNT(event_id)`
   - Color: `device_type`
   - Title: **"Device Trends Over Time"**

---

## Step 8: Publish the Dashboard

1. In any analysis, click **Share** → **Publish dashboard**
2. Name: `Restaurant Analytics Dashboard`
3. Set **refresh frequency**:
   - For Direct Query: no import needed — data is always live
   - For SPICE datasets: set to **hourly** to match Glue Crawler schedule
4. **Share with users** — add users or groups who should view the dashboard
5. Click **Publish dashboard**

---

## Troubleshooting

| Problem | Likely Cause | Fix |
|---|---|---|
| "Validation failed" on Athena data source | QuickSight not authorized for Athena/S3 | Redo Step 1 — check both S3 buckets are selected |
| Empty dataset / no rows | Glue Crawler has not run, or Firehose has not flushed | Run simulator, wait 90s, manually trigger crawler in AWS Console |
| `HIVE_PARTITION_SCHEMA_MISMATCH` | Glue table schema out of date | Re-run Glue Crawler to update table definition |
| `Insufficient Lake Formation permissions` | QuickSight role lacks LF permissions | In Lake Formation console, grant SELECT on `clickstream` table to the QuickSight role |
| Heatmap shows empty cells | No data for those hour/day combinations | Normal for new deployments — run simulator with more events |
| Dashboard loads slowly | Direct Query scanning too much data | Add partition filters (year/month/day) to dataset, or switch to SPICE with scheduled refresh |
| `Athena query timed out` | Query scanning exceeds 100 MB workgroup limit | Refine dataset filters to use partition columns for partition pruning |

---

## QuickSight IAM Role ARN (for reference)

QuickSight's service role ARN follows this pattern:
```
arn:aws:iam::{account-id}:role/aws-quicksight-service-role-v0
```

If you need to grant this role explicit S3 or Athena access via IAM (instead of the QuickSight UI), use this ARN in your resource policies.
