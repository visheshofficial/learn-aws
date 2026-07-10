select
    customer_id,
    name,
    email,
    date(signup_date) as signup_date
from {{ source('dynamodb_catalog', 'customers') }}
