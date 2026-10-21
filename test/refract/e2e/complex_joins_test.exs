defmodule Refract.E2E.ComplexJoinsTest do
  use ExUnit.Case, async: true

  @moduletag :e2e
  @moduletag :tmp_dir
  @moduletag timeout: 10_000

  alias Refract.CSV
  alias Refract.DuckDB.Golden
  alias Refract.Grid
  alias Refract.Query
  alias Refract.Table

  defp grid(name) do
    {:ok, grid} = CSV.load(Golden.path("golden/complex_joins", name <> ".csv"))

    grid
  end

  defp located(grid, columns) do
    spec = Table.spec(header: [columns: Map.new(columns, &{&1, [&1]})])
    {:ok, table} = Grid.locate(grid, spec)

    table
  end

  test "two offset tables load from grids and join with their totals", %{tmp_dir: dir} do
    names = grid("names")
    ages = grid("ages")

    query = Query.open!(engine: Refract.Query.DuckDB)

    :ok = Query.table(query, "names", located(names, ["id", "first_name", "last_name"]))
    :ok = Query.table(query, "ages", located(ages, ["id", "age", "color"]))

    result =
      Query.run!(
        query,
        """
        SELECT id, n.first_name, n.last_name, a.color, a.age,
               $1::VARCHAR AS names_total, $2::VARCHAR AS ages_total
        FROM names n JOIN ages a USING (id)
        ORDER BY id
        """,
        [Grid.value(names, label: "total"), Grid.value(ages, label: "total")]
      )

    out = Path.join(dir, "joined.csv")
    :ok = CSV.write(result.rows, out, header: result.columns)

    assert File.read!(out) == Golden.read!("golden/complex_joins", "expected.csv")
  end
end
