-- Replace YOUR_DATABASE with your Glue database name (e.g., restaurant_analytics_db)

-- =============================================================================
-- device_breakdown.sql
--
-- Purpose:
--   Show how each restaurant's traffic is distributed across device types
--   (mobile, tablet, kiosk, web) over the last 7 days.  Uses window functions
--   to calculate each device type's share of that restaurant's total traffic,
--   giving operators a quick view of which surfaces drive the most engagement.
--
-- Usage:
--   Feed into a per-restaurant device-mix dashboard or alert if a device type
--   drops unexpectedly (e.g., kiosk going offline).
--
-- Output columns:
--   restaurant_id                  - Identifier of the restaurant
--   device_type                    - One of: mobile, tablet, kiosk, web
--   event_count                    - Total events from this device at this restaurant
--   percentage_of_restaurant_total - Share of this device type within the restaurant
--                                    (0.00 – 100.00, two decimal places)
--   unique_sessions                - COUNT of distinct session_id values for this
--                                    restaurant / device_type pair
--
-- Notes on window functions:
--   SUM(event_count) OVER (PARTITION BY restaurant_id) gives the restaurant's
--   total event count without collapsing rows, allowing per-device percentages
--   to be computed in a single pass.
-- =============================================================================

WITH
-- ---------------------------------------------------------------------------
-- date_bounds: materialise the 7-day window boundary once.
-- ---------------------------------------------------------------------------
date_bounds AS (
    SELECT
        date_add('day', -6, CURRENT_DATE) AS window_start,  -- 7 days inclusive of today
        CURRENT_DATE                       AS window_end
),

-- ---------------------------------------------------------------------------
-- raw_events: partition-pruned base dataset.
-- ---------------------------------------------------------------------------
raw_events AS (
    SELECT
        restaurant_id,
        device_type,
        session_id
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
-- device_agg: one row per (restaurant_id, device_type) with raw counts.
-- ---------------------------------------------------------------------------
device_agg AS (
    SELECT
        restaurant_id,
        device_type,
        COUNT(*)                    AS event_count,
        COUNT(DISTINCT session_id)  AS unique_sessions
    FROM raw_events
    GROUP BY
        restaurant_id,
        device_type
),

-- ---------------------------------------------------------------------------
-- with_percentage: add the restaurant-level total using a window function so
-- we can compute percentage without a self-join.
--
--   SUM(event_count) OVER (PARTITION BY restaurant_id)
--       → running total across ALL device rows for that restaurant,
--         replicated on every row in the partition.
--
-- This means percentage_of_restaurant_total will always sum to ~100 % per
-- restaurant across its device_type rows.
-- ---------------------------------------------------------------------------
with_percentage AS (
    SELECT
        restaurant_id,
        device_type,
        event_count,
        unique_sessions,

        -- Window function: sum all event counts within the same restaurant
        SUM(event_count) OVER (
            PARTITION BY restaurant_id
        )                                                     AS restaurant_total,

        -- Compute percentage share (two decimal places)
        ROUND(
            100.0 * event_count
            / SUM(event_count) OVER (PARTITION BY restaurant_id),
            2
        )                                                     AS percentage_of_restaurant_total

    FROM device_agg
)

-- ---------------------------------------------------------------------------
-- Final result: drop the intermediate restaurant_total helper column.
-- ---------------------------------------------------------------------------
SELECT
    restaurant_id,
    device_type,
    event_count,
    percentage_of_restaurant_total,
    unique_sessions
FROM with_percentage
ORDER BY
    restaurant_id  ASC,
    event_count    DESC;  -- Most active device type listed first per restaurant
