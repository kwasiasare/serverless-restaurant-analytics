# Serverless Restaurant Analytics — Implementation Checklist

## Phase 1: Infrastructure
- [x] Create project directory structure
- [x] Write CloudFormation template (cloudformation/template.yaml)
- [x] Write Lambda ingestor (lambda/ingest/handler.py)
- [x] Write Athena queries (athena/queries/*.sql)
- [x] Write data simulator (scripts/simulator.py)
- [x] Write deploy script (scripts/deploy.sh)
- [x] Write QuickSight setup guide (scripts/quicksight_setup.md)
- [x] Write .env.example
- [x] Write README.md

## Phase 2: Deployment (User Action Required)
- [ ] Run ./scripts/deploy.sh
- [ ] Verify stack deploys with no errors
- [ ] Capture API endpoint and API key from stack outputs
- [ ] Update .env with real values

## Phase 3: Testing
- [ ] Run simulator: python scripts/simulator.py --events 500
- [ ] Verify 200 responses from API
- [ ] Test 400 response with malformed event
- [ ] Wait 60-90s, verify JSON files appear in S3

## Phase 4: Data Pipeline
- [ ] Trigger Glue Crawler manually in AWS Console
- [ ] Verify clickstream table appears in Glue Data Catalog
- [ ] Run popular_items.sql in Athena console → returns rows
- [ ] Run all 4 Athena queries successfully

## Phase 5: Visualization
- [ ] Follow scripts/quicksight_setup.md
- [ ] Create Athena data source in QuickSight
- [ ] Build 4 dashboard analyses
- [ ] Publish dashboard

## Phase 1b: Peer Review Fixes (applied before deployment)
- [x] Peer review pass using independent critique subagent
- [x] CFN Bug: S3DestinationConfiguration → ExtendedS3DestinationConfiguration + DynamicPartitioningConfiguration
- [x] CFN Bug: CAPABILITY_IAM → CAPABILITY_NAMED_IAM (named roles require this)
- [x] CFN Bug: CompressionFormat UNCOMPRESSED → GZIP
- [x] CFN Warning: Add ApiGatewayAccessLogGroup (was missing, ProdStage referenced it)
- [x] CFN Warning: Add RecrawlPolicy: CRAWL_NEW_FOLDERS_ONLY to GlueCrawler
- [x] CFN Warning: ProjectName default changed to restaurant_analytics (underscores prevent Athena quoting issues)
- [x] SQL Bug: hourly_trends.sql parse_datetime() → from_iso8601_timestamp() (parse_datetime not in Athena)
- [x] SQL Bug: All 4 queries partition pruning fixed (year IN / month IN + date_parse fine filter)
- [x] Simulator Bug: timestamp format now includes milliseconds (format mismatch with Athena was latent)
- [x] Simulator Fix: docstring endpoint URL corrected (/prod/ingest → /prod/events)
- [x] deploy.sh: ProjectName parameter override converts hyphens → underscores (${STACK_NAME//-/_})

## Review
- Architecture follows least-privilege IAM principles
- Hive-style S3 partitioning enables partition pruning in Athena (now correctly implemented)
- Firehose ExtendedS3DestinationConfiguration required for dynamic partitioning prefix expressions
- GZIP compression on Firehose reduces S3 storage and Athena scan costs ~5-10x
- Glue RecrawlPolicy: CRAWL_NEW_FOLDERS_ONLY prevents redundant re-cataloguing at hourly cadence
- API key auth is simple and sufficient for ingestion endpoint
- QuickSight setup is manual (CFN coverage is incomplete)
- ProjectName uses underscores to avoid Athena backtick-quoting requirement on Glue database names
