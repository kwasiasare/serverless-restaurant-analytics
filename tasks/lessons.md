# Lessons Learned

## Architecture Decisions
- QuickSight cannot be fully automated via CloudFormation — always provide a manual setup guide
- **Firehose dynamic partitioning REQUIRES `ExtendedS3DestinationConfiguration`** — `S3DestinationConfiguration` treats `!{timestamp:...}` expressions as literal strings. Data lands in paths like `clickstream/year=!{timestamp:yyyy}/...` literally, breaking the entire pipeline silently.
- S3 bucket names must be globally unique — always include AWS::AccountId in bucket names
- Glue Crawlers need AWSGlueServiceRole managed policy plus explicit S3 read permissions
- Lambda inline code in CFN is useful for stubs, but deploy.sh should overwrite with real code
- **Glue Crawler RecrawlPolicy: CRAWL_NEW_FOLDERS_ONLY** — without this, the crawler re-reads all existing S3 prefixes on every run, wasting DPU-hours at hourly cadence
- **Firehose GZIP compression** — UNCOMPRESSED data in S3 means Athena scans raw bytes. GZIP gives 5-10x storage and cost reduction with no schema changes needed (Athena reads GZIP natively)
- **AWS::ApiGateway::Account** is a singleton per account/region — every CloudFormation stack that creates this resource will overwrite the CloudWatch role for ALL API Gateways in the account

## Development Patterns
- Use structured JSON logging in Lambda for CloudWatch Insights compatibility
- Initialize boto3 clients outside the handler function for connection reuse across warm invocations
- Always validate at the API boundary — reject bad events with 400, never let them poison the data lake
- Add `ingested_at` server-side timestamp to detect clock skew in client timestamps
- **Simulator timestamps must include milliseconds** — if Athena queries use `date_parse` with `.%f` format or `from_iso8601_timestamp`, timestamps without milliseconds cause silent NULL values or parse failures

## Athena SQL Anti-Patterns
- **Anti-Pattern**: `DATE(CONCAT(CAST(year AS VARCHAR), '-', ...)) BETWEEN start AND end` — wrapping partition columns in ANY function (CAST, CONCAT, DATE) disables Athena partition elimination → full table scan every time
- **Heuristic**: For Athena partition pruning, always use direct column comparisons: `year IN (Y1, Y2) AND month IN (M1, M2)` for the coarse filter, then `date_parse(...) BETWEEN ...` as a fine post-filter. The IN predicates are pushed to the partition index; the fine filter runs only on the surviving data.
- **Anti-Pattern**: Using `parse_datetime()` in Athena — this is a Presto function not available in Athena. Use `from_iso8601_timestamp(col)` for ISO-8601 strings or `date_parse(col, '%Y-%m-%dT%H:%i:%s.%fZ')` for fixed formats.

## Deployment Notes
- API key values are NOT returned directly in CFN outputs — must use `aws apigateway get-api-keys --include-values`
- **CloudFormation CAPABILITY_NAMED_IAM is required** when IAM roles have explicit `RoleName` properties — `CAPABILITY_IAM` alone causes `InsufficientCapabilitiesException` and the stack never deploys
- Athena workgroup BytesScannedCutoffPerQuery prevents runaway queries from burning cost
- **Glue database names must not contain hyphens** if you want to query them in Athena without backtick quoting — use underscores in the ProjectName/resource prefix passed to the Glue database Name property
