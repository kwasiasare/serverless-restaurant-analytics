#!/bin/bash
# =============================================================================
# deploy.sh — Restaurant Analytics Platform — CloudFormation Deploy Script
# =============================================================================
# Usage:
#   ./deploy.sh [--stack-name NAME] [--region REGION] [--profile PROFILE]
#
# Defaults:
#   --stack-name   restaurant-analytics
#   --region       us-east-1
#   --profile      (uses default AWS credential chain if omitted)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# ANSI color helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}${BOLD}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}${BOLD}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}${BOLD}[ERROR]${RESET} $*" >&2; }
header()  { echo -e "\n${CYAN}${BOLD}══════════════════════════════════════════${RESET}"; \
            echo -e "${CYAN}${BOLD}  $*${RESET}"; \
            echo -e "${CYAN}${BOLD}══════════════════════════════════════════${RESET}"; }

# ---------------------------------------------------------------------------
# Default values
# ---------------------------------------------------------------------------
STACK_NAME="restaurant-analytics"
REGION="us-east-1"
PROFILE=""

# ---------------------------------------------------------------------------
# Parse CLI arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --stack-name)
            STACK_NAME="$2"
            shift 2
            ;;
        --region)
            REGION="$2"
            shift 2
            ;;
        --profile)
            PROFILE="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--stack-name NAME] [--region REGION] [--profile PROFILE]"
            exit 0
            ;;
        *)
            error "Unknown argument: $1"
            echo "Usage: $0 [--stack-name NAME] [--region REGION] [--profile PROFILE]"
            exit 1
            ;;
    esac
done

# Build the AWS CLI profile flag (empty string if no profile supplied)
AWS_PROFILE_FLAG=""
if [[ -n "$PROFILE" ]]; then
    AWS_PROFILE_FLAG="--profile $PROFILE"
fi

# Convenience wrapper so every aws call uses the right region + profile
aws_cmd() {
    # shellcheck disable=SC2086
    aws $AWS_PROFILE_FLAG --region "$REGION" "$@"
}

# ---------------------------------------------------------------------------
# Resolve script / project paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_FILE="$PROJECT_ROOT/cloudformation/template.yaml"
LAMBDA_HANDLER="$PROJECT_ROOT/lambda/ingest/handler.py"

header "Restaurant Analytics — Deploy"
info "Stack name : $STACK_NAME"
info "Region     : $REGION"
info "Profile    : ${PROFILE:-<default>}"
info "Template   : $TEMPLATE_FILE"

# ---------------------------------------------------------------------------
# Step 1 — Verify AWS CLI is installed
# ---------------------------------------------------------------------------
header "Step 1: Checking AWS CLI"

if ! command -v aws &>/dev/null; then
    error "AWS CLI is not installed or not in PATH."
    error "Install it from: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
    exit 1
fi

AWS_VERSION=$(aws --version 2>&1 | head -n 1)
success "AWS CLI found: $AWS_VERSION"

# ---------------------------------------------------------------------------
# Step 2 — Verify AWS credentials are configured
# ---------------------------------------------------------------------------
header "Step 2: Verifying AWS credentials"

ACCOUNT_ID=$(aws_cmd sts get-caller-identity --query Account --output text 2>/dev/null || true)

if [[ -z "$ACCOUNT_ID" ]]; then
    error "Could not retrieve AWS account ID. Check that your credentials are configured."
    error "Run: aws configure  (or set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY)"
    exit 1
fi

CALLER_ARN=$(aws_cmd sts get-caller-identity --query Arn --output text)
success "Authenticated as : $CALLER_ARN"
success "Account ID       : $ACCOUNT_ID"

# ---------------------------------------------------------------------------
# Step 3 — Verify CloudFormation template exists
# ---------------------------------------------------------------------------
header "Step 3: Validating template"

if [[ ! -f "$TEMPLATE_FILE" ]]; then
    error "CloudFormation template not found at: $TEMPLATE_FILE"
    exit 1
fi

info "Validating template syntax with AWS..."
aws_cmd cloudformation validate-template \
    --template-body "file://$TEMPLATE_FILE" \
    --output text > /dev/null

