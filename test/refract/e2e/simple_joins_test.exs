defmodule Refract.E2E.SimpleJoinsTest do
  use ExUnit.Case, async: true

  @moduletag :e2e
  @moduletag :tmp_dir
  @moduletag timeout: 10_000

  alias Refract.CSV
  alias Refract.DuckDB.Golden
  alias Refract.Query

  test "names and ages folders join on identifier", %{tmp_dir: dir} do
    shapes = Path.join(dir, "out")

    for name <- ["names", "ages"],
        do: Golden.folder!(shapes, name, [Golden.path("golden/simple_joins", name <> ".csv")])

    query = Query.open!(engine: Refract.Query.DuckDB)

    assert {:ok, ["ages", "names"]} = Query.views(query, shapes)

    result =
      Query.run!(
        query,
        "SELECT identifier, n.name, a.age FROM names n JOIN ages a USING (identifier) ORDER BY identifier"
      )

    out = Path.join(dir, "joined.csv")
    :ok = CSV.write(result.rows, out, header: result.columns)

    assert File.read!(out) == Golden.read!("golden/simple_joins", "expected.csv")
  end
end
