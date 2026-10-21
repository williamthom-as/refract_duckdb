defmodule Refract.Query.DuckDBTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @moduletag timeout: 10_000

  alias Refract.Query
  alias Refract.Query.DuckDB
  alias Refract.Table

  defp open!(opts \\ []), do: Query.open!([engine: DuckDB] ++ opts)

  defp folder!(dir, name, files) do
    path = Path.join(dir, name)
    File.mkdir_p!(path)

    for {file, content} <- files, do: File.write!(Path.join(path, file), content)

    path
  end

  defp select!(%Query{state: %DuckDB{connection: connection}}, sql) do
    {:ok, result} = Duckdbex.query(connection, sql)

    Duckdbex.fetch_all(result)
  end

  describe "open/1" do
    test "a session holds a database and a connection" do
      assert {:ok, %Query{engine: DuckDB, state: %DuckDB{} = state}} = Query.open(engine: DuckDB)

      assert is_reference(state.database)
      assert is_reference(state.connection)
    end

    test "path: keeps the database in a file", %{tmp_dir: dir} do
      path = Path.join(dir, "refract.duckdb")

      assert {:ok, _query} = Query.open(engine: DuckDB, path: path)
      assert File.exists?(path)
    end

    test "unknown options raise" do
      assert_raise ArgumentError, ~r/colour/, fn -> Query.open(engine: DuckDB, colour: :blue) end
    end
  end

  describe "views/3" do
    test "a folder reads as one view across its files", %{tmp_dir: dir} do
      folder!(dir, "invoice", [{"a.csv", "sku,total\n1,3\n"}, {"b.csv", "sku,total\n2,5\n"}])
      query = open!()

      assert {:ok, ["invoice"]} = Query.views(query, dir)

      assert select!(query, "SELECT sku, total FROM invoice ORDER BY sku") == [
               ["1", "3"],
               ["2", "5"]
             ]
    end

    test "files with different columns join by name, missing cells nil", %{tmp_dir: dir} do
      folder!(dir, "invoice", [{"a.csv", "sku,total\n1,3\n"}, {"b.csv", "sku,kg\n2,4\n"}])
      query = open!()

      assert {:ok, ["invoice"]} = Query.views(query, dir)

      assert select!(query, "SELECT sku, total, kg FROM invoice ORDER BY sku") == [
               ["1", "3", nil],
               ["2", nil, "4"]
             ]
    end

    test "ids with leading zeros stay text", %{tmp_dir: dir} do
      folder!(dir, "accounts", [{"a.csv", "id\n007\n"}])
      query = open!()

      assert {:ok, ["accounts"]} = Query.views(query, dir)
      assert select!(query, "SELECT id FROM accounts") == [["007"]]
    end

    test "types: :infer types the columns", %{tmp_dir: dir} do
      folder!(dir, "invoice", [{"a.csv", "sku,total\n7,3.5\n"}])
      query = open!()

      assert {:ok, ["invoice"]} = Query.views(query, dir, types: :infer)
      assert [[sku, total]] = select!(query, "SELECT sku, total FROM invoice")
      assert is_integer(sku)
      refute is_binary(total)
    end
  end

  describe "view/4" do
    test "a glob across nested folders reads as one view", %{tmp_dir: dir} do
      folder!(dir, "aws_bill/2026-09", [{"a.csv", "account,cost\n1,2\n"}])
      folder!(dir, "aws_bill/2026-10", [{"b.csv", "account,cost\n1,3\n"}])
      query = open!()

      assert :ok = Query.view(query, "bills", Path.join([dir, "aws_bill", "*", "*.csv"]))
      assert select!(query, "SELECT count(*) FROM bills") == [[2]]
    end
  end

  describe "table/4" do
    test "a located table loads as text columns in header order" do
      spec = Table.spec(header: [columns: %{"sku" => ["sku"], "item" => ["item"]}])
      {:ok, table} = Refract.CSV.locate({:string, "sku,item\n001,apple\n2,pear\n"}, spec)
      query = open!()

      assert :ok = Query.table(query, "names", table)
      assert select!(query, "SELECT * FROM names") == [["001", "apple"], ["2", "pear"]]
    end

    test "rows load in the order of columns:, missing cells nil" do
      query = open!()

      assert :ok =
               Query.table(query, "names", [%{"a" => "1", "b" => "2"}, %{"a" => "3"}],
                 columns: ["b", "a"]
               )

      assert select!(query, "SELECT * FROM names") == [["2", "1"], [nil, "3"]]
    end
  end

  describe "run/3" do
    defp rows!(query, sql, params \\ []) do
      {:ok, result} = Query.run(query, sql, params)

      Enum.to_list(result.rows)
    end

    test "decimals come back as Decimal" do
      assert [%{"d" => d, "n" => n}] =
               rows!(open!(), "SELECT 2.55::DECIMAL(18, 2) AS d, (-2.55)::DECIMAL(18, 2) AS n")

      assert d == Decimal.new("2.55")
      assert n == Decimal.new("-2.55")
    end

    test "dates, timestamps and times come back as Elixir values" do
      sql =
        "SELECT DATE '2026-10-21' AS d, TIMESTAMP '2026-10-21 09:30:00.123456' AS ts, TIME '09:30:00' AS t"

      assert rows!(open!(), sql) == [
               %{
                 "d" => ~D[2026-10-21],
                 "ts" => ~N[2026-10-21 09:30:00.123456],
                 "t" => ~T[09:30:00.000000]
               }
             ]
    end

    test "huge integers come back as integers" do
      assert rows!(open!(), "SELECT 170141183460469231731687303715884105727::HUGEINT AS h") == [
               %{"h" => 170_141_183_460_469_231_731_687_303_715_884_105_727}
             ]
    end

    test "text, integers, doubles, booleans and nulls are unchanged" do
      assert rows!(open!(), "SELECT 'x' AS s, 42 AS i, 1.5::DOUBLE AS f, true AS b, NULL AS n") ==
               [
                 %{"s" => "x", "i" => 42, "f" => 1.5, "b" => true, "n" => nil}
               ]
    end

    test "a result larger than one chunk streams in full" do
      {:ok, result} = Query.run(open!(), "SELECT range AS n FROM range(5000)")

      assert Enum.take(result.rows, 2) == [%{"n" => 0}, %{"n" => 1}]
      assert Enum.count(result.rows) == 5000
    end

    test "a typed view gives typed values", %{tmp_dir: dir} do
      folder!(dir, "invoice", [{"a.csv", "sku,total\n7,3.5\n"}])
      query = open!()

      {:ok, ["invoice"]} = Query.views(query, dir, types: :infer)

      assert rows!(query, "SELECT sku, total FROM invoice") == [%{"sku" => 7, "total" => 3.5}]
    end

    test "integer params bind" do
      assert rows!(open!(), "SELECT x FROM (SELECT 7 AS x) WHERE x = $1", [7]) == [%{"x" => 7}]
    end

    test "a statement that is not a query is a query error" do
      assert {:error, {:query_error, _message}} =
               Query.run(open!(), "CREATE TABLE t (a INTEGER)")
    end
  end
end