success "Template is valid: $TEMPLATE_FILE"

# ---------------------------------------------------------------------------
# Step 4 — Package Lambda handler (optional — skipped if inline CFN code used)
# ---------------------------------------------------------------------------
header "Step 4: Packaging Lambda handler"

DEPLOY_BUCKET="${STACK_NAME}-deployment-${ACCOUNT_ID}"

if [[ -f "$LAMBDA_HANDLER" ]]; then
    info "Lambda handler found: $LAMBDA_HANDLER"
    info "Deployment S3 bucket : s3://$DEPLOY_BUCKET"

    # Create the deployment bucket if it does not already exist
    if aws_cmd s3api head-bucket --bucket "$DEPLOY_BUCKET" 2>/dev/null; then
        success "Deployment bucket already exists."
    else
        info "Creating deployment bucket: $DEPLOY_BUCKET ..."

        # us-east-1 does NOT accept a LocationConstraint parameter
        if [[ "$REGION" == "us-east-1" ]]; then
            aws_cmd s3api create-bucket \
                --bucket "$DEPLOY_BUCKET" \
                --region "$REGION"
        else
            aws_cmd s3api create-bucket \
                --bucket "$DEPLOY_BUCKET" \
                --region "$REGION" \
                --create-bucket-configuration LocationConstraint="$REGION"
        fi

        # Block all public access
        aws_cmd s3api put-public-access-block \
            --bucket "$DEPLOY_BUCKET" \
            --public-access-block-configuration \
                BlockPublicAcls=true,IgnorePublicAcls=true,\
BlockPublicPolicy=true,RestrictPublicBuckets=true

        success "Deployment bucket created."
    fi

    # Zip the handler and upload
    TMP_ZIP=$(mktemp /tmp/lambda-handler-XXXXXX.zip)
    info "Zipping handler to: $TMP_ZIP"
    (cd "$(dirname "$LAMBDA_HANDLER")" && zip -q "$TMP_ZIP" handler.py)

    ZIP_KEY="${STACK_NAME}/lambda/handler.zip"
    info "Uploading zip to s3://$DEPLOY_BUCKET/$ZIP_KEY ..."
    aws_cmd s3 cp "$TMP_ZIP" "s3://$DEPLOY_BUCKET/$ZIP_KEY"
    rm -f "$TMP_ZIP"

    success "Lambda package uploaded: s3://$DEPLOY_BUCKET/$ZIP_KEY"
    warn "NOTE: This stack uses inline Lambda code in the CloudFormation template."
    warn "      The uploaded zip is available if you switch to S3-based packaging."
else
    warn "Lambda handler not found at $LAMBDA_HANDLER — skipping packaging step."
    warn "The CloudFormation template uses inline Lambda code; this is expected."
fi

# ---------------------------------------------------------------------------
# Step 5 — Deploy CloudFormation stack
# ---------------------------------------------------------------------------
header "Step 5: Deploying CloudFormation stack"

info "Running: aws cloudformation deploy ..."

DEPLOY_ARGS=(
    cloudformation deploy
    --template-file "$TEMPLATE_FILE"
    --stack-name    "$STACK_NAME"
    --parameter-overrides "ProjectName=${STACK_NAME//-/_}"
    --capabilities  CAPABILITY_NAMED_IAM
    --region        "$REGION"
    --no-fail-on-empty-changeset
)

# shellcheck disable=SC2086
aws $AWS_PROFILE_FLAG "${DEPLOY_ARGS[@]}"

success "Stack deployed successfully: $STACK_NAME"

# ---------------------------------------------------------------------------
# Step 6 — Fetch and display stack outputs
# ---------------------------------------------------------------------------
header "Step 6: Stack Outputs"

