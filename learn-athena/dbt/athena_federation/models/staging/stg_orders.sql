select
    order_id,
    customer_id,
    product,
    amount,
    order_date
from {{ source('mysql_catalog', 'orders') }}
