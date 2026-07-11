# Connector Lambda Topology: Option A vs Option B

Decision doc for how many connector Lambdas a multi-tenant Athena federation setup should run, and why. Everything below was verified against the `aws-athena-query-federation` source at tag `v2026.24.1` — file/class references are included so you can check the claims yourself.

---

## First: clear up what a connector Lambda actually is

A common starting assumption — and the one we started with — is *"there will be one Lambda that acts as the connector between Athena and all our data sources."*

**That is not possible.** A connector Lambda **is** a specific connector jar with a specific handler class:

| Data source | Jar | Handler class |
|---|---|---|
| DynamoDB | `athena-dynamodb-2026.24.1.jar` | `com.amazonaws.athena.connectors.dynamodb.DynamoDBCompositeHandler` |
| MySQL | `athena-mysql-2026.24.1.jar` | `com.amazonaws.athena.connectors.mysql.MySqlMuxCompositeHandler` |

Different code, different bundled drivers. There is no jar that speaks both protocols.

**So the floor is one Lambda per data source type, always** — regardless of tenant count. DynamoDB + MySQL means a minimum of 2 connector Lambdas even for a single tenant. This is the connector architecture, not a design choice available to us.

The only question that remains is: **within a single data source type, do all tenants share one Lambda, or does each tenant get its own?**

---

## Second: what "multiplexing" means (and does not mean)

The MySQL connector's handler is called `MySqlMux**CompositeHandler**` and the SDK class behind it is `MultiplexingJdbcMetadataHandler`. The name invites a misreading.

**Multiplexing does NOT mean "one Lambda, many data source types."**

`MySqlMuxMetadataHandler` is constructed with a `MySqlMetadataHandlerFactory` whose `getEngine()` returns the constant `"mysql"`. `DatabaseConnectionConfigBuilder.extractDatabaseConnectionConfig()` then hard-validates every connection string against it:

```java
Validate.isTrue(dbType.equals(this.engine), "JDBC Connection string must be prepended by correct database type.");
```

Hand a MySQL mux Lambda a `postgres://...` connection string and it throws. It speaks MySQL and only MySQL.

**Multiplexing means: one Lambda, one engine, many *instances* of that engine.** One MySQL Lambda can serve tenant A's RDS instance, tenant B's RDS instance, and tenant C's RDS instance, each surfaced to Athena as its own Data Catalog, routed by an environment variable per catalog:

```
default                             = mysql://jdbc:mysql://<some-tenant>-rds:3306/app_db?${some-secret}
acme_catalog_connection_string      = mysql://jdbc:mysql://acme-rds:3306/app_db?${acme-secret}
globex_catalog_connection_string    = mysql://jdbc:mysql://globex-rds:3306/app_db?${globex-secret}
```

(The `<catalog>_connection_string` suffix convention is parsed in `DatabaseConnectionConfigBuilder.build()`.)

## Third: why DynamoDB has no multiplexing — and why that's not a limitation

DynamoDB's connector has no mux handler, which looks like a gap until you ask what there would be to multiplex.

| | MySQL | DynamoDB |
|---|---|---|
| What *is* a tenant's data source? | A separate server, with its own hostname and its own credentials | Just a different table name, in the same AWS account and region |
| To reach tenant B's data, the Lambda needs… | A different endpoint **and** a different secret — so it needs a routing mechanism (= multiplexing) | Nothing. Its IAM role already covers the table. It just queries a different table name. |
| Sharing one Lambda across tenants is… | Possible, via multiplexing | The natural, default behavior |

DynamoDB has nothing to multiplex — there is no per-tenant endpoint and no per-tenant credential to route between. **One shared DynamoDB connector Lambda serving every tenant's table is the normal shape, not a compromise.**

This is why the two connectors look asymmetric in our design. It is not "MySQL has a feature DynamoDB lacks." It is "MySQL needs a mechanism that DynamoDB has no use for."

---

## The actual decision: Option A vs Option B (MySQL only)

Since DynamoDB is settled (one shared Lambda, per-tenant tables named `tenant_<id>_*`), the only open question is the MySQL connector.

### Option A — one MySQL connector Lambda per tenant

*This is what is currently built in `modules/tenant/`.*

Each tenant's `terraform apply` creates that tenant's own Lambda, pointed at that tenant's own RDS instance via a single `default` connection string.