OUTPUTS_JSON=$(aws_cmd cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs" \
    --output json)

if [[ "$OUTPUTS_JSON" == "null" || -z "$OUTPUTS_JSON" ]]; then
    warn "No outputs found for stack: $STACK_NAME"
else
    echo -e "\n${BOLD}Key                         Value${RESET}"
    echo    "──────────────────────────────────────────────────────────────"

    # Parse and print each output key/value
    OUTPUT_COUNT=$(echo "$OUTPUTS_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

    for i in $(seq 0 $((OUTPUT_COUNT - 1))); do
        KEY=$(echo "$OUTPUTS_JSON" | python3 -c \
            "import sys,json; d=json.load(sys.stdin); print(d[$i].get('OutputKey',''))")
        VAL=$(echo "$OUTPUTS_JSON" | python3 -c \
            "import sys,json; d=json.load(sys.stdin); print(d[$i].get('OutputValue',''))")
        DESC=$(echo "$OUTPUTS_JSON" | python3 -c \
            "import sys,json; d=json.load(sys.stdin); print(d[$i].get('Description',''))" 2>/dev/null || true)

        printf "  ${GREEN}%-28s${RESET} %s\n" "$KEY" "$VAL"
        if [[ -n "$DESC" ]]; then
            printf "  %-28s ${YELLOW}(%s)${RESET}\n" "" "$DESC"
        fi
    done
fi

# ---------------------------------------------------------------------------
# Step 7 — Retrieve and display the API key value
# ---------------------------------------------------------------------------
header "Step 7: Retrieving API Key value"

API_KEY_NAME="${STACK_NAME}-api-key"
info "Looking for API key named: $API_KEY_NAME"

API_KEY_VALUE=$(aws_cmd apigateway get-api-keys \
    --include-values \
    --query "items[?name=='${API_KEY_NAME}'].value" \
    --output text 2>/dev/null || true)

if [[ -z "$API_KEY_VALUE" || "$API_KEY_VALUE" == "None" ]]; then
    warn "Could not retrieve API key automatically."
    warn "To retrieve manually:"
    warn "  aws apigateway get-api-keys --include-values --region $REGION \\"
    warn "      --query \"items[?name=='${API_KEY_NAME}'].value\" --output text"
else
    echo -e "\n  ${BOLD}API Key Name :${RESET} $API_KEY_NAME"
    echo -e   "  ${BOLD}API Key Value:${RESET} ${GREEN}$API_KEY_VALUE${RESET}"
    echo

    # Offer to write .env automatically
    ENV_FILE="$PROJECT_ROOT/.env"
    API_ENDPOINT_OUTPUT=$(echo "$OUTPUTS_JSON" | python3 -c \
        "import sys,json
d=json.load(sys.stdin)
matches=[x['OutputValue'] for x in d if 'endpoint' in x.get('OutputKey','').lower() or 'apiurl' in x.get('OutputKey','').lower()]
print(matches[0] if matches else '')" 2>/dev/null || true)

    if [[ -n "$API_ENDPOINT_OUTPUT" ]]; then
        info "Writing credentials to $ENV_FILE ..."
        cat > "$ENV_FILE" <<EOF
# Auto-generated by deploy.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
API_ENDPOINT=${API_ENDPOINT_OUTPUT}
API_KEY=${API_KEY_VALUE}
EOF
        success ".env file written: $ENV_FILE"
    else
        warn "Could not auto-detect API endpoint from stack outputs. Set API_ENDPOINT in .env manually."
    fi
fi

# ---------------------------------------------------------------------------
# Step 8 — Next steps
# ---------------------------------------------------------------------------
header "Next Steps"

cat <<EOF

  ${CYAN}1.${RESET} Copy the API endpoint and key to ${BOLD}.env${RESET} in the project root
     (done automatically above if the endpoint was detected).

  ${CYAN}2.${RESET} Run the data simulator:
     ${BOLD}python scripts/simulator.py --events 500${RESET}

  ${CYAN}3.${RESET} Wait ${BOLD}60–90 seconds${RESET} for the Kinesis Firehose buffer to flush
     data into S3.

  ${CYAN}4.${RESET} Trigger the Glue Crawler manually in the AWS Console:
       AWS Console → Glue → Crawlers → run your crawler

  ${CYAN}5.${RESET} Run the Athena queries in ${BOLD}athena/queries/${RESET}:
       Start with popular_items.sql, then hourly_trends.sql

  ${CYAN}6.${RESET} Follow ${BOLD}scripts/quicksight_setup.md${RESET} to build QuickSight dashboards.

EOF

success "Deploy complete. Stack: $STACK_NAME  Region: $REGION"
