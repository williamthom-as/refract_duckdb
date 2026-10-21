defmodule Refract.E2E.PseudonymisedJoinTest do
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
  alias Refract.Table

  @keyring Keyring.new!(keys: %{1 => :binary.copy(<<1>>, 32)})

  @bills ["aws_bill.csv", "aws_bill_october.csv"]

  @columns %{
    "account" => ["lineitem/usageaccountid", "usage account id"],
    "service" => ["lineitem/productcode", "service"],
    "usage_start" => ["lineitem/usagestartdate", "usage start date"],
    "cost" => ["lineitem/unblendedcost", "unblended cost"]
  }

  @sql """
  SELECT account, s.cost AS september, o.cost AS october
  FROM (
    SELECT account, sum(CAST(cost AS DECIMAL(18, 2))) AS cost
    FROM aws_bill WHERE usage_start LIKE '2026-09%' GROUP BY account
  ) s
  JOIN (
    SELECT account, sum(CAST(cost AS DECIMAL(18, 2))) AS cost
    FROM aws_bill WHERE usage_start LIKE '2026-10%' GROUP BY account
  ) o USING (account)
  ORDER BY account
  """

  defp shape_folders(dir, private) do
    folder = Path.join([dir, "aws_bill"])
    File.mkdir_p!(folder)
    spec = Table.spec(header: [columns: @columns, required: ["account", "cost"]])

    for bill <- @bills do
      {:ok, table} = CSV.locate(Golden.path("inbox", bill), spec)

      :ok =
        table.rows
        |> private.()
        |> CSV.write(Path.join(folder, bill), header: Enum.sort(Map.keys(@columns)))
    end

    dir
  end

  defp joined(dir) do
    query = Query.open!(engine: Refract.Query.DuckDB)
    {:ok, ["aws_bill"]} = Query.views(query, dir)

    query |> Query.run!(@sql) |> Map.fetch!(:rows) |> Enum.to_list()
  end

  test "a join on pseudonymised accounts equals the raw join once reversed", %{tmp_dir: dir} do
    raw = dir |> Path.join("raw") |> shape_folders(& &1) |> joined()

    private =
      dir
      |> Path.join("private")
      |> shape_folders(
        &Rows.update(&1, "account", fn account ->
          Pseudonym.apply!(account, :aws_account, @keyring)
        end)
      )
      |> joined()

    assert raw == [
             %{
               "account" => "123456789012",
               "september" => Decimal.new("1.28"),
               "october" => Decimal.new("1.30")
             }
           ]

    refute private == raw

    assert Rows.update(private, "account", &Pseudonym.reverse!(&1, :aws_account, @keyring))
           |> Enum.to_list() == raw
  end
end
