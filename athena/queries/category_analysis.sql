-- Replace YOUR_DATABASE with your Glue database name (e.g., restaurant_analytics_db)

-- =============================================================================
-- category_analysis.sql
--
-- Purpose:
--   Analyse menu category performance over the last 30 days, broken down by
--   event type.  Also computes a per-category conversion rate (orders / views)
--   to surface which categories are best at converting browsers into buyers.
--
-- Usage:
--   Suitable for a category-level performance dashboard.  Run daily and cache
--   results in S3 or a BI layer.
--
-- Output columns:
--   category             - Menu category (Burgers, Pizza, Salads, Drinks, Desserts)
--   event_type           - One of: view, click, add_to_cart, order
--   event_count          - Number of events for this category / event_type pair
--   unique_items         - Distinct menu_item_id values seen in this group
--   total_revenue        - SUM of price (only meaningful for event_type = 'order')
--   avg_price            - AVG of price across all events in the group
--   conversion_rate      - orders / views for the category (NULL if no views)
--                          Expressed as a decimal (e.g., 0.12 = 12 %)
-- =============================================================================

WITH
-- ---------------------------------------------------------------------------
-- date_bounds: materialise the 30-day window boundary.
-- ---------------------------------------------------------------------------
date_bounds AS (
    SELECT
        date_add('day', -29, CURRENT_DATE) AS window_start,  -- 30 days inclusive of today
        CURRENT_DATE                        AS window_end
),

-- ---------------------------------------------------------------------------
-- raw_events: partition-pruned base dataset for the 30-day window.
-- ---------------------------------------------------------------------------
raw_events AS (
    SELECT
        category,
        event_type,
        menu_item_id,
        price
    FROM YOUR_DATABASE.clickstream
    WHERE
        -- Coarse partition pruning: VARCHAR partition columns vs VARCHAR constants.
        year  IN (CAST(YEAR(CURRENT_DATE) AS VARCHAR),
                  CAST(YEAR(date_add('day', -29, CURRENT_DATE)) AS VARCHAR))
        AND month IN (LPAD(CAST(MONTH(CURRENT_DATE) AS VARCHAR), 2, '0'),
                      LPAD(CAST(MONTH(date_add('day', -29, CURRENT_DATE)) AS VARCHAR), 2, '0'))
        -- Fine date boundary (runs post-partition-filter):
        AND date_parse(
                year || '-' || month || '-' || LPAD(day, 2, '0'),
                '%Y-%m-%d'
            ) BETWEEN date_add('day', -29, CURRENT_DATE) AND CURRENT_DATE
),

-- ---------------------------------------------------------------------------
-- category_event_stats: core aggregation by category and event type.
-- ---------------------------------------------------------------------------
category_event_stats AS (
    SELECT
        category,
        event_type,
        COUNT(*)                       AS event_count,
        COUNT(DISTINCT menu_item_id)   AS unique_items,
        COALESCE(SUM(price), 0)        AS total_revenue,
        ROUND(AVG(price), 2)           AS avg_price
    FROM raw_events
    GROUP BY
        category,
        event_type
),

-- ---------------------------------------------------------------------------
-- category_view_counts: isolate view counts per category so we can compute
-- conversion_rate = orders / views in the final join.
-- Using a dedicated CTE keeps the logic readable and avoids a self-join on
-- the larger raw_events table.
-- ---------------------------------------------------------------------------
category_view_counts AS (
    SELECT
        category,
        COUNT(*) AS view_count
    FROM raw_events
    WHERE event_type = 'view'
    GROUP BY category
),

-- ---------------------------------------------------------------------------
-- category_order_counts: isolate order counts per category for the same reason.
-- ---------------------------------------------------------------------------
category_order_counts AS (
    SELECT
        category,
        COUNT(*) AS order_count
    FROM raw_events
    WHERE event_type = 'order'
    GROUP BY category
),

-- ---------------------------------------------------------------------------
-- conversion_rates: one row per category with the funnel conversion metric.
-- ---------------------------------------------------------------------------
conversion_rates AS (
    SELECT
        v.category,
        -- NULLIF guards against zero-view categories producing a divide-by-zero.
        ROUND(
            CAST(COALESCE(o.order_count, 0) AS DOUBLE)
            / NULLIF(CAST(v.view_count AS DOUBLE), 0),
            4
        ) AS conversion_rate
    FROM category_view_counts v
    LEFT JOIN category_order_counts o
        ON v.category = o.category
)

-- ---------------------------------------------------------------------------
-- Final result: join event stats with the per-category conversion rate.
-- ---------------------------------------------------------------------------
SELECT
    ces.category,
    ces.event_type,
    ces.event_count,
    ces.unique_items,
    ROUND(ces.total_revenue, 2)    AS total_revenue,
    ces.avg_price,
    -- Conversion rate is the same for all event_type rows within a category;
    -- it represents the overall funnel health of that category.
    cr.conversion_rate
FROM category_event_stats ces
LEFT JOIN conversion_rates cr
    ON ces.category = cr.category
ORDER BY
    ces.category   ASC,
    ces.event_type ASC;