**Created per tenant:** RDS instance · **Lambda** · **Lambda IAM role** · 2 security groups · Secrets Manager secret · Athena Data Catalog · Athena Workgroup · query IAM role

**Onboarding a tenant:**
```bash
cp -r environments/example-tenant environments/globex
cd environments/globex
# set tenant_id = "globex" in terraform.tfvars
terraform apply        # one apply, one state file, nothing else in the system is touched
```

### Option B — one shared, multiplexed MySQL connector Lambda

One Lambda in the `shared/` stack, carrying one `<catalog>_connection_string` environment variable per tenant.

**Created per tenant:** RDS instance · security group · Secrets Manager secret · Athena Data Catalog · Athena Workgroup · query IAM role
**Not created per tenant:** Lambda, Lambda IAM role

**Onboarding a tenant:**
```bash
cd environments/globex && terraform apply     # creates globex's RDS + secret
cd ../../shared        && terraform apply     # THEN adds globex's connection string to the shared Lambda
```

---

## Comparison

| | Option A: Lambda per tenant | Option B: one shared mux'd Lambda |
|---|---|---|
| Lambdas at N tenants | N (+1 shared DynamoDB) | 1 (+1 shared DynamoDB) |
| Tenant onboarding | One `terraform apply`, in the tenant's own state | **Two** applies, in order — tenant, then shared |
| Tenant states independent? | **Yes** | **No** — every onboard/offboard mutates shared state that all tenants depend on |
| Lambda IAM role can read… | Only that tenant's secret | **Every** tenant's secret |
| Lambda network path reaches… | Only that tenant's RDS | **Every** tenant's RDS |
| Blast radius if the Lambda is compromised | One tenant | **All tenants' databases** |
| Cross-tenant query prevention (Athena IAM) | Yes | Yes — identical, this layer is independent of topology |
| Cost | Negligible difference — Lambda bills per invocation, not idle |
| Scales to hundreds of tenants? | Lambda function sprawl becomes an ops/limits problem | Yes, this is where B wins |

### Three specific things about Option B worth knowing

**1. It forfeits the independent-per-tenant-state structure — the biggest issue.** The shared Lambda's environment variables must enumerate every tenant's connection string. But a tenant's RDS endpoint and secret name only exist *after* that tenant's apply. So onboarding requires a second apply against `shared/`, mutating state that every other tenant depends on. A botched `shared` apply can break MySQL querying for **all** tenants simultaneously. Option A has no such coupling — the tenant's Lambda is created in the tenant's own state, and the shared stack never learns the tenant exists.

**2. The mux handler requires a `default` connection string.** From `JDBCUtil.createJdbcMetadataHandlerMap()`:

```java
if (!defaultPresent) {
    throw new AthenaConnectorException("Must provide connection parameters for default database instance " + ...);
}
```

A shared Lambda must therefore nominate one arbitrary tenant's database as `default`. Functionally harmless, but it leaves one tenant structurally privileged, and the catalog `lambda:<function-name>` silently resolves to their database.

**3. Athena's IAM catalog/workgroup scoping protects you in *both* options.** Athena supports resource-level IAM on `datacatalog` and `workgroup` ARNs, so a tenant's query role can be restricted to only its own catalogs and workgroup. A tenant cannot query another tenant's catalog under either option. What Option B gives up is *defense in depth* — if the Lambda process itself is compromised (say a dependency vulnerability in the connector), it holds the credentials and network reachability for every tenant's database.

---

## Recommendation: Option A

**Given the choices already made, Option A is the coherent one.** We are paying for a dedicated RDS instance per tenant — that is the expensive isolation decision, already taken. Option B would then funnel every tenant's database credentials and network access through a single shared Lambda, which gives back much of what the dedicated RDS bought, *and* forfeits the independent-state structure we deliberately chose. The cost saving is close to zero, because Lambda does not bill for idle functions.

Option B is a coherent design — but in a system that also pooled RDS (shared instance, per-tenant schemas and MySQL users). That is a consistent "cheap and shared" posture. Dedicated RDS + shared Lambda is an awkward middle: it pays for the expensive half of isolation and skips the free half.

**The one scenario that flips this:** tenant counts in the high hundreds. Then per-tenant Lambda sprawl becomes a real operational problem (function limits, apply times, deploy blast radius), and Option B — or a broader rethink toward pooled RDS with per-tenant schemas — becomes the right call.
