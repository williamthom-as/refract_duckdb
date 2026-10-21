defmodule Refract.DuckDB.Golden do
  @moduledoc false

  @root Path.expand("../fixtures", __DIR__)

  @spec path(String.t(), String.t()) :: Path.t()

  def path(dir, file), do: Path.join([@root, dir, file])

  @spec read!(String.t(), String.t()) :: String.t()

  def read!(dir, file), do: File.read!(path(dir, file))

  @spec rows!(String.t(), String.t()) :: [map()]

  def rows!(dir, file) do
    {:ok, rows} = Refract.CSV.stream(path(dir, file))

    Enum.to_list(rows)
  end

  @spec folder!(Path.t(), String.t(), [Path.t()]) :: Path.t()

  def folder!(root, name, sources) do
    folder = Path.join(root, name)
    File.mkdir_p!(folder)

    for source <- sources, do: File.cp!(source, Path.join(folder, Path.basename(source)))

    folder
  end
end
