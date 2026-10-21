defmodule Refract.Query.DuckDB do
  @moduledoc """
  duckdb query engine for `Refract.Query`. in memory by default, or a database file via `path:`.

      {:ok, query} = Refract.Query.open(engine: Refract.Query.DuckDB)
      {:ok, query} = Refract.Query.open(engine: Refract.Query.DuckDB, path: "refract.duckdb")
  """

  @behaviour Refract.Query.Engine

  alias Refract.Errors.QueryError

  defstruct [:database, :connection, :closed]

  @type t :: %__MODULE__{
          database: reference(),
          connection: reference(),
          closed: :atomics.atomics_ref()
        }

  @spec open(keyword()) :: {:ok, t()} | {:error, term()}

  @impl Refract.Query.Engine
  def open(opts) do
    opts = Keyword.validate!(opts, path: nil)
    path = Keyword.fetch!(opts, :path)

    validate_path(path)

    with {:ok, database} <- database(path),
         {:ok, connection} <- Duckdbex.connection(database) do
      {:ok, %__MODULE__{database: database, connection: connection, closed: :atomics.new(1, [])}}
    end
  end

  @spec view(t(), String.t(), String.t(), [Refract.Query.view_opt()]) :: :ok | {:error, term()}

  @impl Refract.Query.Engine
  def view(%__MODULE__{} = state, name, glob, opts) do
    types = Keyword.fetch!(opts, :types)
    format = Keyword.fetch!(opts, :format)

    with {:ok, source} <- source(format, glob, types) do
      execute(state, "CREATE VIEW #{name} AS SELECT * FROM #{source}")
    end
  end

  @spec table(t(), String.t(), [String.t()], Enumerable.t()) :: :ok | {:error, term()}

  @impl Refract.Query.Engine
  def table(%__MODULE__{} = state, name, columns, rows) do
    with :ok <- execute(state, "CREATE TABLE #{name} (#{column_definitions(columns)})"),
         {:ok, appender} <- Duckdbex.appender(state.connection, name) do
      append(appender, rows)
    end
  end

  @spec run(t(), String.t(), list()) :: {:ok, [String.t()], Enumerable.t()} | {:error, term()}

  @impl Refract.Query.Engine
  def run(%__MODULE__{} = state, sql, params) do
    with {:ok, description} <- describe(state, sql, params) do
      columns = Enum.map(description, fn [name, _type | _rest] -> name end)
      converters = Enum.map(description, fn [_name, type | _rest] -> converter(type) end)

      {:ok, columns, rows(state, sql, params, converters)}
    end
  end

  @spec close(t()) :: :ok

  @impl Refract.Query.Engine
  def close(%__MODULE__{database: database, connection: connection, closed: closed}) do
    if :atomics.compare_exchange(closed, 1, 0, 1) == :ok do
      :ok = Duckdbex.release(connection)
      :ok = Duckdbex.release(database)
    end

    :ok
  end

  defp validate_path(path) when is_nil(path) or is_binary(path), do: :ok

  defp validate_path(path) do
    raise ArgumentError, "path must be a string or nil, got: #{inspect(path)}"
  end

  defp database(nil), do: Duckdbex.open()
  defp database(path), do: Duckdbex.open(path)

  defp execute(state, sql) do
    with {:ok, query_result} <- query(state, sql, []) do
      Duckdbex.release(query_result)
    end
  end

  defp describe(state, sql, params) do
    with {:ok, query_result} <- query(state, "DESCRIBE " <> sql, params) do
      description = Duckdbex.fetch_all(query_result)
      :ok = Duckdbex.release(query_result)

      described(description)
    end
  end

  defp described({:error, reason}), do: {:error, {:query_error, reason}}
  defp described(description), do: {:ok, description}

  defp query(%__MODULE__{connection: connection, closed: closed}, sql, params) do
    case :atomics.get(closed, 1) do
      0 -> connection |> Duckdbex.query(sql, params) |> queried()
      1 -> {:error, :closed}
    end
  end

  defp queried({:ok, query_result}), do: {:ok, query_result}
  defp queried({:error, reason}), do: {:error, {:query_error, reason}}

  defp rows(%__MODULE__{closed: closed} = state, sql, params, converters) do
    Stream.resource(
      fn -> start(state, sql, params) end,
      &next_chunk(&1, converters, closed),
      &Duckdbex.release/1
    )
  end

  defp start(state, sql, params) do
    state
    |> query(sql, params)
    |> started()
  end

  defp started({:ok, query_result}), do: query_result
  defp started({:error, :closed}), do: raise(QueryError, message: "query is closed")
  defp started({:error, {:query_error, reason}}), do: raise(QueryError, message: reason)

  defp next_chunk(query_result, converters, closed) do
    if :atomics.get(closed, 1) == 1 do
      raise QueryError, message: "query is closed"
    end

    query_result
    |> Duckdbex.fetch_chunk()
    |> chunk(query_result, converters)
  end

  defp chunk([], query_result, _converters), do: {:halt, query_result}
  defp chunk({:error, reason}, _query_result, _converters), do: raise(QueryError, message: reason)

  defp chunk(rows, query_result, converters),
    do: {Enum.map(rows, &convert(&1, converters)), query_result}

  defp convert(row, converters), do: Enum.zip_with(row, converters, &cell/2)

  defp cell(nil, _converter), do: nil
  defp cell(value, converter), do: converter.(value)

  defp converter("DECIMAL" <> _precision), do: &decimal/1
  defp converter("DATE"), do: &Date.from_erl!/1
  defp converter("TIMESTAMP"), do: &timestamp/1
  defp converter("TIME"), do: &time/1
  defp converter("HUGEINT"), do: &Duckdbex.hugeint_to_integer/1
  defp converter(_type), do: &Function.identity/1

  defp decimal({{lower, upper}, width, scale}),
    do: decimal({Duckdbex.hugeint_to_integer({upper, lower}), width, scale})

  defp decimal({coefficient, _width, scale}) when coefficient < 0,
    do: Decimal.new(-1, -coefficient, -scale)

  defp decimal({coefficient, _width, scale}), do: Decimal.new(1, coefficient, -scale)

  defp timestamp({date, time}), do: NaiveDateTime.new!(Date.from_erl!(date), time(time))

  defp time({hour, minute, second, microsecond}),
    do: Time.new!(hour, minute, second, {microsecond, 6})

  defp append(appender, rows) do
    rows
    |> Stream.chunk_every(2048)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      appended(Duckdbex.appender_add_rows(appender, chunk))
    end)
    |> close_appender(appender)
  after
    Duckdbex.release(appender)
  end

  defp appended(:ok), do: {:cont, :ok}
  defp appended(error), do: {:halt, result(error)}

  defp close_appender(:ok, appender), do: appender |> Duckdbex.appender_close() |> result()
  defp close_appender(error, _appender), do: error

  defp result(:ok), do: :ok
  defp result({:error, reason}), do: {:error, {:query_error, reason}}

  defp source("csv", glob, types),
    do: {:ok, "read_csv(#{literal(glob)}, union_by_name = true#{column_types(types)})"}

  defp source(format, _glob, _types), do: {:error, {:unsupported_format, format}}

  defp column_types(:text), do: ", all_varchar = true"
  defp column_types(:infer), do: ""

  defp column_definitions(columns),
    do: Enum.map_join(columns, ", ", &"#{identifier(&1)} VARCHAR")

  defp literal(value), do: "'" <> String.replace(value, "'", "''") <> "'"

  defp identifier(value), do: ~s(") <> String.replace(value, ~s("), ~s("")) <> ~s(")
end
