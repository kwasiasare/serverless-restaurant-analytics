-- Replace YOUR_DATABASE with your Glue database name (e.g., restaurant_analytics_db)

-- =============================================================================
-- hourly_trends.sql
--
-- Purpose:
--   Produce an event-volume heatmap dataset showing how activity is distributed
--   across hours of the day and days of the week over the last 7 days.
--   The result can be consumed directly by a heatmap visualisation (e.g., in
--   Grafana, QuickSight, or a custom front-end) where X = hour_of_day,
--   Y = day_of_week, and the cell value = event_count.
--
-- Usage:
--   Designed to be run on a schedule (e.g., every hour via EventBridge) and
--   results cached in S3 or a BI tool.
--
-- Output columns:
--   hour_of_day   - Integer 0-23 representing the UTC hour of the event
--   day_of_week   - Full day name (Monday … Sunday) derived from the timestamp
--   day_num       - ISO day number 1 (Monday) – 7 (Sunday), for sort ordering
--   event_type    - One of: view, click, add_to_cart, order
--   event_count   - Number of events in that hour / day / type combination
--
-- Notes:
--   - Timestamps stored in the clickstream table are expected to be ISO-8601
--     strings in UTC (e.g., "2024-03-15T14:32:01.123Z").
--   - Partition columns (year, month, day) are integers derived from the
--     ingestion partition path and are used for cost-efficient partition pruning.
-- =============================================================================

WITH
-- ---------------------------------------------------------------------------
-- date_bounds: materialise the 7-day window boundary once.
-- ---------------------------------------------------------------------------
date_bounds AS (
    SELECT
        date_add('day', -6, CURRENT_DATE) AS window_start,
        CURRENT_DATE                       AS window_end
),

-- ---------------------------------------------------------------------------
-- raw_events: apply partition pruning and parse the timestamp string into a
-- TIMESTAMP value so we can extract temporal components.
-- ---------------------------------------------------------------------------
raw_events AS (
    SELECT
        -- from_iso8601_timestamp correctly parses UTC strings like
        -- "2024-03-15T14:32:01Z" and "2024-03-15T14:32:01.123Z".
        -- parse_datetime() is NOT available in Athena; use this instead.
        from_iso8601_timestamp(timestamp) AS event_ts,
        event_type
    FROM YOUR_DATABASE.clickstream
    WHERE
        -- Coarse partition pruning: VARCHAR partition columns vs VARCHAR constants.
        year  IN (CAST(YEAR(CURRENT_DATE) AS VARCHAR),
                  CAST(YEAR(date_add('day', -6, CURRENT_DATE)) AS VARCHAR))
        AND month IN (LPAD(CAST(MONTH(CURRENT_DATE) AS VARCHAR), 2, '0'),
                      LPAD(CAST(MONTH(date_add('day', -6, CURRENT_DATE)) AS VARCHAR), 2, '0'))
        -- Fine date boundary (runs post-partition-filter):
        AND date_parse(
                year || '-' || month || '-' || LPAD(day, 2, '0'),
                '%Y-%m-%d'
            ) BETWEEN date_add('day', -6, CURRENT_DATE) AND CURRENT_DATE
),

-- ---------------------------------------------------------------------------
-- extracted: pull out the temporal dimensions we need for grouping.
-- ---------------------------------------------------------------------------
extracted AS (
    SELECT
        event_type,

        -- Hour of day: integer 0-23
        HOUR(event_ts)                                    AS hour_of_day,

        -- ISO day-of-week: 1 = Monday, 7 = Sunday (Presto DAY_OF_WEEK)
        DAY_OF_WEEK(event_ts)                             AS day_num,

        -- Human-readable day name for presentation layer
        date_format(event_ts, '%W')                       AS day_of_week

    FROM raw_events
    -- Secondary guard: ensure the event's own timestamp also falls in the window.
    -- This catches any data that landed in a partition outside its logical date.
    WHERE CAST(event_ts AS DATE) BETWEEN (SELECT window_start FROM date_bounds)
                                     AND (SELECT window_end   FROM date_bounds)
)

-- ---------------------------------------------------------------------------
-- Final aggregation: one row per (hour, day, event_type) combination.
-- ---------------------------------------------------------------------------
SELECT
    hour_of_day,
    day_of_week,
    day_num,
    event_type,
    COUNT(*) AS event_count
FROM extracted
GROUP BY
    hour_of_day,
    day_of_week,
    day_num,
    event_type
ORDER BY
    day_num       ASC,   -- Monday → Sunday
    hour_of_day   ASC;   -- 0 → 23
