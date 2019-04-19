defmodule Cpc.AlpmUtils do
  def parse_db(db) do
    db
    |> String.replace_trailing("\n", "")
    |> String.split("\n\n")
    |> Enum.reduce([], fn
      "%" <> rest, acc ->
        [header, value] = String.split(rest, "\n", parts: 2)
        [{String.replace_suffix(header, "%", ""), value} | acc]
    end)
    |> Map.new()
  end
end
