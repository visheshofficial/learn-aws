# Multi-Tenant Athena Federated Queries with Terraform

This extends [`../athena-manual-connector-deployment.md`](../athena-manual-connector-deployment.md) — the manual, single-tenant, raw-AWS-CLI walkthrough — into a Terraform-managed setup that can host any number of isolated tenants on shared connector infrastructure. Same two data sources (DynamoDB + MySQL), same non-SAR jar deployment, same v2026.24.1 connectors. What's different is everything about *how many* of each resource exist and *who can reach what*.

Read this after the single-tenant doc, not instead of it — the connector internals (handler classes, env var formats, required JVM flags, VPC/endpoint requirements) are the same and aren't re-explained here.

---

## What actually changes for multi-tenancy, and why

### The single most important thing to understand first

**One Lambda cannot be "the" connector between Athena and all your data sources.** A connector Lambda *is* a specific jar with a specific handler class — the DynamoDB jar and the MySQL jar are different code with different bundled drivers, and no jar speaks both. **The floor is one Lambda per data source type, always**, regardless of tenant count.

The only real question is: *within* one data source type, do all tenants share one Lambda, or does each tenant get its own? "Multiplexing" is often misread as the answer to the first question when it's actually about the second — it means **one Lambda, one engine, many *instances* of that engine** (many MySQL servers), never many engine types.

