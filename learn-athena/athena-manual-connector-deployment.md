# Athena Federated Queries: DynamoDB + MySQL + Redshift (Manual Deployment, No SAR)

This guide deploys three Athena Query Federation connectors **manually** — no SAR, no CloudFormation — seeds each data source with synthetic data, and runs federated queries that join across them. Every command is exact and runnable in order. The final section tears down every resource created. Two connectors (DynamoDB, MySQL) deploy from the pre-built jar uploaded straight to Lambda; the third (Redshift) deploys from AWS's pre-built container image instead, because its jar exceeds Lambda's zip-deployment size limit — Phase 5.7 explains why.

Connector version used throughout: **v2026.24.1** — asset filenames and required handler classes/env vars below were verified directly against the [aws-athena-query-federation](https://github.com/awslabs/aws-athena-query-federation) source at that tag (not assumed from older docs).

## Decisions this doc is built around

These were confirmed with you before writing any commands — change them if your situation differs:

| Decision | Choice |
|---|---|
| Region | `us-east-1` |
| MySQL hosting | New RDS MySQL instance, **VPC-private** (no public access in steady state) |
| Redshift hosting | New **single-node `ra3.large`** provisioned cluster, **VPC-private**. `dc2.large` is not an option — DC2 node types were discontinued for new cluster creation on 2025-05-15 and retire entirely on 2026-04-24, so `ra3.large` (the smallest RA3 size) is now the cheapest orderable node. Still cheaper than Redshift Serverless for a short POC: $0.543/hour compute + $0.024/GB-month storage (billed separately, unlike DC2's bundled local SSD) vs. Serverless's 8-RPU minimum (~$3/hour active) in `us-east-1` |
| VPC | Your account's existing **default VPC** — Redshift reuses the same VPC, subnets, and Secrets Manager/S3 endpoints the MySQL connector already needed, rather than standing up its own |
| Seed-data access to private RDS/Redshift | Temporarily open to your own IP + flip `publicly-accessible` on, load data, then revert both |
| Data model | DynamoDB table `customers` (PK `customer_id`) ⋈ MySQL table `orders` (`customer_id` FK) ⋈ Redshift table `payments` (`order_id` FK) — a three-source chain joined on `customer_id` then `order_id` |

Key architectural facts this doc relies on (verified in source, not assumed): the DynamoDB connector needs **no VPC** at all. The MySQL and Redshift connectors are both built on the same `athena-jdbc` codebase and **must** be VPC-attached to reach their respective databases, which means they lose default internet access — so each also needs the **S3 Gateway endpoint** (for spilling) and **Secrets Manager Interface endpoint** (for fetching DB credentials) created in Phase 4. Without those two endpoints, a VPC-attached connector will fail at runtime even though it deploys successfully. (CloudWatch Logs works fine with no endpoint — Lambda ships logs via its control plane, not through your VPC ENI. The connector's own `athena:GetQueryExecution` call is best-effort/non-fatal if unreachable, confirmed in `QueryStatusChecker.java`, so no Athena VPC endpoint is needed.) Redshift's connector handler (`RedshiftMuxCompositeHandler`), environment variable shape, and IAM permission set are all structurally identical to MySQL's — confirmed against `athena-redshift/athena-redshift.yaml` and `RedshiftConstants.java` at the same release tag — the only real differences are the port (5439), JDBC scheme (`redshift://jdbc:redshift://`), and driver class.

---

## Prerequisites

- AWS CLI v2, configured (`aws configure`) with permissions to create IAM roles/policies, Lambda functions, S3 buckets, DynamoDB tables, RDS instances, EC2 security groups/VPC endpoints, Secrets Manager secrets, and Athena data catalogs.
- A local `mysql` client (`mysql --version`) — used once, briefly, to seed RDS. On macOS, `brew install mysql-client` (**not** `mysql-shell`/`mysqlsh` — that's a different tool with different CLI syntax). It's keg-only, so add it to your PATH: `echo 'export PATH="/opt/homebrew/opt/mysql-client/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc`.
- A local `psql` client, to seed Redshift (Redshift speaks the Postgres wire protocol). On macOS: `brew install libpq` — also keg-only: `echo 'export PATH="/opt/homebrew/opt/libpq/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc`.
- `curl`, `openssl`, `jq` available locally.

---

## Phase 0: Set shared variables

Run this once; every later command in this doc reuses these variables. **Keep this shell session open** (or re-export these) for the rest of the walkthrough.

> **If you're on zsh** (macOS default), unquoted variables holding multiple space-separated values (`$SUBNET_IDS`, `$ROUTE_TABLE_IDS`) do **not** word-split into separate CLI arguments the way they do in bash — zsh passes the whole thing as one argument, which later shows up as an `Invalid Subnet Id` / `Invalid Route Table Id` style error with all the IDs jammed together. `setopt SH_WORD_SPLIT` below restores bash-style splitting for the rest of this session; it's a no-op if you're actually on bash. If your terminal errors on this line, you're already on bash and can skip it.

```bash
setopt SH_WORD_SPLIT 2>/dev/null

export AWS_REGION="us-east-1"
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account: $ACCOUNT_ID  Region: $AWS_REGION"

# S3 buckets (globally unique — suffixed with your account id)
export CODE_BUCKET="athena-federation-code-${ACCOUNT_ID}"
export SPILL_BUCKET="athena-federation-spill-${ACCOUNT_ID}"
export RESULTS_BUCKET="athena-federation-results-${ACCOUNT_ID}"

# DynamoDB connector
export DYNAMODB_TABLE="customers"
export DYNAMODB_LAMBDA="athena_dynamodb_connector"
export DYNAMODB_CATALOG="dynamodb_catalog"
export DYNAMODB_ROLE="AthenaDynamoDBConnectorRole"
export DYNAMODB_JAR="athena-dynamodb-2026.24.1.jar"

# MySQL connector
export MYSQL_LAMBDA="athena_mysql_connector"
export MYSQL_CATALOG="mysql_catalog"
export MYSQL_ROLE="AthenaMySQLConnectorRole"
export MYSQL_JAR="athena-mysql-2026.24.1.jar"
export MYSQL_DB_INSTANCE_ID="athena-federation-mysql"
export MYSQL_DB_NAME="federation_demo"
export MYSQL_MASTER_USERNAME="admin"
export MYSQL_SECRET_NAME="AthenaMySQLFederationSecret"
export DB_SUBNET_GROUP="athena-mysql-subnet-group"
export LAMBDA_SG_NAME="athena-mysql-lambda-sg"
export RDS_SG_NAME="athena-mysql-rds-sg"
export ENDPOINT_SG_NAME="athena-secretsmanager-endpoint-sg"

# Redshift connector — deployed from a container image, not a jar (see Phase 5.7:
# the jar exceeds Lambda's unzipped size limit), so no REDSHIFT_JAR variable here.
export REDSHIFT_LAMBDA="athena_redshift_connector"
export REDSHIFT_CATALOG="redshift_catalog"
export REDSHIFT_ROLE="AthenaRedshiftConnectorRole"
export REDSHIFT_CLUSTER_ID="athena-federation-redshift"
export REDSHIFT_DB_NAME="federation_demo"
export REDSHIFT_MASTER_USERNAME="admin"
export REDSHIFT_SECRET_NAME="AthenaRedshiftFederationSecret"
export REDSHIFT_SUBNET_GROUP="athena-redshift-subnet-group"
export REDSHIFT_LAMBDA_SG_NAME="athena-redshift-lambda-sg"
export REDSHIFT_SG_NAME="athena-redshift-sg"

mkdir -p ~/athena-federation-demo && cd ~/athena-federation-demo
```

**This is a multi-session runbook — every `export` above only lives in the terminal tab you ran it in.** If you close/reopen your terminal, or switch tabs, these variables are gone and any command using them silently gets an empty string (e.g. `--group-name` with nothing after it, which is exactly the parse error you get if you try to run Phase 4 in a fresh shell without re-running Phase 0 and Phase 4.1 first). Before running any phase, check the variables it needs aren't empty:

```bash
check_vars () {
  local missing=0
  for v in "$@"; do
    if [ -z "${!v}" ]; then echo "MISSING: $v is not set in this shell"; missing=1; fi
  done
  [ "$missing" -eq 1 ] && echo "Re-run Phase 0 (and Phase 4.1 if VPC_ID/SUBNET_IDS are missing) in this terminal before continuing." && return 1
  return 0
}
```

---

## Phase 1: Foundational S3 buckets

```bash
aws s3 mb s3://$CODE_BUCKET --region $AWS_REGION
aws s3 mb s3://$SPILL_BUCKET --region $AWS_REGION
aws s3 mb s3://$RESULTS_BUCKET --region $AWS_REGION
```

Add a lifecycle rule so spilled data auto-expires after 1 day (spill data is transient — no reason to keep it):

```bash
cat > spill-lifecycle.json <<'EOF'
{
  "Rules": [
    {
      "ID": "expire-spill-objects",
      "Filter": {},
      "Status": "Enabled",
      "Expiration": { "Days": 1 }
    }
  ]
}
EOF

aws s3api put-bucket-lifecycle-configuration \
  --bucket $SPILL_BUCKET \
  --lifecycle-configuration file://spill-lifecycle.json
```

### Set the Athena console's query result location

The `run_query` helper in Phase 6 passes `--result-configuration` on every CLI call, so it doesn't need this. But if you run any query from the **Athena console** instead, it uses the `primary` workgroup's own result-location setting — which is unset by default and throws "Before you run your first query, you need to set up a query result location in Amazon S3." Set it once, now:

```bash
aws athena update-work-group \
  --work-group primary \
  --configuration-updates "ResultConfigurationUpdates={OutputLocation=s3://${RESULTS_BUCKET}/}"
```

## Phase 2: Download connector jars and upload to the code bucket

Only DynamoDB and MySQL — Redshift's jar exceeds Lambda's unzipped size limit and is deployed from a pre-built container image instead (Phase 5.7 explains why and how).

```bash
curl -L -o $DYNAMODB_JAR \
  https://github.com/awslabs/aws-athena-query-federation/releases/download/v2026.24.1/$DYNAMODB_JAR

curl -L -o $MYSQL_JAR \
  https://github.com/awslabs/aws-athena-query-federation/releases/download/v2026.24.1/$MYSQL_JAR

aws s3 cp $DYNAMODB_JAR s3://$CODE_BUCKET/connectors/$DYNAMODB_JAR
aws s3 cp $MYSQL_JAR s3://$CODE_BUCKET/connectors/$MYSQL_JAR
```

> Both jars are self-contained (Maven shade plugin bundles the JDBC driver / AWS SDK / federation SDK), so no separate dependency jar is needed — confirmed from `athena-mysql/pom.xml`'s `maven-shade-plugin` config. Both are also well under Lambda's 250 MiB unzipped limit, but not by much: 245.5 MB (MySQL) and 239.2 MB (DynamoDB) uncompressed, against a 262.1 MB ceiling. Worth re-checking with `unzip -l` if you bump `connector_version` later — there's no guarantee a future release stays under.

---

## Phase 3: DynamoDB source — table, data, connector, catalog

### 3.1 Create the DynamoDB table

```bash
aws dynamodb create-table \
  --table-name $DYNAMODB_TABLE \
  --attribute-definitions AttributeName=customer_id,AttributeType=S \
  --key-schema AttributeName=customer_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region $AWS_REGION

aws dynamodb wait table-exists --table-name $DYNAMODB_TABLE
```

### 3.2 Insert synthetic customer data

8 customers, `customer_id` values `CUST001`–`CUST008` (this exact ID scheme is what the MySQL `orders` table will reference later, so the federated JOIN lines up):

```bash
aws dynamodb put-item --table-name $DYNAMODB_TABLE --item '{
  "customer_id": {"S": "CUST001"}, "name": {"S": "Alice Johnson"},
  "email": {"S": "alice.johnson@example.com"}, "signup_date": {"S": "2025-01-12"}
}'
aws dynamodb put-item --table-name $DYNAMODB_TABLE --item '{
  "customer_id": {"S": "CUST002"}, "name": {"S": "Brian Lee"},
  "email": {"S": "brian.lee@example.com"}, "signup_date": {"S": "2025-02-03"}
}'
aws dynamodb put-item --table-name $DYNAMODB_TABLE --item '{
  "customer_id": {"S": "CUST003"}, "name": {"S": "Carla Mendes"},
  "email": {"S": "carla.mendes@example.com"}, "signup_date": {"S": "2025-02-20"}
}'
aws dynamodb put-item --table-name $DYNAMODB_TABLE --item '{
  "customer_id": {"S": "CUST004"}, "name": {"S": "David Kim"},
  "email": {"S": "david.kim@example.com"}, "signup_date": {"S": "2025-03-11"}
}'
aws dynamodb put-item --table-name $DYNAMODB_TABLE --item '{
  "customer_id": {"S": "CUST005"}, "name": {"S": "Elena Petrova"},
  "email": {"S": "elena.petrova@example.com"}, "signup_date": {"S": "2025-03-29"}
}'
aws dynamodb put-item --table-name $DYNAMODB_TABLE --item '{
  "customer_id": {"S": "CUST006"}, "name": {"S": "Farid Haidari"},
  "email": {"S": "farid.haidari@example.com"}, "signup_date": {"S": "2025-04-15"}
}'
aws dynamodb put-item --table-name $DYNAMODB_TABLE --item '{
  "customer_id": {"S": "CUST007"}, "name": {"S": "Grace Osei"},
  "email": {"S": "grace.osei@example.com"}, "signup_date": {"S": "2025-05-02"}
}'
aws dynamodb put-item --table-name $DYNAMODB_TABLE --item '{
  "customer_id": {"S": "CUST008"}, "name": {"S": "Hana Suzuki"},
  "email": {"S": "hana.suzuki@example.com"}, "signup_date": {"S": "2025-05-18"}
}'
```

Verify:

```bash
aws dynamodb scan --table-name $DYNAMODB_TABLE --select COUNT
```

### 3.3 IAM role for the DynamoDB connector Lambda

```bash
cat > trust-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Principal": { "Service": "lambda.amazonaws.com" }, "Action": "sts:AssumeRole" }
  ]
}
EOF

aws iam create-role \
  --role-name $DYNAMODB_ROLE \
  --assume-role-policy-document file://trust-policy.json

aws iam attach-role-policy \
  --role-name $DYNAMODB_ROLE \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
```

Inline policy — this exact permission set is what the connector's own SAR template grants (verified in `athena-dynamodb/athena-dynamodb.yaml`):

```bash
cat > dynamodb-connector-permissions.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DataSourceAndGlueAccess",
      "Effect": "Allow",
      "Action": [
        "dynamodb:DescribeTable", "dynamodb:ListTables", "dynamodb:Query", "dynamodb:Scan", "dynamodb:PartiQLSelect",
        "glue:GetTableVersions", "glue:GetPartitions", "glue:GetTables", "glue:GetTableVersion",
        "glue:GetDatabases", "glue:GetTable", "glue:GetPartition", "glue:GetDatabase",
        "athena:GetQueryExecution"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SpillBucketAccess",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation", "s3:GetObjectVersion",
        "s3:PutObject", "s3:PutObjectAcl", "s3:GetLifecycleConfiguration", "s3:PutLifecycleConfiguration", "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::${SPILL_BUCKET}",
        "arn:aws:s3:::${SPILL_BUCKET}/*"
      ]
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name $DYNAMODB_ROLE \
  --policy-name AthenaDynamoDBConnectorPermissions \
  --policy-document file://dynamodb-connector-permissions.json

export DYNAMODB_ROLE_ARN=$(aws iam get-role --role-name $DYNAMODB_ROLE --query 'Role.Arn' --output text)
```

IAM role propagation can take ~10 seconds before Lambda will accept it — pause briefly before the next step.

### 3.4 Create the DynamoDB connector Lambda function

The handler is the connector's **composite handler class** — not `ProxyHandler` (that class doesn't exist in this repo; confirmed by searching the whole codebase). `RequestStreamHandler`-based classes only need the fully-qualified class name, no `::method` suffix.

> **Required JVM flag — `java21` will crash without it.** The federation SDK uses Apache Arrow for in-memory data, and Arrow needs reflective access to `java.nio.Buffer` internals that the JVM's module system blocks by default on Java 17+/21. Without this flag, every query fails inside the metadata handler with `InaccessibleObjectException: Unable to make field long java.nio.Buffer.address accessible` → `Failed to initialize MemoryUtil`, and Athena reports it back to you as a confusing `TABLE_NOT_FOUND` instead of the real error. Fix it by setting `JAVA_TOOL_OPTIONS` (a standard JVM env var every `java` launcher reads at startup) to `--add-opens=java.base/java.nio=ALL-UNNAMED`. Both connectors need this — it's baked into both env JSON files below.

```bash
cat > dynamodb-env.json <<EOF
{
  "Variables": {
    "spill_bucket": "${SPILL_BUCKET}",
    "spill_prefix": "athena-spill",
    "disable_spill_encryption": "false",
    "JAVA_TOOL_OPTIONS": "--add-opens=java.base/java.nio=ALL-UNNAMED"
  }
}
EOF

aws lambda create-function \
  --function-name $DYNAMODB_LAMBDA \
  --runtime java21 \
  --role $DYNAMODB_ROLE_ARN \
  --handler com.amazonaws.athena.connectors.dynamodb.DynamoDBCompositeHandler \
  --code S3Bucket=$CODE_BUCKET,S3Key=connectors/$DYNAMODB_JAR \
  --memory-size 3008 \
  --timeout 900 \
  --environment file://dynamodb-env.json

aws lambda wait function-active --function-name $DYNAMODB_LAMBDA
```

**Already created the function without this flag?** Patch it in place instead of recreating it:

```bash
aws lambda update-function-configuration \
  --function-name $DYNAMODB_LAMBDA \
  --environment file://dynamodb-env.json

aws lambda wait function-updated --function-name $DYNAMODB_LAMBDA
```

### 3.5 Register the DynamoDB Athena Data Catalog

```bash
export DYNAMODB_LAMBDA_ARN=$(aws lambda get-function --function-name $DYNAMODB_LAMBDA --query 'Configuration.FunctionArn' --output text)

# Read more about this
aws lambda add-permission \
  --function-name $DYNAMODB_LAMBDA \
  --statement-id AllowAthenaInvoke \
  --action lambda:InvokeFunction \
  --principal athena.amazonaws.com

aws athena create-data-catalog \
  --name $DYNAMODB_CATALOG \
  --type LAMBDA \
  --description "DynamoDB connector for federation demo" \
  --parameters "function=$DYNAMODB_LAMBDA_ARN"
```

---

## Phase 4: MySQL (RDS) source — networking, instance, data, connector, catalog

### 4.1 Look up the default VPC and its subnets

```bash
export VPC_ID=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
export SUBNET_IDS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID Name=default-for-az,Values=true --query 'Subnets[*].SubnetId' --output text)
export SUBNET_IDS_CSV=$(echo $SUBNET_IDS | tr ' ' ',')
echo "VPC: $VPC_ID"
echo "Subnets: $SUBNET_IDS"
```

RDS requires a DB subnet group spanning at least 2 Availability Zones — the default VPC's default-for-az subnets satisfy this in `us-east-1` (3 AZs by default).

### 4.2 Security groups

```bash
check_vars VPC_ID LAMBDA_SG_NAME RDS_SG_NAME ENDPOINT_SG_NAME || return 1
```

Lambda's security group (no inbound rules needed — Lambda never receives inbound traffic):

```bash
export LAMBDA_SG_ID=$(aws ec2 create-security-group \
  --group-name $LAMBDA_SG_NAME \
  --description "Athena MySQL connector Lambda" \
  --vpc-id $VPC_ID \
  --query 'GroupId' --output text)
```

RDS's security group — allow 3306 only from the Lambda's security group:

```bash
export RDS_SG_ID=$(aws ec2 create-security-group \
  --group-name $RDS_SG_NAME \
  --description "RDS MySQL for Athena federation demo" \
  --vpc-id $VPC_ID \
  --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress \
  --group-id $RDS_SG_ID \
  --protocol tcp --port 3306 \
  --source-group $LAMBDA_SG_ID
```

Secrets Manager VPC endpoint's security group — allow HTTPS from the Lambda's security group:

```bash
export ENDPOINT_SG_ID=$(aws ec2 create-security-group \
  --group-name $ENDPOINT_SG_NAME \
  --description "Secrets Manager interface endpoint for Athena MySQL connector" \
  --vpc-id $VPC_ID \
  --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress \
  --group-id $ENDPOINT_SG_ID \
  --protocol tcp --port 443 \
  --source-group $LAMBDA_SG_ID
```

### 4.3 VPC endpoints (required — the MySQL Lambda has no NAT/internet path)

S3 Gateway endpoint (free; needed for spilling to `$SPILL_BUCKET`):

```bash
export ROUTE_TABLE_IDS=$(aws ec2 describe-route-tables --filters Name=vpc-id,Values=$VPC_ID --query 'RouteTables[*].RouteTableId' --output text)

aws ec2 create-vpc-endpoint \
  --vpc-id $VPC_ID \
  --vpc-endpoint-type Gateway \
  --service-name com.amazonaws.$AWS_REGION.s3 \
  --route-table-ids $ROUTE_TABLE_IDS
```

Secrets Manager Interface endpoint (small hourly cost; needed for the connector to fetch DB credentials — this call is synchronous and required, unlike the Athena status-check call):

```bash
aws ec2 create-vpc-endpoint \
  --vpc-id $VPC_ID \
  --vpc-endpoint-type Interface \
  --service-name com.amazonaws.$AWS_REGION.secretsmanager \
  --subnet-ids $SUBNET_IDS \
  --security-group-ids $ENDPOINT_SG_ID \
  --private-dns-enabled
```

### 4.4 DB subnet group

```bash
aws rds create-db-subnet-group \
  --db-subnet-group-name $DB_SUBNET_GROUP \
  --db-subnet-group-description "Subnets for Athena MySQL federation demo" \
  --subnet-ids $SUBNET_IDS
```

### 4.5 Create the RDS MySQL instance (private)

Generate a random master password (alphanumeric only, so it never needs URL-encoding later) and resolve the latest available MySQL 8.0 engine version — nothing hardcoded:

```bash
export MYSQL_MASTER_PASSWORD=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)
echo "Master password (save this — you'll need it to seed data): $MYSQL_MASTER_PASSWORD"

export MYSQL_ENGINE_VERSION=$(aws rds describe-db-engine-versions \
  --engine mysql \
  --query "DBEngineVersions[?starts_with(EngineVersion, '8.0')].EngineVersion | sort(@) | [-1]" \
  --output text)
echo "Engine version: $MYSQL_ENGINE_VERSION"

aws rds create-db-instance \
  --db-instance-identifier $MYSQL_DB_INSTANCE_ID \
  --db-instance-class db.t4g.micro \
  --engine mysql \
  --engine-version $MYSQL_ENGINE_VERSION \
  --master-username $MYSQL_MASTER_USERNAME \
  --master-user-password $MYSQL_MASTER_PASSWORD \
  --allocated-storage 20 \
  --storage-type gp3 \
  --storage-encrypted \
  --db-name $MYSQL_DB_NAME \
  --vpc-security-group-ids $RDS_SG_ID \
  --db-subnet-group-name $DB_SUBNET_GROUP \
  --backup-retention-period 0 \
  --no-multi-az \
  --no-publicly-accessible \
  --no-deletion-protection

aws rds wait db-instance-available --db-instance-identifier $MYSQL_DB_INSTANCE_ID

export MYSQL_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier $MYSQL_DB_INSTANCE_ID \
  --query 'DBInstances[0].Endpoint.Address' --output text)
echo "RDS endpoint: $MYSQL_ENDPOINT"
```

> `--backup-retention-period 0` disables automated backups so teardown never has to deal with a final snapshot — fine for a throwaway demo, not something to carry into production.

### 4.6 Store master credentials in Secrets Manager

The connector expects the secret as JSON with exactly these two keys (verified in `DefaultCredentialsProvider.java`):

```bash
aws secretsmanager create-secret \
  --name $MYSQL_SECRET_NAME \
  --description "Master credentials for Athena MySQL federation demo" \
  --secret-string "{\"username\":\"${MYSQL_MASTER_USERNAME}\",\"password\":\"${MYSQL_MASTER_PASSWORD}\"}"

export MYSQL_SECRET_ARN=$(aws secretsmanager describe-secret --secret-id $MYSQL_SECRET_NAME --query 'ARN' --output text)
```

### 4.7 Temporarily open RDS to your IP and seed synthetic data

```bash
export MY_IP=$(curl -s https://checkip.amazonaws.com)
echo "Your IP: $MY_IP"

aws ec2 authorize-security-group-ingress \
  --group-id $RDS_SG_ID \
  --protocol tcp --port 3306 \
  --cidr "${MY_IP}/32"

aws rds modify-db-instance \
  --db-instance-identifier $MYSQL_DB_INSTANCE_ID \
  --publicly-accessible \
  --apply-immediately

aws rds wait db-instance-available --db-instance-identifier $MYSQL_DB_INSTANCE_ID
```

`wait db-instance-available` can return before the public IP association has fully propagated — if the next step's connection is refused, wait ~60 seconds and retry.

Create the `orders` table and insert 20 synthetic rows referencing the 8 DynamoDB customer IDs (note `customer_id` is `VARCHAR(10)` on both sides — matching types means the later federated JOIN needs no casting):

```bash
mysql -h "$MYSQL_ENDPOINT" -P 3306 -u "$MYSQL_MASTER_USERNAME" -p"$MYSQL_MASTER_PASSWORD" "$MYSQL_DB_NAME" <<'SQL'
CREATE TABLE orders (
  order_id INT PRIMARY KEY AUTO_INCREMENT,
  customer_id VARCHAR(10) NOT NULL,
  product VARCHAR(100) NOT NULL,
  amount DECIMAL(10,2) NOT NULL,
  order_date DATE NOT NULL
);

INSERT INTO orders (customer_id, product, amount, order_date) VALUES
('CUST001', 'Wireless Mouse',        24.99, '2026-01-05'),
('CUST001', 'Mechanical Keyboard',   89.50, '2026-02-14'),
('CUST002', 'USB-C Hub',            34.00, '2026-01-20'),
('CUST002', 'Laptop Stand',         45.75, '2026-03-02'),
('CUST002', 'Webcam 1080p',         59.99, '2026-04-11'),
('CUST003', 'Noise Cancelling Headphones', 199.99, '2026-01-30'),
('CUST003', 'Bluetooth Speaker',    69.25, '2026-05-06'),
('CUST004', 'External SSD 1TB',    109.00, '2026-02-08'),
('CUST004', 'HDMI Cable 2m',         9.99, '2026-02-09'),
('CUST004', 'Monitor Arm',          79.99, '2026-06-01'),
('CUST005', 'Wireless Charger',     29.99, '2026-01-15'),
('CUST005', 'Portable SSD 500GB',   64.50, '2026-03-22'),
('CUST006', 'Gaming Mouse Pad',     19.99, '2026-04-02'),
('CUST006', 'RGB Keyboard',         74.00, '2026-04-30'),
('CUST006', 'Graphics Tablet',     149.99, '2026-06-18'),
('CUST007', 'Ergonomic Chair Cushion', 39.99, '2026-02-25'),
('CUST007', '4K Webcam',            89.99, '2026-05-14'),
('CUST008', 'Desk Lamp LED',        22.50, '2026-01-10'),
('CUST008', 'Cable Organizer Kit',  14.99, '2026-03-19'),
('CUST008', 'Standing Desk Mat',    54.00, '2026-06-27');
SQL
```

Verify:

```bash
mysql -h "$MYSQL_ENDPOINT" -P 3306 -u "$MYSQL_MASTER_USERNAME" -p"$MYSQL_MASTER_PASSWORD" "$MYSQL_DB_NAME" \
  -e "SELECT COUNT(*) FROM orders;"
```

### 4.8 Revert RDS to private (close the temporary access window)

```bash
aws rds modify-db-instance \
  --db-instance-identifier $MYSQL_DB_INSTANCE_ID \
  --no-publicly-accessible \
  --apply-immediately

aws rds wait db-instance-available --db-instance-identifier $MYSQL_DB_INSTANCE_ID

aws ec2 revoke-security-group-ingress \
  --group-id $RDS_SG_ID \
  --protocol tcp --port 3306 \
  --cidr "${MY_IP}/32"
```

RDS is now back to fully private, reachable only from the Lambda security group.

### 4.9 IAM role for the MySQL connector Lambda

```bash
aws iam create-role \
  --role-name $MYSQL_ROLE \
  --assume-role-policy-document file://trust-policy.json

aws iam attach-role-policy \
  --role-name $MYSQL_ROLE \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole
```

`AWSLambdaVPCAccessExecutionRole` (not the basic one) is required here — it grants `ec2:CreateNetworkInterface` / `DeleteNetworkInterface` / `DescribeNetworkInterfaces` / `DetachNetworkInterface` plus CloudWatch Logs, which a VPC-attached Lambda needs to even start up. This matches the MySQL connector's own SAR template exactly.

```bash
cat > mysql-connector-permissions.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SecretAccess",
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "${MYSQL_SECRET_ARN}"
    },
    {
      "Sid": "AthenaInvoke",
      "Effect": "Allow",
      "Action": "athena:GetQueryExecution",
      "Resource": "*"
    },
    {
      "Sid": "SpillBucketAccess",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation", "s3:GetObjectVersion",
        "s3:PutObject", "s3:PutObjectAcl", "s3:GetLifecycleConfiguration", "s3:PutLifecycleConfiguration", "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::${SPILL_BUCKET}",
        "arn:aws:s3:::${SPILL_BUCKET}/*"
      ]
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name $MYSQL_ROLE \
  --policy-name AthenaMySQLConnectorPermissions \
  --policy-document file://mysql-connector-permissions.json

export MYSQL_ROLE_ARN=$(aws iam get-role --role-name $MYSQL_ROLE --query 'Role.Arn' --output text)
```

### 4.10 Create the MySQL connector Lambda function

The connection string format (`${engine}://${jdbc_url}`, with `${SecretName}` as a literal placeholder token the connector resolves at invocation time) was verified in `DatabaseConnectionConfigBuilder.java` and `GenericJdbcConnectionFactory.java` — the `${...}` token is stripped from the URL entirely and the username/password from the secret are injected as separate JDBC connection properties, not URL query params.

> **Same required JVM flag as the DynamoDB connector** (see the note in 3.4) — `JAVA_TOOL_OPTIONS=--add-opens=java.base/java.nio=ALL-UNNAMED` is required here too, since it's the same shaded federation SDK / Arrow dependency causing the crash. It's included in the env JSON below.

```bash
check_vars SUBNET_IDS LAMBDA_SG_ID MYSQL_ROLE_ARN CODE_BUCKET MYSQL_JAR MYSQL_ENDPOINT MYSQL_MASTER_PASSWORD || return 1

# Rebuilt here (not reused from Phase 4.1) so a stale/new shell can't silently pass a
# malformed value — SubnetIds in --vpc-config must be comma-joined, not space-separated.
export SUBNET_IDS_CSV=$(echo $SUBNET_IDS | tr ' ' ',')

cat > mysql-env.json <<EOF
{
  "Variables": {
    "spill_bucket": "${SPILL_BUCKET}",
    "spill_prefix": "athena-spill",
    "disable_spill_encryption": "false",
    "default": "mysql://jdbc:mysql://${MYSQL_ENDPOINT}:3306/${MYSQL_DB_NAME}?\${${MYSQL_SECRET_NAME}}",
    "JAVA_TOOL_OPTIONS": "--add-opens=java.base/java.nio=ALL-UNNAMED"
  }
}
EOF
cat mysql-env.json   # sanity check: the "default" value should literally contain ${AthenaMySQLFederationSecret}

aws lambda create-function \
  --function-name $MYSQL_LAMBDA \
  --runtime java21 \
  --role $MYSQL_ROLE_ARN \
  --handler com.amazonaws.athena.connectors.mysql.MySqlMuxCompositeHandler \
  --code S3Bucket=$CODE_BUCKET,S3Key=connectors/$MYSQL_JAR \
  --memory-size 3008 \
  --timeout 900 \
  --vpc-config SubnetIds=$SUBNET_IDS_CSV,SecurityGroupIds=$LAMBDA_SG_ID \
  --environment file://mysql-env.json

aws lambda wait function-active --function-name $MYSQL_LAMBDA
```

**Already created the function without this flag?** Patch it in place instead of recreating it:

```bash
aws lambda update-function-configuration \
  --function-name $MYSQL_LAMBDA \
  --environment file://mysql-env.json

aws lambda wait function-updated --function-name $MYSQL_LAMBDA
```

> `MySqlMuxCompositeHandler` (not `MySqlCompositeHandler`) is used because it supports the `<catalog>_connection_string` env var convention for multiple catalogs from one Lambda — we only use `default` here, but Mux is what the official template deploys and it works fine with a single connection.

### 4.11 Register the MySQL Athena Data Catalog

```bash
export MYSQL_LAMBDA_ARN=$(aws lambda get-function --function-name $MYSQL_LAMBDA --query 'Configuration.FunctionArn' --output text)

aws lambda add-permission \
  --function-name $MYSQL_LAMBDA \
  --statement-id AllowAthenaInvoke \
  --action lambda:InvokeFunction \
  --principal athena.amazonaws.com

aws athena create-data-catalog \
  --name $MYSQL_CATALOG \
  --type LAMBDA \
  --description "MySQL/RDS connector for federation demo" \
  --parameters "function=$MYSQL_LAMBDA_ARN"
```

---

## Phase 5: Redshift source — cluster, data, connector, catalog

Redshift's connector is built on the same `athena-jdbc` codebase as MySQL's — same handler shape (`RedshiftMuxCompositeHandler`, the Redshift analogue of `MySqlMuxCompositeHandler`), same `default` connection-string env var format, same Secrets Manager credential mechanism, same required `JAVA_TOOL_OPTIONS` fix. This phase reuses the VPC, subnets, S3 Gateway endpoint, and Secrets Manager Interface endpoint already created in Phase 4 — only new security groups are created. One thing does not carry over from MySQL: the connector jar itself is too large for Lambda's zip-deployment size limit, so 5.7 deploys it from a container image instead — no separate jar download for Redshift in Phase 2.

### 5.1 Create the Redshift cluster subnet group

```bash
check_vars SUBNET_IDS || return 1

aws redshift create-cluster-subnet-group \
  --cluster-subnet-group-name $REDSHIFT_SUBNET_GROUP \
  --description "Subnets for Athena Redshift federation demo" \
  --subnet-ids $SUBNET_IDS
```

### 5.2 Security groups

```bash
check_vars VPC_ID || return 1

export REDSHIFT_LAMBDA_SG_ID=$(aws ec2 create-security-group \
  --group-name $REDSHIFT_LAMBDA_SG_NAME \
  --description "Athena Redshift connector Lambda" \
  --vpc-id $VPC_ID \
  --query 'GroupId' --output text)

export REDSHIFT_SG_ID=$(aws ec2 create-security-group \
  --group-name $REDSHIFT_SG_NAME \
  --description "Redshift cluster for Athena federation demo" \
  --vpc-id $VPC_ID \
  --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress \
  --group-id $REDSHIFT_SG_ID \
  --protocol tcp --port 5439 \
  --source-group $REDSHIFT_LAMBDA_SG_ID
```

The existing Secrets Manager VPC endpoint (from Phase 4.3) only allows inbound 443 from the MySQL Lambda's security group — this new Redshift Lambda has its own, different security group, so it needs its own explicit rule added to that same endpoint:

```bash
check_vars ENDPOINT_SG_ID || return 1

aws ec2 authorize-security-group-ingress \
  --group-id $ENDPOINT_SG_ID \
  --protocol tcp --port 443 \
  --source-group $REDSHIFT_LAMBDA_SG_ID
```

### 5.3 Create the Redshift cluster (private, single-node)

A single-node `ra3.large` is the cheapest node Redshift will actually let you provision today — DC2 (`dc2.large`/`dc2.8xlarge`) was discontinued for new clusters on 2025-05-15, so it's not a matter of picking a smaller size; RA3 is the only family available. `ra3.large` runs $0.543/hour compute plus $0.024/GB-month for storage (billed separately from compute — RA3 uses managed storage, not bundled local SSD), still well under Redshift Serverless's 8-RPU minimum (~$3/hour active in `us-east-1`) for a short POC. For a few dozen synthetic rows over a couple of test hours, expect roughly $1-2 total, storage cost negligible.

```bash
export REDSHIFT_MASTER_PASSWORD="Aa1$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 20)"
echo "Redshift master password (save this — you'll need it to seed data): $REDSHIFT_MASTER_PASSWORD"
```

(Prefixing with `Aa1` guarantees Redshift's password policy — at least one uppercase, one lowercase, one digit — regardless of what the random draw produced, without needing to inspect and retry.)

```bash
aws redshift create-cluster \
  --cluster-identifier $REDSHIFT_CLUSTER_ID \
  --node-type ra3.large \
  --cluster-type single-node \
  --master-username $REDSHIFT_MASTER_USERNAME \
  --master-user-password "$REDSHIFT_MASTER_PASSWORD" \
  --db-name $REDSHIFT_DB_NAME \
  --cluster-subnet-group-name $REDSHIFT_SUBNET_GROUP \
  --vpc-security-group-ids $REDSHIFT_SG_ID \
  --no-publicly-accessible \
  --encrypted

aws redshift wait cluster-available --cluster-identifier $REDSHIFT_CLUSTER_ID

export REDSHIFT_ENDPOINT=$(aws redshift describe-clusters \
  --cluster-identifier $REDSHIFT_CLUSTER_ID \
  --query 'Clusters[0].Endpoint.Address' --output text)
echo "Redshift endpoint: $REDSHIFT_ENDPOINT"
```

### 5.4 Store master credentials in Secrets Manager

Same JSON shape as MySQL's — the credential-fetching code (`DefaultCredentialsProvider`) is shared across all JDBC connectors, not MySQL-specific.

```bash
aws secretsmanager create-secret \
  --name $REDSHIFT_SECRET_NAME \
  --description "Master credentials for Athena Redshift federation demo" \
  --secret-string "{\"username\":\"${REDSHIFT_MASTER_USERNAME}\",\"password\":\"${REDSHIFT_MASTER_PASSWORD}\"}"

export REDSHIFT_SECRET_ARN=$(aws secretsmanager describe-secret --secret-id $REDSHIFT_SECRET_NAME --query 'ARN' --output text)
```

### 5.5 Temporarily open Redshift to your IP and seed synthetic data

Same temporary-access pattern as MySQL: private by default, briefly opened, then reverted.

```bash
export MY_IP=$(curl -s https://checkip.amazonaws.com)

aws ec2 authorize-security-group-ingress \
  --group-id $REDSHIFT_SG_ID \
  --protocol tcp --port 5439 \
  --cidr "${MY_IP}/32"

aws redshift modify-cluster \
  --cluster-identifier $REDSHIFT_CLUSTER_ID \
  --publicly-accessible

aws redshift wait cluster-available --cluster-identifier $REDSHIFT_CLUSTER_ID
```

Create the `payments` table and insert rows referencing the MySQL `orders.order_id` values from Phase 4 (order_id 1–18 get a payment; 19 and 20 are deliberately left unpaid, to show a `LEFT JOIN` producing `NULL`s later):

```bash
PGPASSWORD="$REDSHIFT_MASTER_PASSWORD" psql -h "$REDSHIFT_ENDPOINT" -p 5439 -U "$REDSHIFT_MASTER_USERNAME" -d "$REDSHIFT_DB_NAME" <<'SQL'
CREATE TABLE payments (
  payment_id INT IDENTITY(1,1) PRIMARY KEY,
  order_id INT NOT NULL,
  payment_method VARCHAR(20) NOT NULL,
  paid_amount DECIMAL(10,2) NOT NULL,
  paid_at DATE NOT NULL
);

INSERT INTO payments (order_id, payment_method, paid_amount, paid_at) VALUES
(1,  'credit_card', 24.99,  '2026-01-06'),
(2,  'credit_card', 89.50,  '2026-02-15'),
(3,  'paypal',      34.00,  '2026-01-21'),
(4,  'credit_card', 45.75,  '2026-03-03'),
(5,  'debit_card',  59.99,  '2026-04-12'),
(6,  'credit_card', 199.99, '2026-01-31'),
(7,  'paypal',      69.25,  '2026-05-07'),
(8,  'credit_card', 109.00, '2026-02-09'),
(9,  'debit_card',  9.99,   '2026-02-10'),
(10, 'credit_card', 79.99,  '2026-06-02'),
(11, 'paypal',      29.99,  '2026-01-16'),
(12, 'credit_card', 64.50,  '2026-03-23'),
(13, 'debit_card',  19.99,  '2026-04-03'),
(14, 'credit_card', 74.00,  '2026-05-01'),
(15, 'paypal',      149.99, '2026-06-19'),
(16, 'credit_card', 39.99,  '2026-02-26'),
(17, 'credit_card', 89.99,  '2026-05-15'),
(18, 'debit_card',  22.50,  '2026-01-11');
SQL
```

Verify:

```bash
PGPASSWORD="$REDSHIFT_MASTER_PASSWORD" psql -h "$REDSHIFT_ENDPOINT" -p 5439 -U "$REDSHIFT_MASTER_USERNAME" -d "$REDSHIFT_DB_NAME" \
  -c "SELECT COUNT(*) FROM payments;"
```

Revert access:

```bash
aws redshift modify-cluster --cluster-identifier $REDSHIFT_CLUSTER_ID --no-publicly-accessible
aws redshift wait cluster-available --cluster-identifier $REDSHIFT_CLUSTER_ID
aws ec2 revoke-security-group-ingress --group-id $REDSHIFT_SG_ID --protocol tcp --port 5439 --cidr "${MY_IP}/32"
```

### 5.6 IAM role for the Redshift connector Lambda

Structurally identical to the MySQL role — `AWSLambdaVPCAccessExecutionRole` (VPC-attached, needs ENI permissions) plus an inline policy scoped to this connector's own secret.

```bash
aws iam create-role \
  --role-name $REDSHIFT_ROLE \
  --assume-role-policy-document file://trust-policy.json

aws iam attach-role-policy \
  --role-name $REDSHIFT_ROLE \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole

cat > redshift-connector-permissions.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SecretAccess",
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "${REDSHIFT_SECRET_ARN}"
    },
    {
      "Sid": "AthenaInvoke",
      "Effect": "Allow",
      "Action": "athena:GetQueryExecution",
      "Resource": "*"
    },
    {
      "Sid": "SpillBucketAccess",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation", "s3:GetObjectVersion",
        "s3:PutObject", "s3:PutObjectAcl", "s3:GetLifecycleConfiguration", "s3:PutLifecycleConfiguration", "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::${SPILL_BUCKET}",
        "arn:aws:s3:::${SPILL_BUCKET}/*"
      ]
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name $REDSHIFT_ROLE \
  --policy-name AthenaRedshiftConnectorPermissions \
  --policy-document file://redshift-connector-permissions.json

export REDSHIFT_ROLE_ARN=$(aws iam get-role --role-name $REDSHIFT_ROLE --query 'Role.Arn' --output text)
```

### 5.7 Create the Redshift connector Lambda function

> **This one can't be deployed as a jar — checked, not assumed.** Lambda's zip-based deployment has a hard 250 MiB (262,144,000 byte) limit on the **unzipped** package size. Downloading `athena-redshift-2026.24.1.jar` and running `unzip -l` on it shows 275,595,798 bytes uncompressed — about 13.5 MB over the limit, regardless of upload method (S3 doesn't change this limit). For reference, MySQL's jar unzips to 245,459,306 bytes — only ~4.6 MB of headroom — and DynamoDB's to 239,233,463 bytes. None of these are comfortably under the limit; Redshift's simply tips over it. This is exactly why AWS's own current SAR template for this connector defaults to `PackageType: Image` rather than a zip upload (confirmed in `athena-redshift/athena-redshift.yaml`) — it's not a preference, the jar doesn't fit any other way.
>
> The fix: deploy from AWS's own pre-built container image instead of a jar. Still fully manual (no SAR, no CloudFormation, no Docker build on your end) — just a different `--code` artifact type on the same `create-function` call. AWS publishes one of these images per connector, per release, at a fixed, predictable repository path that any account can pull from.

```bash
check_vars SUBNET_IDS REDSHIFT_LAMBDA_SG_ID REDSHIFT_ROLE_ARN REDSHIFT_ENDPOINT REDSHIFT_SECRET_NAME AWS_REGION || return 1

export SUBNET_IDS_CSV=$(echo $SUBNET_IDS | tr ' ' ',')

# Account that owns the public connector container images — AWS uses two
# region-specific exceptions (Bahrain, Hong Kong); everywhere else, including
# us-east-1, uses the same account. Mirrors the Fn::If logic in
# athena-redshift.yaml rather than hardcoding one region's value.
case "$AWS_REGION" in
  me-south-1) CONNECTOR_ECR_ACCOUNT=084828588479 ;;
  ap-east-1)  CONNECTOR_ECR_ACCOUNT=183295418215 ;;
  *)          CONNECTOR_ECR_ACCOUNT=292517598671 ;;
esac
export REDSHIFT_IMAGE_URI="${CONNECTOR_ECR_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/athena-federation-repository-redshift:2026.24.1"
echo "Image: $REDSHIFT_IMAGE_URI"
```

`292517598671` is an **AWS-owned account, not yours** — this image is never copied or shared into your account, so it will never show up by browsing your own account's ECR console, and there's no CLI equivalent that lists its contents from the outside either. Its resource policy grants only the specific pull actions Lambda's image-fetch mechanism uses (`BatchGetImage`, `GetDownloadUrlForLayer`, `BatchCheckLayerAvailability`) — not introspection actions like `ecr:DescribeImages` or `ecr:GetRepositoryPolicy`. Trying either of those (even with `--registry-id` set correctly) gets `AccessDeniedException: ... because no resource-based policy allows the ecr:DescribeImages action` — that's expected, not a sign anything is misconfigured on your end, and it tells you nothing about whether the actual image pull will succeed; they're different IAM actions entirely.

The only real test is `create-function` itself:

```bash
aws lambda create-function \
  --function-name redshift-image-check \
  --package-type Image \
  --role $REDSHIFT_ROLE_ARN \
  --code ImageUri=$REDSHIFT_IMAGE_URI \
  --image-config file://redshift-image-config.json

aws lambda delete-function --function-name redshift-image-check
```

If the tag genuinely doesn't exist, this fails immediately with something like `ImageNotFoundException` rather than a permissions error — a clearly different failure mode you'd recognize. Since the real `create-function` call below does the identical check as a side effect, this is only worth running standalone if you want to confirm the image before wiring up the rest of the environment/VPC config.

```bash
cat > redshift-env.json <<EOF
{
  "Variables": {
    "spill_bucket": "${SPILL_BUCKET}",
    "spill_prefix": "athena-spill",
    "disable_spill_encryption": "false",
    "default": "redshift://jdbc:redshift://${REDSHIFT_ENDPOINT}:5439/${REDSHIFT_DB_NAME}?\${${REDSHIFT_SECRET_NAME}}",
    "JAVA_TOOL_OPTIONS": "--add-opens=java.base/java.nio=ALL-UNNAMED"
  }
}
EOF
cat redshift-env.json   # sanity check: "default" should literally contain ${AthenaRedshiftFederationSecret}

# Image package type has no --runtime/--handler (those are zip-only) — the
# entry point is set via --image-config instead, using file:// for the same
# reason --environment does: shorthand syntax mangles nested structures.
cat > redshift-image-config.json <<'EOF'
{
  "Command": ["com.amazonaws.athena.connectors.redshift.RedshiftMuxCompositeHandler"]
}
EOF

aws lambda create-function \
  --function-name $REDSHIFT_LAMBDA \
  --package-type Image \
  --role $REDSHIFT_ROLE_ARN \
  --code ImageUri=$REDSHIFT_IMAGE_URI \
  --image-config file://redshift-image-config.json \
  --memory-size 3008 \
  --timeout 900 \
  --vpc-config SubnetIds=$SUBNET_IDS_CSV,SecurityGroupIds=$REDSHIFT_LAMBDA_SG_ID \
  --environment file://redshift-env.json

aws lambda wait function-active --function-name $REDSHIFT_LAMBDA
```

> No change needed to the IAM role from 5.6 — image-pull permission is governed by the image repository's own resource policy (which AWS has already configured to allow any account to pull, since this is the same mechanism SAR itself relies on to deploy this connector into arbitrary customer accounts), not by anything on your execution role. The role still only governs what the function can do at runtime, which is unchanged.

### 5.8 Register the Redshift Athena Data Catalog

```bash
export REDSHIFT_LAMBDA_ARN=$(aws lambda get-function --function-name $REDSHIFT_LAMBDA --query 'Configuration.FunctionArn' --output text)

aws lambda add-permission \
  --function-name $REDSHIFT_LAMBDA \
  --statement-id AllowAthenaInvoke \
  --action lambda:InvokeFunction \
  --principal athena.amazonaws.com

aws athena create-data-catalog \
  --name $REDSHIFT_CATALOG \
  --type LAMBDA \
  --description "Redshift connector for federation demo" \
  --parameters "function=$REDSHIFT_LAMBDA_ARN"
```

---

## Phase 6: Query each source through Athena

A small helper to run a query and print results (used for every query below):

```bash
run_query () {
  local sql="$1"
  local ctx="$2"   # e.g. "Catalog=dynamodb_catalog,Database=default" — omit for cross-catalog queries
  local qid
  if [ -n "$ctx" ]; then
    qid=$(aws athena start-query-execution \
      --query-string "$sql" \
      --query-execution-context "$ctx" \
      --result-configuration "OutputLocation=s3://${RESULTS_BUCKET}/" \
      --query 'QueryExecutionId' --output text)
  else
    qid=$(aws athena start-query-execution \
      --query-string "$sql" \
      --result-configuration "OutputLocation=s3://${RESULTS_BUCKET}/" \
      --query 'QueryExecutionId' --output text)
  fi

  while true; do
    local qstate=$(aws athena get-query-execution --query-execution-id "$qid" --query 'QueryExecution.Status.State' --output text)
    [[ "$qstate" == "SUCCEEDED" || "$qstate" == "FAILED" || "$qstate" == "CANCELLED" ]] && break
    sleep 2
  done

  if [[ "$qstate" != "SUCCEEDED" ]]; then
    aws athena get-query-execution --query-execution-id "$qid" --query 'QueryExecution.Status.StateChangeReason' --output text
    return 1
  fi
  aws athena get-query-results --query-execution-id "$qid" --output table
}
```

### 6.1 DynamoDB source alone

```bash
run_query "SHOW TABLES IN ${DYNAMODB_CATALOG}.default" "Catalog=${DYNAMODB_CATALOG}"

run_query "SELECT * FROM ${DYNAMODB_CATALOG}.default.customers ORDER BY customer_id" "Catalog=${DYNAMODB_CATALOG}"
```

### 6.2 MySQL source alone

```bash
run_query "SHOW TABLES IN ${MYSQL_CATALOG}.${MYSQL_DB_NAME}" "Catalog=${MYSQL_CATALOG}"

run_query "SELECT * FROM ${MYSQL_CATALOG}.${MYSQL_DB_NAME}.orders ORDER BY order_id" "Catalog=${MYSQL_CATALOG}"
```

### 6.3 Redshift source alone

```bash
run_query "SHOW TABLES IN ${REDSHIFT_CATALOG}.public" "Catalog=${REDSHIFT_CATALOG}"

run_query "SELECT * FROM ${REDSHIFT_CATALOG}.public.payments ORDER BY payment_id" "Catalog=${REDSHIFT_CATALOG}"
```

(Redshift's default schema is `public`, not `default` — that's a Postgres/Redshift convention, unlike DynamoDB's connector which always uses `default`.)

---

## Phase 7: Federated queries — how it works, and running one

**How federated queries work:** when a query references a Lambda-backed catalog, Athena's query engine calls the connector Lambda twice per source, not once. First it invokes the connector's **metadata handler** to learn what tables/columns exist and how the data is split for parallel reads. Then, during execution, it invokes the connector's **record handler** (potentially many times in parallel) to actually fetch rows — each invocation returns an Arrow-encoded batch, spilling to the S3 spill bucket if a batch is too large for the Lambda's memory. Athena's engine collects the rows returned from **every** catalog referenced in the query and performs the actual `JOIN`/aggregation itself — the join logic never runs inside either connector Lambda; each Lambda only ever sees requests for its own source's rows.

Because both sides of the join are resolved through fully-qualified `catalog.database.table` references in the SQL, no single `--query-execution-context` catalog applies — Athena resolves each side independently and joins in its own engine:

```bash
run_query "
SELECT
  o.order_id,
  o.product,
  o.amount,
  o.order_date,
  c.name,
  c.email
FROM ${MYSQL_CATALOG}.${MYSQL_DB_NAME}.orders o
JOIN ${DYNAMODB_CATALOG}.default.customers c
  ON o.customer_id = c.customer_id
ORDER BY o.order_date
"
```

A second example — aggregate spend per customer, still joined live across both sources:

```bash
run_query "
SELECT
  c.customer_id,
  c.name,
  COUNT(o.order_id)  AS order_count,
  SUM(o.amount)       AS total_spent
FROM ${DYNAMODB_CATALOG}.default.customers c
JOIN ${MYSQL_CATALOG}.${MYSQL_DB_NAME}.orders o
  ON c.customer_id = o.customer_id
GROUP BY c.customer_id, c.name
ORDER BY total_spent DESC
"
```

### Three-way federated join

The same mechanism scales to a third catalog with no special syntax — Athena invokes a third connector Lambda for the third source and folds its rows into the same join. This chains all three sources: DynamoDB `customers` → MySQL `orders` → Redshift `payments`, using a `LEFT JOIN` on the last hop so orders 19 and 20 (deliberately left unpaid in Phase 5.5) show up with `NULL` payment columns instead of being dropped:

```bash
run_query "
SELECT
  c.name,
  c.email,
  o.order_id,
  o.product,
  o.amount        AS order_amount,
  p.payment_method,
  p.paid_amount,
  p.paid_at
FROM ${DYNAMODB_CATALOG}.default.customers c
JOIN ${MYSQL_CATALOG}.${MYSQL_DB_NAME}.orders o
  ON c.customer_id = o.customer_id
LEFT JOIN ${REDSHIFT_CATALOG}.public.payments p
  ON o.order_id = p.order_id
ORDER BY o.order_id
"
```

If any query is slow the first time, that's expected — it's a cold-start Lambda invocation for every connector involved, plus VPC ENI attachment latency for the MySQL and Redshift ones; subsequent queries are faster.

---

## Phase 8: dbt as a data quality framework on top of the federated sources

Project files already created at `dbt/athena_federation/` in this repo:

```
dbt/athena_federation/
├── dbt_project.yml
├── profiles.yml.example        # reference only — the real one goes to ~/.dbt/profiles.yml
├── models/
│   ├── staging/
│   │   ├── _sources.yml        # declares dynamodb_catalog.default.customers, mysql_catalog.federation_demo.orders
│   │   ├── _staging.yml        # schema tests, incl. a cross-catalog `relationships` test
│   │   ├── stg_customers.sql   # materializes the DynamoDB source into a Glue-backed table
│   │   └── stg_orders.sql      # materializes the MySQL source into a Glue-backed table
│   └── marts/
│       ├── _marts.yml
│       └── fct_customer_orders.sql   # joins the two staged tables — no Lambda calls at this layer
└── tests/
    └── assert_orders_amount_positive.sql   # singular test example
```

Verified against the actual package (not assumed): `dbt-athena-community` is now just a thin shim that depends on the real package, `dbt-athena` — install `dbt-athena` directly. Current version is `1.10.2`, requires Python ≥3.10.

### 8.1 Install dependencies

```bash
python3 --version   # must be 3.10+; if not: brew install python@3.12
```

Use a virtualenv — this sidesteps Homebrew's Python being "externally managed" (PEP 668), which otherwise blocks a bare `pip install` outright on recent macOS Python installs:

```bash
cd /path/to/learn-athena/dbt/athena_federation
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
pip install "dbt-athena==1.10.2"
dbt --version
```

`source .venv/bin/activate` is identical in bash and zsh — no shell-specific behavior here.

### 8.2 Create the Athena database dbt will materialize models into

dbt needs a Glue-backed Athena database to write its own tables into (separate from `dynamodb_catalog`/`mysql_catalog`, which are federated and read-only). Reusing `$RESULTS_BUCKET` with a distinct prefix avoids standing up another bucket to tear down later.

```bash
check_vars RESULTS_BUCKET AWS_REGION || return 1

run_query "CREATE DATABASE IF NOT EXISTS dbt_athena_federation LOCATION 's3://${RESULTS_BUCKET}/dbt-models/'"
```

(`run_query` is the helper function defined in Phase 6 — re-paste it into this shell if it's not already defined here.)

### 8.3 Write your dbt profile

`profiles.yml` holds environment-specific config (bucket paths, AWS profile) and conventionally lives outside the project directory, at `~/.dbt/profiles.yml` — not committed to the repo. Generated from your already-exported variables, so nothing is hardcoded:

```bash
check_vars RESULTS_BUCKET AWS_REGION AWS_PROFILE || return 1

mkdir -p ~/.dbt
cat > ~/.dbt/profiles.yml <<EOF
athena_federation:
  target: dev
  outputs:
    dev:
      type: athena
      s3_staging_dir: "s3://${RESULTS_BUCKET}/dbt-staging/"
      s3_data_dir: "s3://${RESULTS_BUCKET}/dbt-models/"
      s3_data_naming: schema_table
      region_name: "${AWS_REGION}"
      schema: dbt_athena_federation
      database: awsdatacatalog
      aws_profile_name: "${AWS_PROFILE}"
      threads: 2
      num_retries: 3
EOF
```

If you're not using a named AWS CLI profile (e.g. you're using env-var credentials instead), drop the `aws_profile_name` line — the adapter falls back to standard boto3 credential resolution.

### 8.4 Run it

```bash
cd /path/to/learn-athena/dbt/athena_federation
source .venv/bin/activate   # only needed if this is a new shell

dbt debug     # confirms it can reach Athena/S3/Glue with this profile
dbt run       # builds stg_customers, stg_orders, fct_customer_orders
dbt test      # runs schema tests (not_null/unique/relationships) + the singular test
```

`dbt test` is the actual data-quality framework moment here: the `relationships` test in `_staging.yml` verifies every `customer_id` in the **MySQL** `orders` table actually exists in the **DynamoDB** `customers` table — a referential-integrity check spanning two physically different databases, computed by a single federated Athena query dbt generates and runs for you.

### 8.5 Tear down the dbt-created resources

These aren't covered by the main teardown below since they weren't created by it — do this alongside step 9/10 of the main teardown:

```bash
run_query "DROP TABLE IF EXISTS dbt_athena_federation.fct_customer_orders"
run_query "DROP TABLE IF EXISTS dbt_athena_federation.stg_customers"
run_query "DROP TABLE IF EXISTS dbt_athena_federation.stg_orders"
run_query "DROP DATABASE IF EXISTS dbt_athena_federation"

aws s3 rm "s3://${RESULTS_BUCKET}/dbt-models/" --recursive
aws s3 rm "s3://${RESULTS_BUCKET}/dbt-staging/" --recursive
```

(`$RESULTS_BUCKET` itself is deleted later in the main teardown's step 10 — don't delete it here, just its dbt-specific prefixes, or step 10 will just find it already empty of these objects.)

---

## Teardown — delete everything, in dependency order

Run top to bottom. Each step assumes the variables from Phase 0 are still exported in your shell.

```bash
# 1. Athena data catalogs
aws athena delete-data-catalog --name $DYNAMODB_CATALOG
aws athena delete-data-catalog --name $MYSQL_CATALOG
aws athena delete-data-catalog --name $REDSHIFT_CATALOG

# 2. Lambda functions (this also removes the athena.amazonaws.com invoke permission)
aws lambda delete-function --function-name $DYNAMODB_LAMBDA
aws lambda delete-function --function-name $MYSQL_LAMBDA
aws lambda delete-function --function-name $REDSHIFT_LAMBDA

# 3. IAM roles
aws iam delete-role-policy --role-name $DYNAMODB_ROLE --policy-name AthenaDynamoDBConnectorPermissions
aws iam detach-role-policy --role-name $DYNAMODB_ROLE --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam delete-role --role-name $DYNAMODB_ROLE

aws iam delete-role-policy --role-name $MYSQL_ROLE --policy-name AthenaMySQLConnectorPermissions
aws iam detach-role-policy --role-name $MYSQL_ROLE --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole
aws iam delete-role --role-name $MYSQL_ROLE

aws iam delete-role-policy --role-name $REDSHIFT_ROLE --policy-name AthenaRedshiftConnectorPermissions
aws iam detach-role-policy --role-name $REDSHIFT_ROLE --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole
aws iam delete-role --role-name $REDSHIFT_ROLE

# 4. RDS instance (backup-retention was 0, so no final snapshot exists to manage)
aws rds delete-db-instance \
  --db-instance-identifier $MYSQL_DB_INSTANCE_ID \
  --skip-final-snapshot \
  --delete-automated-backups

aws rds wait db-instance-deleted --db-instance-identifier $MYSQL_DB_INSTANCE_ID

# 5. Redshift cluster (no final snapshot, same reasoning as the RDS instance)
aws redshift delete-cluster \
  --cluster-identifier $REDSHIFT_CLUSTER_ID \
  --skip-final-cluster-snapshot

aws redshift wait cluster-deleted --cluster-identifier $REDSHIFT_CLUSTER_ID

# 6. Subnet groups
aws rds delete-db-subnet-group --db-subnet-group-name $DB_SUBNET_GROUP
aws redshift delete-cluster-subnet-group --cluster-subnet-group-name $REDSHIFT_SUBNET_GROUP

# 7. VPC endpoints
export S3_ENDPOINT_ID=$(aws ec2 describe-vpc-endpoints \
  --filters Name=vpc-id,Values=$VPC_ID Name=service-name,Values=com.amazonaws.$AWS_REGION.s3 \
  --query 'VpcEndpoints[0].VpcEndpointId' --output text)
export SECRETSMANAGER_ENDPOINT_ID=$(aws ec2 describe-vpc-endpoints \
  --filters Name=vpc-id,Values=$VPC_ID Name=service-name,Values=com.amazonaws.$AWS_REGION.secretsmanager \
  --query 'VpcEndpoints[0].VpcEndpointId' --output text)

aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $S3_ENDPOINT_ID $SECRETSMANAGER_ENDPOINT_ID

# 8. Security groups (wait a few seconds after step 7 for ENIs to detach before deleting)
aws ec2 delete-security-group --group-id $RDS_SG_ID
aws ec2 delete-security-group --group-id $REDSHIFT_SG_ID
aws ec2 delete-security-group --group-id $ENDPOINT_SG_ID
aws ec2 delete-security-group --group-id $LAMBDA_SG_ID
aws ec2 delete-security-group --group-id $REDSHIFT_LAMBDA_SG_ID

# 9. DynamoDB table
aws dynamodb delete-table --table-name $DYNAMODB_TABLE

# 10. Secrets Manager secrets (force-delete, no 7-30 day recovery window, since this is a demo)
aws secretsmanager delete-secret \
  --secret-id $MYSQL_SECRET_NAME \
  --force-delete-without-recovery

aws secretsmanager delete-secret \
  --secret-id $REDSHIFT_SECRET_NAME \
  --force-delete-without-recovery

# 11. S3 buckets (empty, then delete)
aws s3 rm s3://$CODE_BUCKET --recursive
aws s3 rb s3://$CODE_BUCKET

aws s3 rm s3://$SPILL_BUCKET --recursive
aws s3 rb s3://$SPILL_BUCKET

aws s3 rm s3://$RESULTS_BUCKET --recursive
aws s3 rb s3://$RESULTS_BUCKET
```

### Verify nothing is left

```bash
aws athena list-data-catalogs --query "DataCatalogsSummary[?CatalogName=='${DYNAMODB_CATALOG}' || CatalogName=='${MYSQL_CATALOG}' || CatalogName=='${REDSHIFT_CATALOG}']"
aws lambda list-functions --query "Functions[?FunctionName=='${DYNAMODB_LAMBDA}' || FunctionName=='${MYSQL_LAMBDA}' || FunctionName=='${REDSHIFT_LAMBDA}']"
aws rds describe-db-instances --query "DBInstances[?DBInstanceIdentifier=='${MYSQL_DB_INSTANCE_ID}']"
aws redshift describe-clusters --query "Clusters[?ClusterIdentifier=='${REDSHIFT_CLUSTER_ID}']"
aws dynamodb list-tables --query "TableNames[?@=='${DYNAMODB_TABLE}']"
aws s3 ls | grep athena-federation
aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC_ID Name=group-name,Values=$LAMBDA_SG_NAME,$RDS_SG_NAME,$ENDPOINT_SG_NAME,$REDSHIFT_LAMBDA_SG_NAME,$REDSHIFT_SG_NAME
```

Every query above should return empty. If any security group deletion in step 8 fails with a dependency error, wait ~30 seconds (ENI detachment from the VPC endpoints/Lambdas lags slightly) and re-run just that step.
