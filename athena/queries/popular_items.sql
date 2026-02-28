-- Replace YOUR_DATABASE with your Glue database name (e.g., restaurant_analytics_db)

-- =============================================================================
-- popular_items.sql
--
-- Purpose:
--   Identify the top 20 menu items ranked by total interaction count over the
--   last 7 days. Breaks interactions down by type (view, click, add_to_cart,
--   order) and calculates total revenue generated from completed orders.
--
-- Usage:
--   Run in the Athena query editor or via the AWS SDK / CLI.
--   The partition filter (year / month / day) ensures only the relevant S3
--   prefixes are scanned, keeping cost and latency low.
--
-- Output columns:
--   menu_item_name       - Display name of the menu item
--   category             - Menu category (Burgers, Pizza, Salads, Drinks, Desserts)
--   total_interactions   - Sum of all event types for this item
--   views                - COUNT of view events
--   clicks               - COUNT of click events
--   add_to_cart_count    - COUNT of add_to_cart events
--   orders               - COUNT of order events
--   total_revenue        - SUM of price for order events only
-- =============================================================================

WITH
-- ---------------------------------------------------------------------------
-- date_bounds: compute the inclusive start date for the 7-day window.
-- Athena / Presto does not support CURRENT_DATE directly in all partition
-- filters, so we materialise the boundary here once.
-- ---------------------------------------------------------------------------
date_bounds AS (
    SELECT
        date_add('day', -6, CURRENT_DATE) AS window_start,  -- 7 days inclusive of today
        CURRENT_DATE                       AS window_end
),

-- ---------------------------------------------------------------------------
-- raw_events: pull only the partitions we need.
--
-- Partition pruning strategy:
--   1. year IN (...)  and  month IN (...)  — Athena pushes these simple IN
--      predicates directly to the Hive partition index, eliminating whole
--      year/month S3 prefixes before reading any data.  A 7-day window
--      spans at most 2 calendar months, so this reduces the scan to
--      1-2 months of data.
--   2. date_parse(...) BETWEEN ... — fine filter runs only on the rows
--      that survived the coarse partition filter, ensuring we don't include
--      days that fall outside the exact 7-day boundary.
--
-- NOTE: Wrapping partition columns in functions (e.g., DATE(CONCAT(...)))
-- disables Athena partition elimination — every partition is scanned.
-- The year/month IN pattern is the correct approach.
-- ---------------------------------------------------------------------------
raw_events AS (
    SELECT
        menu_item_id,
        menu_item_name,
        category,
        event_type,
        price
    FROM YOUR_DATABASE.clickstream
    WHERE
        -- Coarse partition pruning (pushed to partition index):
        year  IN (YEAR(CURRENT_DATE), YEAR(date_add('day', -6, CURRENT_DATE)))
        AND month IN (MONTH(CURRENT_DATE), MONTH(date_add('day', -6, CURRENT_DATE)))
        -- Fine date boundary (runs post-partition-filter):
        AND date_parse(
                CAST(year AS VARCHAR) || '-' ||
                LPAD(CAST(month AS VARCHAR), 2, '0') || '-' ||
                LPAD(CAST(day AS VARCHAR), 2, '0'),
                '%Y-%m-%d'
            ) BETWEEN date_add('day', -6, CURRENT_DATE) AND CURRENT_DATE
),

-- ---------------------------------------------------------------------------
-- item_stats: aggregate per menu item
-- ---------------------------------------------------------------------------
item_stats AS (
    SELECT
        menu_item_id,
        menu_item_name,
        category,

        -- Total interactions across all event types
        COUNT(*)                                                         AS total_interactions,

        -- Individual event type counts
        COUNT(CASE WHEN event_type = 'view'         THEN 1 END)         AS views,
        COUNT(CASE WHEN event_type = 'click'        THEN 1 END)         AS clicks,
        COUNT(CASE WHEN event_type = 'add_to_cart'  THEN 1 END)         AS add_to_cart_count,
        COUNT(CASE WHEN event_type = 'order'        THEN 1 END)         AS orders,

        -- Revenue: only count the price when an order was completed
        COALESCE(
            SUM(CASE WHEN event_type = 'order' THEN price ELSE 0 END),
            0
        )                                                                AS total_revenue

    FROM raw_events
    GROUP BY
        menu_item_id,
        menu_item_name,
        category
)

-- ---------------------------------------------------------------------------
-- Final result: top 20 items by total interaction volume
-- ---------------------------------------------------------------------------
SELECT
    menu_item_name,
    category,
    total_interactions,
    views,
    clicks,
    add_to_cart_count,
    orders,
    ROUND(total_revenue, 2) AS total_revenue
FROM item_stats
ORDER BY total_interactions DESC
LIMIT 20;