That distinction, why DynamoDB has no multiplexing (and doesn't need it), and the full Option A vs Option B analysis for the MySQL Lambda are written up in **[`lambda-topology-options.md`](./lambda-topology-options.md)** — read that before changing any of this. The summary of what got built:

| Decision | Choice | Why |
|---|---|---|
| MySQL topology | **One Lambda per tenant** (Option A), each with a dedicated RDS instance, security groups, Athena Data Catalog and Workgroup | A shared mux'd Lambda is possible, but it would need IAM access to *every* tenant's secret and a network path to *every* tenant's RDS, and it would forfeit the independent-per-tenant-state structure. See the decision doc. |
| DynamoDB topology | **One shared Lambda**, one table per tenant (`tenant_<id>_customers`), one shared Athena Data Catalog, IAM role scoped to the `tenant_*` table-name wildcard | DynamoDB has no per-tenant endpoint or credential to route between — a shared Lambda is the natural shape here, not a compromise |
| Shared networking | One VPC (default VPC), one S3 Gateway endpoint, one Secrets Manager Interface endpoint, one RDS subnet group | Network plumbing, not data access — sharing it doesn't weaken isolation the way sharing compute/credentials would |
| Terraform structure | Six focused modules under `modules/`, instantiated by thin environments under `environments/` — one `shared/` environment plus **one environment per tenant, each with its own state file** | Tenants are fully independent to apply/destroy; onboarding never touches another tenant's state. The `athena-connector` module is shared by the DynamoDB and MySQL connectors alike. |
| Tenant input surface | Just `tenant_id` | Everything else — table names, secret names, catalog names, workgroup names, a generated password — is derived or generated inside the module |

### The second isolation layer: Athena's own IAM

Independent of Lambda topology, Athena's control plane can enforce tenant isolation directly. Pulled from AWS's IAM action definitions (cross-checked against the service's actual resource types):

- `athena:GetDataCatalog`, `GetDatabase`, `GetTableMetadata`, `ListDatabases`, `ListTableMetadata` support **resource-level IAM scoping to a single `datacatalog` ARN** (`arn:aws:athena:region:account:datacatalog/<name>`).
- `athena:StartQueryExecution`, `GetQueryExecution`, `GetQueryResults` and friends support **resource-level IAM scoping to a single `workgroup` ARN**.

So a tenant's query role can be restricted to "only resolve metadata for catalog X, only run queries in workgroup Y" with actual `Resource:`-scoped IAM — not security-through-obscurity. `modules/tenant-access` does exactly this (`aws_iam_role.query`), which is why a tenant cannot query another tenant's catalog **regardless of which Lambda topology you pick**. Per-tenant Lambdas (data-plane isolation) and catalog/workgroup-scoped IAM (control-plane isolation) are defense in depth, not alternatives.

### "Use Athena/Trino"

Athena's query engine (v3) is Trino under the hood. Every tenant's `aws_athena_workgroup` explicitly pins `engine_version.selected_engine_version = "Athena engine version 3"` rather than leaving it to whatever the account default happens to be — so federated joins across catalogs always run on the same, current, Trino-based engine.

---

## Repo layout

Every reusable piece is a module; environments are thin wiring that instantiates them and holds no raw resources of their own.

```
multi-tenant-iac/
├── modules/
│   ├── connector-artifacts/    S3 code/spill/results buckets + connector jar fetch & upload
│   ├── federation-network/     VPC lookup, S3 gateway endpoint, Secrets Manager interface
│   │                           endpoint + its SG, shared RDS subnet group
│   ├── athena-connector/    ★  GENERIC connector: IAM role + policies, Lambda (VPC optional),
│   │                           Athena invoke permission, Athena Data Catalog.
│   │                           Instantiated TWICE — DynamoDB (shared) and MySQL (per tenant)
│   ├── tenant-network/         This tenant's Lambda SG + RDS SG
│   ├── tenant-datastores/      This tenant's DynamoDB table, RDS instance, generated password, secret
│   └── tenant-access/          This tenant's Athena workgroup + scoped query IAM role
│
└── environments/
    ├── shared/                 Applied ONCE. = connector-artifacts + federation-network
    │                             + athena-connector (DynamoDB flavor)
    └── tenant-1/               COPY THIS PER TENANT. = tenant-network + tenant-datastores
                                  + athena-connector (MySQL flavor) + tenant-access
```

**The `athena-connector` module is the point of the whole decomposition.** The DynamoDB connector and every tenant's MySQL connector are the same seven-resource pattern — IAM trust doc, role, execution-policy attachment, data-source policy, Lambda, Athena invoke permission, Data Catalog. They differ only in handler class, jar, environment variables, IAM statements, and whether a VPC is attached. All five are module inputs, so there is exactly one implementation of "an Athena federation connector" in this repo.

### Why `tenant-network` is a separate module

It exists to break a dependency cycle, and this is not obvious until Terraform rejects your config:

- The MySQL Lambda's `default` env var contains the **RDS endpoint** → connector depends on datastore.
- The RDS security group's ingress rule references the **Lambda's security group** → datastore depends on connector.

Owning both security groups in a third module that depends on nothing makes the graph acyclic. The actual module graph, from `tofu graph`:

```
tenant-network ──> tenant-datastores ──> athena-connector ──> tenant-access
       └────────────────────────────────────────┘
```

All modules and both environments were run through `tofu validate` (OpenTofu — Terraform's open-source fork; same HCL, same providers) against the real `hashicorp/aws` v5 provider schema, so the resource arguments here aren't guessed. Everywhere this doc says `terraform`, `tofu` works identically.

---

## Prerequisites

- Terraform ≥ 1.7 (`terraform -version`) or OpenTofu (`tofu -version`)
- AWS CLI v2, configured with the same permissions as the single-tenant doc's prerequisites, plus `iam:CreateRole`/`PutRolePolicy` for the new per-tenant query roles
- `curl` — the `shared` stack's `null_resource.connector_jars` shells out to it (and to `aws s3 cp`) to fetch the connector jars at apply time
- A `mysql` client, for the same seeding purpose as the single-tenant doc (see that doc's Prerequisites for the macOS `mysql-shell` vs `mysql-client` gotcha — it applies here unchanged)

---

## Phase 1: Deploy the shared environment (once)

```bash
cd multi-tenant-iac/environments/shared
terraform init
terraform plan
terraform apply
```

This instantiates `connector-artifacts` (the three S3 buckets, plus both connector jars fetched from the GitHub release and uploaded), `federation-network` (the S3 Gateway + Secrets Manager Interface VPC endpoints and the shared RDS subnet group), and `athena-connector` in its DynamoDB flavor (Lambda, IAM role scoped to `tenant_*` tables, Athena Data Catalog). Nothing tenant-specific exists yet.

```bash
terraform output
```

Every tenant environment reads this state via `terraform_remote_state`, pointed at `../shared/terraform.tfstate` by default.

---

## Phase 2: Onboard your first tenant

Copy the tenant environment — this is the whole onboarding mechanism:

```bash
cp -r multi-tenant-iac/environments/tenant-1 multi-tenant-iac/environments/acme
cd multi-tenant-iac/environments/acme
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` — the only line that needs to change:

```hcl
tenant_id = "acme"
```

```bash
terraform init
terraform apply
```

This creates, for `acme` alone: a DynamoDB table (`tenant_acme_customers`), a dedicated RDS MySQL instance, a dedicated MySQL connector Lambda + security groups, a Secrets Manager secret, a dedicated `mysql_catalog_acme` Athena Data Catalog, a dedicated `tenant_acme_workgroup` (engine v3), and a dedicated `tenant_acme_query_role` IAM role scoped to only that workgroup and only `acme`'s two catalogs (its own MySQL catalog + the shared DynamoDB catalog).

```bash
terraform output
```

Note the values — `rds_endpoint`, `mysql_secret_name`, `dynamodb_table_name`, `mysql_catalog_name`, `workgroup_name`, `query_role_arn`. The next two phases use them directly.

---

## Phase 3: Seed synthetic data for this tenant

### DynamoDB

```bash
TABLE=$(terraform output -raw dynamodb_table_name)

aws dynamodb put-item --table-name "$TABLE" --item '{
  "customer_id": {"S": "CUST001"}, "name": {"S": "Alice Johnson"},
  "email": {"S": "alice.johnson@example.com"}, "signup_date": {"S": "2025-01-12"}
}'
aws dynamodb put-item --table-name "$TABLE" --item '{
  "customer_id": {"S": "CUST002"}, "name": {"S": "Brian Lee"},
  "email": {"S": "brian.lee@example.com"}, "signup_date": {"S": "2025-02-03"}
}'
```

(Add as many as you like — same pattern as the single-tenant doc's Phase 3.2.)

### MySQL

Same temporary-access pattern as the single-tenant doc: this tenant's RDS instance is private by default, so briefly open it to your own IP, seed it, then close it again.

Everything below comes from Terraform outputs — nothing is derived from a naming convention, so this works unchanged for any tenant id.

```bash
RDS_ENDPOINT=$(terraform output -raw rds_endpoint)
RDS_INSTANCE_ID=$(terraform output -raw rds_instance_id)
RDS_SG_ID=$(terraform output -raw rds_security_group_id)
SECRET_NAME=$(terraform output -raw mysql_secret_name)
DB_NAME=$(terraform output -raw mysql_database_name)
MY_IP=$(curl -s https://checkip.amazonaws.com)

MYSQL_PASSWORD=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --query SecretString --output text | jq -r .password)
MYSQL_USERNAME=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --query SecretString --output text | jq -r .username)

aws ec2 authorize-security-group-ingress --group-id "$RDS_SG_ID" --protocol tcp --port 3306 --cidr "${MY_IP}/32"
aws rds modify-db-instance --db-instance-identifier "$RDS_INSTANCE_ID" --publicly-accessible --apply-immediately
aws rds wait db-instance-available --db-instance-identifier "$RDS_INSTANCE_ID"
```

```bash
mysql -h "$RDS_ENDPOINT" -P 3306 -u "$MYSQL_USERNAME" -p"$MYSQL_PASSWORD" "$DB_NAME" <<'SQL'
CREATE TABLE orders (
  order_id INT PRIMARY KEY AUTO_INCREMENT,
  customer_id VARCHAR(10) NOT NULL,
  product VARCHAR(100) NOT NULL,
  amount DECIMAL(10,2) NOT NULL,
  order_date DATE NOT NULL
);

INSERT INTO orders (customer_id, product, amount, order_date) VALUES
('CUST001', 'Wireless Mouse',      24.99, '2026-01-05'),
('CUST002', 'USB-C Hub',           34.00, '2026-01-20');
SQL
```

Revert access:

```bash
aws rds modify-db-instance --db-instance-identifier "$RDS_INSTANCE_ID" --no-publicly-accessible --apply-immediately
aws rds wait db-instance-available --db-instance-identifier "$RDS_INSTANCE_ID"
aws ec2 revoke-security-group-ingress --group-id "$RDS_SG_ID" --protocol tcp --port 3306 --cidr "${MY_IP}/32"
```

---

## Phase 4: Query as this tenant — proving the isolation boundary is real, not just documented

Assume `acme`'s scoped query role rather than using your own admin credentials, so you're actually exercising the IAM boundary the Terraform built:

```bash
QUERY_ROLE_ARN=$(terraform output -raw query_role_arn)
WORKGROUP=$(terraform output -raw workgroup_name)
MYSQL_CATALOG=$(terraform output -raw mysql_catalog_name)
DYNAMODB_CATALOG=$(aws athena list-data-catalogs --query "DataCatalogsSummary[?ends_with(CatalogName, 'dynamodb_catalog')].CatalogName | [0]" --output text)

CREDS=$(aws sts assume-role --role-arn "$QUERY_ROLE_ARN" --role-session-name acme-query)
export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .Credentials.AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .Credentials.SecretAccessKey)
export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .Credentials.SessionToken)
```

Run the same federated join pattern as the single-tenant doc, now inside `acme`'s own workgroup:

```bash
QID=$(aws athena start-query-execution \
  --query-string "SELECT o.order_id, o.product, o.amount, c.name, c.email
                   FROM ${MYSQL_CATALOG}.$(terraform output -raw mysql_database_name).orders o
                   JOIN ${DYNAMODB_CATALOG}.default.customers c ON o.customer_id = c.customer_id" \
  --work-group "$WORKGROUP" \
  --query 'QueryExecutionId' --output text)

sleep 5
aws athena get-query-results --query-execution-id "$QID" --output table
```

That succeeds. Now prove the boundary by trying to reach *nothing* — a catalog `acme`'s role was never granted:

```bash
aws athena start-query-execution \
  --query-string "SHOW TABLES IN some_other_tenant_catalog.default" \
  --work-group "$WORKGROUP"
```

Expect `AccessDeniedException` — `acme`'s role has no `athena:GetDataCatalog`/`GetTableMetadata` permission on any catalog but its own MySQL catalog and the shared DynamoDB catalog. Once you've onboarded a second tenant (next phase), you can point this at their real catalog name for a concrete cross-tenant denial instead of a nonexistent one.

Drop the assumed-role credentials when done:

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
```

---

## Phase 5: Onboard a second tenant

Repeat Phase 2 exactly, with a different id:

```bash
cp -r multi-tenant-iac/environments/tenant-1 multi-tenant-iac/environments/globex
cd multi-tenant-iac/environments/globex
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: tenant_id = "globex"
terraform init
terraform apply
```

`acme` and `globex` now share only the DynamoDB Lambda, the VPC, the two VPC endpoints, and the S3 buckets (each under their own prefix). Separate RDS instances, separate Lambdas, separate security groups, separate secrets, separate workgroups. Re-run the Phase 4 denial check using `globex`'s real `mysql_catalog_name` output as the target, from `acme`'s assumed role — confirms the isolation holds against a real, existing catalog, not just a made-up name.

---

## Teardown

Destroy tenants first (any order, they don't depend on each other), shared last — shared's resources (VPC endpoints, DynamoDB Lambda, S3 buckets) are depended on by every tenant config via remote state, so destroying shared first would strand tenant resources with dangling references.

```bash
cd multi-tenant-iac/environments/acme && terraform destroy
cd ../globex && terraform destroy
cd ../shared  && terraform destroy
```

If a tenant's RDS instance is still flagged `publicly-accessible` from an interrupted Phase 3 (you skipped the revert step), `terraform destroy` will still delete it fine — the temporary security-group rule just gets deleted along with the security group itself.

---

## Taking this to production

This doc optimized for "runnable without any extra bootstrapping" — local Terraform state, default VPC, curl-based jar fetch. Before using this for anything real:

- Swap `backend "local"` for `backend "s3"` (with state locking) in every `versions.tf` — the `terraform_remote_state` blocks in tenant configs only need their `config` block updated to match, nothing else changes.
- Replace `assumable_by_arns` defaults (account root) with your actual per-tenant application/user role ARNs — account-root-assumable is a placeholder, not a real trust boundary.
- Consider a dedicated (non-default) VPC per the same reasoning as the single-tenant doc, if the default VPC isn't acceptable in your account.
- The `null_resource.connector_jars` local-exec pattern is fine for a demo; a real pipeline would fetch/verify/upload the jars in CI before `terraform apply` runs, so `apply` doesn't depend on GitHub being reachable from whatever machine is running Terraform.
