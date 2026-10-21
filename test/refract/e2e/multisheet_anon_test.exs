defmodule Refract.E2E.MultisheetAnonTest do
  use ExUnit.Case, async: true

  @moduletag :e2e
  @moduletag :tmp_dir
  @moduletag timeout: 10_000

  alias Refract.CSV
  alias Refract.DuckDB.Golden
  alias Refract.Privacy.Keyring
  alias Refract.Privacy.Pseudonym
  alias Refract.Query
  alias Refract.Rows

  @keyring Keyring.new!(keys: %{1 => :binary.copy(<<1>>, 32)})
  @letters "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz "
  @opts [alphabet: @letters, min_domain: 0]

  @sql """
  SELECT customer_id, c.name, o.product, o.quantity,
         CAST(p.total_amount AS VARCHAR) AS total_amount, p.payment_date
  FROM orders o
  JOIN customers c USING (customer_id)
  JOIN (
    SELECT customer_id, sum(CAST(amount AS DOUBLE)) AS total_amount, max(date) AS payment_date
    FROM payments
    GROUP BY customer_id
  ) p USING (customer_id)
  ORDER BY customer_id, o.order_id
  """

  setup %{tmp_dir: dir} do
    shapes = Path.join(dir, "out")

    for name <- ["orders", "payments"],
        do: Golden.folder!(shapes, name, [Golden.path("golden/multisheet_anon", name <> ".csv")])

    {:ok, customers} = CSV.stream(Golden.path("golden/multisheet_anon", "customers.csv"))

    private =
      Rows.update(customers, "name", &Pseudonym.apply!(&1, :customer_name, @keyring, @opts))

    query = Query.open!(engine: Refract.Query.DuckDB)
    {:ok, ["orders", "payments"]} = Query.views(query, shapes)
    :ok = Query.table(query, "customers", private, columns: ["customer_id", "name", "email"])

    %{rows: query |> Query.run!(@sql) |> Map.fetch!(:rows) |> Enum.to_list()}
  end

  test "every column but the name matches the expected data", %{rows: rows} do
    expected = Golden.rows!("golden/multisheet_anon", "expected_data.csv")

    assert Enum.map(rows, &Map.delete(&1, "name")) == Enum.map(expected, &Map.delete(&1, "name"))
  end

  test "names are pseudonymised and reverse to the original name", %{rows: rows} do
    expected = Golden.rows!("golden/multisheet_anon", "expected_data.csv")

    lookup =
      Map.new(
        Golden.rows!("golden/multisheet_anon", "expected_lookup.csv"),
        &{&1["original"], &1["translated"]}
      )

    for {row, expected_row} <- Enum.zip(rows, expected) do
      original = Map.fetch!(lookup, expected_row["name"])

      refute row["name"] == original
      assert Pseudonym.reverse!(row["name"], :customer_name, @keyring, @opts) == original
    end
  end
end
