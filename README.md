# refract_duckdb

duckdb query engine for [refract](https://github.com/williamthom-as/refract)'s `Refract.Query`.

- `Refract.Query.DuckDB` implements `Refract.Query.Engine`, built on `duckdbex` (DuckDB 1.5)
- in memory by default, or a database file with `path:`
- Views: one name per folder of csv files (`Refract.Query.views/3`), read as text by default but can use `types: :infer` to let DuckDB type them
- Tables: located tables or via any rows loaded straight in (`Refract.Query.table/4`)
- Results: DuckDB types come back as `Decimal`, `Date`, `NaiveDateTime`, `Time`, integers, floats, booleans, text and nil

```elixir
query = Refract.Query.open!(engine: Refract.Query.DuckDB)

{:ok, ["bill"]} = Refract.Query.views(query, "out")
:ok = Refract.Query.table(query, "customers", customers, columns: ["customer", "plan"])

result = Refract.Query.run!(query, "SELECT plan, count(*) AS bills FROM bill JOIN customers USING (customer) GROUP BY plan")
```

## Install

```elixir
{:refract, path: "../refract"},
{:refract_duckdb, path: "../refract_duckdb"}
```
