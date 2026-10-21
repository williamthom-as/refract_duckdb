fixtures
========

copied from refract core test fixtures, the joins need core and this engine together

dir                       from                                  used by
golden/simple_joins       core golden simple_joins              simple joins e2e
golden/complex_joins      core golden complex_joins             complex joins e2e
golden/multisheet_anon    core golden multisheet_anon           multisheet anon e2e
inbox/aws_bill.csv        core inbox aws_bill.csv               pseudonymised join e2e
inbox/aws_bill_october.csv core inbox aws_bill_october.csv      pseudonymised join e2e

refract differs
===============

multisheet_anon expected names come from a cure translation table so names are checked by reverse not by value
multisheet_anon total_amount is the sum of payment amounts per customer as a double cast to text giving 70.0
multisheet_anon payment_date is the latest payment date per customer
complex_joins totals are passed as params cast to varchar since a bare param in the select list has no type
