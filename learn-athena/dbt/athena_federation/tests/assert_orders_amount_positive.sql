-- Singular test: fails (returns rows) if any order amount is zero or negative.
select order_id, amount
from {{ ref('stg_orders') }}
where amount <= 0
